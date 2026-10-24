import Foundation

/// What's inside a Windows installation image, read natively from the XML
/// block every WIM / ESD carries (no extra tools needed).
struct WindowsEdition: Hashable, Sendable {
    var index: Int
    var name: String          // "Windows 11 Pro"
    var build: Int            // 22631
    var arch: WindowsArch
    var languages: [String]
}

enum WindowsArch: String, Sendable {
    case x86, amd64, arm64, unknown
    /// `<ARCH>` codes used in WIM metadata (PROCESSOR_ARCHITECTURE_*).
    init(code: Int) {
        switch code {
        case 0: self = .x86
        case 9: self = .amd64
        case 12: self = .arm64
        default: self = .unknown
        }
    }
    var title: String {
        switch self { case .x86: return "32-bit"; case .amd64: return "64-bit (x64)"; case .arm64: return "Arm64"; case .unknown: return "" }
    }
}

struct WindowsImageInfo: Sendable {
    var editions: [WindowsEdition]
    var build: Int { editions.map(\.build).max() ?? 0 }
    var arch: WindowsArch { editions.first?.arch ?? .unknown }
    /// Windows 11 kept major version 10; builds from 22000 on are Windows 11.
    var isWindows11: Bool { build >= 22000 }
    var title: String {
        let name = isWindows11 ? "Windows 11" : (build >= 10240 ? "Windows 10" : "Windows")
        return [name, build > 0 ? "build \(build)" : "", arch.title].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

enum WindowsImage {
    /// Reads the metadata XML of a .wim / .esd: the header's XML resource
    /// (offset 0x48: 7-byte size, 1-byte flags, 8-byte offset), UTF-16LE.
    static func read(_ path: String) -> WindowsImageInfo? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 208), head.count == 208,
              head.prefix(5) == Data("MSWIM".utf8) else { return nil }
        let size = head[0x48..<0x4F].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        let offset = head[0x50..<0x58].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        guard size > 0, size < 16_000_000 else { return nil }
        try? h.seek(toOffset: offset)
        guard let xml = try? h.read(upToCount: size), let text = String(data: xml, encoding: .utf16LittleEndian) else { return nil }
        return parse(text)
    }

    /// Pulls each `<IMAGE>` out of the WIM XML (small, regular format).
    static func parse(_ xml: String) -> WindowsImageInfo {
        var out: [WindowsEdition] = []
        for chunk in xml.components(separatedBy: "<IMAGE INDEX=\"").dropFirst() {
            let index = Int(chunk.prefix { $0.isNumber }) ?? 0
            let name = tag("DISPLAYNAME", in: chunk) ?? tag("NAME", in: chunk) ?? "Edition \(index)"
            let build = Int(tag("BUILD", in: chunk) ?? "") ?? 0
            let arch = WindowsArch(code: Int(tag("ARCH", in: chunk) ?? "") ?? -1)
            let langs = chunk.components(separatedBy: "<LANGUAGE>").dropFirst().compactMap { $0.components(separatedBy: "</LANGUAGE>").first }
            out.append(WindowsEdition(index: index, name: name, build: build, arch: arch, languages: langs))
        }
        return WindowsImageInfo(editions: out)
    }

    private static func tag(_ t: String, in s: String) -> String? {
        guard let a = s.range(of: "<\(t)>"), let b = s.range(of: "</\(t)>", range: a.upperBound..<s.endIndex) else { return nil }
        return String(s[a.upperBound..<b.lowerBound])
    }
}
