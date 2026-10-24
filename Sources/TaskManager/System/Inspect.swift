import Darwin
import Foundation
import Security
import CryptoKit

/// A TCP/UDP port that one of your processes is listening on.
struct ListeningPort: Identifiable, Sendable, Hashable {
    var id: String { "\(pid)-\(proto)-\(port)" }
    let pid: pid_t
    let process: String
    let proto: String       // "TCP" / "UDP"
    let port: Int
    let address: String     // "*" or a specific IP
}

/// A process that has a file (or something inside a folder/disk) open.
struct OpenFileUse: Identifiable, Sendable, Hashable {
    var id: String { "\(pid)-\(path)" }
    let pid: pid_t
    let process: String
    let path: String
}

/// Socket and file-descriptor inspection via libproc. Works for your own
/// processes; the kernel hides other users' descriptors without admin rights.
enum FDInspector {
    private static func fds(_ pid: pid_t) -> [proc_fdinfo] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<proc_fdinfo>.stride + 16
        var buf = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &buf, Int32(count * MemoryLayout<proc_fdinfo>.stride))
        guard got > 0 else { return [] }
        return Array(buf.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride))
    }

    static func listeningPorts(_ procs: [ProcessInfoSample]) -> [ListeningPort] {
        var out: [ListeningPort] = []
        for p in procs where !p.restricted {
            for fd in fds(p.pid) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var si = socket_fdinfo()
                let r = proc_pidfdinfo(p.pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, Int32(MemoryLayout<socket_fdinfo>.size))
                guard r == Int32(MemoryLayout<socket_fdinfo>.size) else { continue }
                let kind = si.psi.soi_kind
                let family = si.psi.soi_family
                guard family == AF_INET || family == AF_INET6 else { continue }
                if kind == Int32(SOCKINFO_TCP) {
                    let tcp = si.psi.soi_proto.pri_tcp
                    guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
                    let ini = tcp.tcpsi_ini
                    out.append(ListeningPort(pid: p.pid, process: p.name, proto: "TCP",
                                             port: Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))),
                                             address: address(ini, family: family)))
                } else if kind == Int32(SOCKINFO_IN) {
                    let ini = si.psi.soi_proto.pri_in
                    let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
                    guard port > 0, ini.insi_fport == 0 else { continue }   // bound, unconnected UDP
                    out.append(ListeningPort(pid: p.pid, process: p.name, proto: "UDP", port: port,
                                             address: address(ini, family: family)))
                }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }.sorted { ($0.port, $0.proto) < ($1.port, $1.proto) }
    }

    private static func address(_ ini: in_sockinfo, family: Int32) -> String {
        var ini = ini
        if family == AF_INET {
            var a = ini.insi_laddr.ina_46.i46a_addr4
            if a.s_addr == 0 { return "All interfaces" }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
            return String(cString: buf)
        }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        withUnsafePointer(to: &ini.insi_laddr.ina_6) { p in _ = inet_ntop(AF_INET6, p, &buf, socklen_t(buf.count)) }
        let s = String(cString: buf)
        return s == "::" ? "All interfaces" : s
    }

    /// Processes with `path` (a file, or anything under a folder / disk) open,
    /// including their current working directory.
    static func users(of path: String, _ procs: [ProcessInfoSample]) -> [OpenFileUse] {
        let target = (path as NSString).standardizingPath
        let isDir = (try? URL(fileURLWithPath: target).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        func matches(_ p: String) -> Bool { p == target || (isDir && p.hasPrefix(target.hasSuffix("/") ? target : target + "/")) }
        var out: [OpenFileUse] = []
        for p in procs where !p.restricted {
            var vpi = proc_vnodepathinfo()
            if proc_pidinfo(p.pid, PROC_PIDVNODEPATHINFO, 0, &vpi, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 {
                let cwd = withUnsafeBytes(of: vpi.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                if matches(cwd) { out.append(OpenFileUse(pid: p.pid, process: p.name, path: cwd + "  (working folder)")) }
            }
            if matches(p.path) { out.append(OpenFileUse(pid: p.pid, process: p.name, path: p.path + "  (running from here)")) }
            for fd in fds(p.pid) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var vi = vnode_fdinfowithpath()
                let r = proc_pidfdinfo(p.pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vi, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
                guard r == Int32(MemoryLayout<vnode_fdinfowithpath>.size) else { continue }
                let fp = withUnsafeBytes(of: vi.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                if matches(fp) { out.append(OpenFileUse(pid: p.pid, process: p.name, path: fp)) }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }
}

/// Code-signing identity of an executable or app bundle.
struct SignatureInfo: Sendable {
    enum Status: String, Sendable { case apple = "Apple", notarized = "Notarized", appStore = "Mac App Store",
                                         signed = "Signed (not notarized)", adHoc = "Ad-hoc signed", unsigned = "Not signed", invalid = "Invalid signature" }
    var status: Status
    var developer: String?
    var teamID: String?
    var identifier: String?
    var isTrusted: Bool { [.apple, .notarized, .appStore].contains(status) }
}

enum CodeSignature {
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: SignatureInfo] = [:]

    static func purge() { cacheLock.lock(); cache.removeAll(); cacheLock.unlock() }

    static func check(_ path: String) -> SignatureInfo? {
        guard !path.isEmpty else { return nil }
        cacheLock.lock(); if let c = cache[path] { cacheLock.unlock(); return c }; cacheLock.unlock()
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var infoRef: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        let info = (infoRef as? [String: Any]) ?? [:]
        var result: SignatureInfo
        if info[kSecCodeInfoIdentifier as String] == nil {
            result = SignatureInfo(status: .unsigned)
        } else if SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) != errSecSuccess {
            result = SignatureInfo(status: .invalid)
        } else {
            func satisfies(_ req: String) -> Bool {
                var r: SecRequirement?
                guard SecRequirementCreateWithString(req as CFString, [], &r) == errSecSuccess, let r else { return false }
                return SecStaticCodeCheckValidity(code, [], r) == errSecSuccess
            }
            let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
            let developer = certs.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
            let status: SignatureInfo.Status
            if satisfies("anchor apple") { status = .apple }
            else if satisfies("anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9]") { status = .appStore }
            else if satisfies("notarized") { status = .notarized }
            else if certs.isEmpty { status = .adHoc }
            else { status = .signed }
            result = SignatureInfo(status: status, developer: status == .apple ? "Apple" : developer,
                                   teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
                                   identifier: info[kSecCodeInfoIdentifier as String] as? String)
        }
        cacheLock.lock(); cache[path] = result; cacheLock.unlock()
        return result
    }

    /// SHA-256 of a file, for a VirusTotal lookup (the hash is the only thing sent).
    static func sha256(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
