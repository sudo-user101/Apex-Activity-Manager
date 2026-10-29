import Foundation

/// Preview-Folder's archive work, done with tools macOS ships (`ditto`, `tar`,
/// i.e. libarchive, and `zip`): extract (all of it or some, with a password,
/// split zips joined), create zip or 7z (AES-256 password and split volumes
/// for zip), add to and delete from a zip, and check an archive for damage.
/// Zips are made and unpacked with `ditto` when possible, which keeps Finder
/// tags, custom icons, permissions and symbolic links, so extracted apps run.
enum ArchiveTools {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case zip, sevenZip = "7z"
        var id: String { rawValue }
        var title: String { self == .zip ? "ZIP" : "7z" }
        var ext: String { self == .zip ? "zip" : "7z" }
    }

    enum Failure: Error, LocalizedError, Equatable {
        case needsPassword, wrongPassword, unsupported(String), failed(String)
        var errorDescription: String? {
            switch self {
            case .needsPassword: return "This archive is protected with a password."
            case .wrongPassword: return "That password isn’t right."
            case .unsupported(let why): return why
            case .failed(let why): return why.isEmpty ? "That didn’t work." : why
            }
        }
    }

    // MARK: What a file is

    /// The archive kind from a file's first bytes, whatever its name. Pure: tested.
    static func kind(magic d: Data) -> String? {
        func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            d.count >= offset + bytes.count && Array(d[d.startIndex + offset ..< d.startIndex + offset + bytes.count]) == bytes
        }
        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) || starts([0x50, 0x4B, 0x07, 0x08]) { return "zip" }
        if starts([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return "7z" }
        if starts([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { return "rar" }
        if starts([0x1F, 0x8B]) { return "gz" }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return "xz" }
        if starts([0x42, 0x5A, 0x68]) { return "bz2" }
        if starts([0x28, 0xB5, 0x2F, 0xFD]) { return "zst" }
        if starts([0x04, 0x22, 0x4D, 0x18]) { return "lz4" }
        if starts(Array("MSCF".utf8)) { return "cab" }
        if starts(Array("xar!".utf8)) { return "xar" }
        if starts(Array("!<arch>".utf8)) { return "ar" }
        if starts(Array("070707".utf8)) || starts(Array("070701".utf8)) || starts(Array("070702".utf8)) { return "cpio" }
        if starts(Array("ustar".utf8), at: 257) { return "tar" }
        return nil
    }

    /// An archive by its name, or failing that by its first bytes. Reads 512 bytes at most.
    static func isArchive(_ url: URL) -> Bool {
        if ArchiveList.isArchive(url) { return true }
        guard !Dataless.file(url.path), let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return kind(magic: (try? h.read(upToCount: 512)) ?? Data()) != nil
    }

    static func isDiskImage(_ url: URL) -> Bool { ["dmg", "sparseimage", "sparsebundle"].contains(url.pathExtension.lowercased()) }

    /// The archive's name without its archive extensions ("photos.tar.gz" → "photos"). Pure: tested.
    static func baseName(_ name: String) -> String {
        var n = name
        let known: Set<String> = ArchiveList.extensions.union(["001", "z01"])
        while case let ext = (n as NSString).pathExtension.lowercased(), !ext.isEmpty, known.contains(ext) {
            n = (n as NSString).deletingPathExtension
        }
        return n.isEmpty ? name : n
    }

    /// `name`, or "name 2", "name 3"… so nothing already there is touched. Pure: tested.
    static func unique(_ name: String, existing: (String) -> Bool) -> String {
        guard existing(name) else { return name }
        let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(name) \(n)" : "\(base) \(n).\(ext)"
            if !existing(candidate) { return candidate }
            n += 1
        }
    }

    /// Where an extraction ends up: one top-level item stays as it is; several
    /// go into a folder named after the archive. Pure: tested.
    static func smartName(topLevel: [String], archiveName: String) -> (wrap: Bool, name: String) {
        topLevel.count == 1 ? (false, topLevel[0]) : (true, baseName(archiveName))
    }

    // MARK: Extract

    /// Unpacks `items` (paths inside the archive; empty = everything) into
    /// `folder`, smartly named, and returns what was made.
    static func extract(_ archive: URL, items: [String] = [], to folder: URL, password: String? = nil) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let staging = folder.appendingPathComponent(".apex-extract-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            let out = staging.appendingPathComponent("out", isDirectory: true)
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            if let joined = try joinSplitZip(archive, in: staging) {
                // macOS's unzip reads a joined split zip and checks every file; its warning about the parts is expected.
                let r = run("/usr/bin/unzip", ["-q", "-o", joined.path, "-d", out.path] + items.flatMap { [$0, $0 + "/*"] })
                let problems = r.err.lowercased().split(separator: "\n").filter { $0.contains("bad crc") || $0.contains("error:") || $0.contains("incorrect password") }
                if !problems.isEmpty { throw Failure.failed("This split archive is damaged or a part is missing: " + firstLine(String(problems[0]))) }
                return try place(out: out, items: items, archive: archive, folder: folder)
            }
            let source = archive

            let isZip = kind(magic: (try? FileHandle(forReadingFrom: source).read(upToCount: 8)) ?? Data()) == "zip"
            var result: (status: Int32, err: String, out: String)
            if isZip, items.isEmpty, password == nil {
                result = run("/usr/bin/ditto", ["-x", "-k", source.path, out.path])
            } else {
                var args = ["-xf", source.path, "-C", out.path]
                if let password { args += ["--passphrase", password] }
                // "--": a name inside the archive is never read as an option (an entry called "-P" would turn off tar's protections).
                if !items.isEmpty { args += ["--"] + items }
                result = run("/usr/bin/tar", args)
            }
            if result.status != 0 {
                let e = result.err.lowercased()
                if e.contains("passphrase") || e.contains("encrypted") {
                    throw password == nil ? Failure.needsPassword : Failure.wrongPassword
                }
                // ditto can't do some zips (e.g. AES ones): libarchive gets a go.
                if isZip, items.isEmpty, password == nil {
                    try? fm.removeItem(at: out); try fm.createDirectory(at: out, withIntermediateDirectories: true)
                    let again = run("/usr/bin/tar", ["-xf", source.path, "-C", out.path])
                    if again.status != 0 {
                        let e2 = again.err.lowercased()
                        if e2.contains("passphrase") || e2.contains("encrypted") { throw Failure.needsPassword }
                        throw Failure.failed(firstLine(again.err))
                    }
                } else {
                    throw Failure.failed(firstLine(result.err))
                }
            }
            return try place(out: out, items: items, archive: archive, folder: folder)
        }.value
    }

    /// Moves what was unpacked into `folder`, smartly named.
    private static func place(out: URL, items: [String], archive: URL, folder: URL) throws -> URL {
            let fm = FileManager.default
            // Selected items keep their place inside the archive; bring them up to the top.
            var root = out
            if !items.isEmpty, items.count == 1 || Set(items.map { ($0 as NSString).deletingLastPathComponent }).count == 1 {
                let parent = (items[0] as NSString).deletingLastPathComponent
                if !parent.isEmpty { root = out.appendingPathComponent(parent) }
            }
            let top = try fm.contentsOfDirectory(atPath: root.path).filter { $0 != "__MACOSX" && $0 != ".DS_Store" }
            guard !top.isEmpty else { throw Failure.failed("Nothing came out of it.") }
            let plan = smartName(topLevel: top, archiveName: archive.lastPathComponent)
            let finalName = unique(plan.name) { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
            let dest = folder.appendingPathComponent(finalName)
            if plan.wrap {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                for name in top { try fm.moveItem(at: root.appendingPathComponent(name), to: dest.appendingPathComponent(name)) }
            } else {
                try fm.moveItem(at: root.appendingPathComponent(top[0]), to: dest)
            }
            return dest
    }

    /// The parts of a split zip, in order (name.z01, name.z02… then name.zip). Pure apart from looking at the folder.
    static func splitParts(_ archive: URL) -> [URL]? {
        guard archive.pathExtension.lowercased() == "zip" else { return nil }
        let base = archive.deletingPathExtension()
        var parts: [URL] = []
        var n = 1
        while case let part = base.appendingPathExtension(String(format: "z%02d", n)), FileManager.default.fileExists(atPath: part.path) {
            parts.append(part); n += 1
        }
        return parts.isEmpty ? nil : parts + [archive]
    }

    /// A split zip's parts joined end to end, or nil when it isn't split.
    private static func joinSplitZip(_ archive: URL, in dir: URL) throws -> URL? {
        guard let parts = splitParts(archive) else { return nil }
        let joined = dir.appendingPathComponent("joined.zip")
        FileManager.default.createFile(atPath: joined.path, contents: nil)
        let out = try FileHandle(forWritingTo: joined)
        defer { try? out.close() }
        for part in parts {
            let input = try FileHandle(forReadingFrom: part)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { out.write(chunk) }
        }
        return joined
    }

    // MARK: Create

    /// Why an archive can't be made that way, or nil. Pure: tested.
    static func refusal(format: Format, password: String?, splitMB: Int?) -> String? {
        if format == .sevenZip, password?.isEmpty == false { return "macOS’s tools can’t put a password on 7z archives. Use ZIP for a password (AES-256)." }
        if format == .sevenZip, (splitMB ?? 0) > 0 { return "Only ZIP archives can be split into parts." }
        if (splitMB ?? 0) > 0, password?.isEmpty == false { return "macOS’s tools can split a ZIP or protect it with a password, not both at once." }
        return nil
    }

    /// Packs `items` into a new archive next to the first one. Returns it.
    static func create(_ items: [URL], format: Format, password: String?, splitMB: Int?, name: String? = nil) async throws -> URL {
        guard let first = items.first else { throw Failure.failed("Nothing to compress.") }
        if let why = refusal(format: format, password: password, splitMB: splitMB) { throw Failure.unsupported(why) }
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let folder = first.deletingLastPathComponent()
            let base = name ?? (items.count == 1 ? first.lastPathComponent : "Archive")
            let fileName = unique(base + "." + format.ext) { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
            let dest = folder.appendingPathComponent(fileName)
            let r: (status: Int32, err: String, out: String)
            var isDir: ObjCBool = false
            let firstIsFolder = fm.fileExists(atPath: first.path, isDirectory: &isDir) && isDir.boolValue
            if let mb = splitMB, mb > 0 {
                // Split archives are made by zip itself (re-splitting another tool's zip damages it).
                guard Set(items.map { $0.deletingLastPathComponent().path }).count == 1 else {
                    throw Failure.unsupported("To split, choose items that are in the same folder.")
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                p.arguments = ["-q", "-r", "-y", "-s", "\(mb)m", dest.path, "--"] + items.map(\.lastPathComponent)
                p.currentDirectoryURL = folder
                let err = Pipe(); p.standardError = err; p.standardOutput = FileHandle.nullDevice
                try p.run(); p.waitUntilExit()
                guard p.terminationStatus == 0 else {
                    throw Failure.failed(firstLine(String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""))
                }
                return dest
            } else if format == .zip, items.count == 1, password?.isEmpty != false {
                // ditto keeps tags, icons, permissions and links. --keepParent puts a folder in under its own name.
                r = run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc"] + (firstIsFolder ? ["--keepParent"] : []) + [first.path, dest.path])
            } else {
                var args = ["-cf", dest.path, "--format=" + (format == .zip ? "zip" : "7zip")]
                if format == .zip, let p = password, !p.isEmpty { args += ["--options", "zip:encryption=aes256", "--passphrase", p] }
                // A name starting with "-" is given as "./-name", so tar can't take it for an option.
                for u in items { args += ["-C", u.deletingLastPathComponent().path, u.lastPathComponent.hasPrefix("-") ? "./" + u.lastPathComponent : u.lastPathComponent] }
                r = run("/usr/bin/tar", args)
            }
            guard r.status == 0 else { try? fm.removeItem(at: dest); throw Failure.failed(firstLine(r.err)) }
            return dest
        }.value
    }

    // MARK: Edit (ZIP)

    static func canEdit(_ archive: URL) -> Bool { archive.pathExtension.lowercased() == "zip" && splitParts(archive) == nil }

    /// Takes items (files or whole folders, as paths inside the zip) out of it.
    static func delete(_ paths: [String], from archive: URL, folders: Set<String>) async throws {
        guard canEdit(archive) else { throw Failure.unsupported("Only ZIP archives (not split ones) can be changed.") }
        let patterns = paths.flatMap { folders.contains($0) ? [$0 + "/", $0 + "/*"] : [$0] }
        let r = await Task.detached { run("/usr/bin/zip", ["-q", "-d", archive.path, "--"] + patterns) }.value
        guard r.status == 0 || r.status == 12 else { throw Failure.failed(firstLine(r.err)) }   // 12: nothing matched
    }

    /// Puts files into the zip, inside `folder` ("" = the top), replacing ones with the same name.
    static func add(_ files: [URL], to archive: URL, inside folder: String) async throws {
        guard canEdit(archive) else { throw Failure.unsupported("Only ZIP archives (not split ones) can be changed.") }
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let stage = fm.temporaryDirectory.appendingPathComponent("apex-add-\(UUID().uuidString.prefix(8))", isDirectory: true)
            let into = folder.isEmpty ? stage : stage.appendingPathComponent(folder, isDirectory: true)
            try fm.createDirectory(at: into, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: stage) }
            var names: [String] = []
            for f in files {
                try fm.copyItem(at: f, to: into.appendingPathComponent(f.lastPathComponent))
                names.append(folder.isEmpty ? f.lastPathComponent : folder + "/" + f.lastPathComponent)
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.arguments = ["-q", "-r", "-y", archive.path, "--"] + names
            p.currentDirectoryURL = stage
            let err = Pipe(); p.standardError = err; p.standardOutput = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw Failure.failed(firstLine(String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""))
            }
        }.value
    }

    // MARK: Check

    /// Reads every file in the archive through to the end: nil when all is
    /// well, else what's damaged.
    static func check(_ archive: URL, password: String? = nil) async -> String? {
        await Task.detached(priority: .userInitiated) {
            var args = ["-xOf", archive.path]
            if let password { args += ["--passphrase", password] }
            let r = run("/usr/bin/tar", args, discardOutput: true)
            if r.status == 0 { return nil }
            let lines = r.err.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("tar: Error exit") }
            return lines.isEmpty ? "It couldn’t be read to the end." : lines.prefix(5).joined(separator: "\n")
        }.value
    }

    // MARK: Disk images

    /// Mounts a disk image read-only and hidden from Finder; returns where.
    static func mount(_ image: URL) async throws -> URL {
        try await Task.detached {
            let r = run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-noverify", "-plist", image.path], captureOutput: true)
            guard r.status == 0, let data = r.out.data(using: .utf8),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let entities = plist["system-entities"] as? [[String: Any]],
                  let mount = entities.compactMap({ $0["mount-point"] as? String }).first else {
                throw Failure.failed("This disk image couldn’t be opened. " + firstLine(r.err))
            }
            return URL(fileURLWithPath: mount, isDirectory: true)
        }.value
    }

    static func unmount(_ point: URL) { _ = run("/usr/bin/hdiutil", ["detach", "-quiet", point.path]) }

    // MARK: Running the tools

    @discardableResult
    nonisolated static func run(_ tool: String, _ args: [String], discardOutput: Bool = false, captureOutput: Bool = false) -> (status: Int32, err: String, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe(), out = Pipe()
        p.standardError = err
        p.standardOutput = captureOutput ? out : FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, error.localizedDescription, "") }
        var outData = Data()
        if captureOutput { outData = out.fileHandleForReading.readDataToEndOfFile() }
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        _ = discardOutput
        return (p.terminationStatus, String(data: errData, encoding: .utf8) ?? "", String(data: outData, encoding: .utf8) ?? "")
    }

    private static func firstLine(_ s: String) -> String {
        s.split(separator: "\n").first.map { String($0).replacingOccurrences(of: "tar: ", with: "") } ?? ""
    }
}
