import Foundation
import Security

/// A cloud service Apex shows on Performance › Cloud: a folder macOS syncs
/// (iCloud Drive, ~/Library/CloudStorage: OneDrive, Google Drive, Dropbox,
/// Nextcloud…), or one the user added: any folder, or a WebDAV server
/// (Nextcloud, ownCloud, a NAS…) for its online quota.
struct CloudService: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case system, folder, webdav, web }
    var id: String
    var name: String
    var account: String = ""
    var kind: Kind
    var path: String = ""            // local folder, if any
    var url: String = ""             // WebDAV address
    var username: String = ""
    /// Web sign-in: the provider's storage page and this service's own browser data.
    var webPage: String? = nil
    var webStore: String? = nil

    var symbol: String {
        switch name {
        case "iCloud Drive": return "icloud"
        case "OneDrive", "Google Drive", "Dropbox", "Box", "Nextcloud": return "externaldrive.connected.to.line.below"
        default: return kind == .webdav ? "server.rack" : kind == .web ? "globe" : "folder"
        }
    }
}

/// What a scan found in a local cloud folder.
struct CloudUsage: Sendable, Equatable {
    var files = 0
    var onlineOnly = 0
    var totalBytes: UInt64 = 0        // everything, including online-only files
    var onMacBytes: UInt64 = 0        // what's actually stored on this Mac
    var largest: [CloudFile] = []     // biggest files stored on this Mac
    var partial = false
    var scanned = Date()
}

struct CloudFile: Identifiable, Sendable, Hashable {
    var id: String { path }
    let path: String
    let bytes: UInt64
    var uploading = false          // not in the cloud yet: can't be made online-only until it is
    var name: String { (path as NSString).lastPathComponent }
}

struct CloudQuota: Sendable, Equatable {
    var used: UInt64
    var available: UInt64?
    var total: UInt64? { available.map { used + $0 } }
}

enum Cloud {
    /// Services macOS syncs for this user.
    static func detected(home: String = NSHomeDirectory()) -> [CloudService] {
        var out: [CloudService] = []
        let icloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if FileManager.default.fileExists(atPath: icloud) {
            out.append(CloudService(id: "icloud", name: "iCloud Drive", kind: .system, path: icloud))
        }
        let base = home + "/Library/CloudStorage"
        for dir in ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []).sorted() where !dir.hasPrefix(".") {
            let (name, account) = providerName(dir)
            out.append(CloudService(id: "cs:" + dir, name: name, account: account, kind: .system, path: base + "/" + dir))
        }
        return out
    }

    /// "OneDrive-Personal" → ("OneDrive", "Personal"); "GoogleDrive-me@x.com" →
    /// ("Google Drive", "me@x.com"); "Nextcloud-host-user" → ("Nextcloud", "host-user"). Pure: tested.
    static func providerName(_ dir: String) -> (String, String) {
        let parts = dir.split(separator: "-", maxSplits: 1).map(String.init)
        let raw = parts[0], account = parts.count > 1 ? parts[1] : ""
        let known = ["OneDrive": "OneDrive", "GoogleDrive": "Google Drive", "Dropbox": "Dropbox", "Box": "Box",
                     "Nextcloud": "Nextcloud", "ownCloud": "ownCloud", "pCloud": "pCloud", "ProtonDrive": "Proton Drive",
                     "SynologyDrive": "Synology Drive", "MEGA": "MEGA"]
        let name = known[raw] ?? raw
        return (name, account == name ? "" : account)
    }

    /// Walks a folder: how much is stored on this Mac vs online only. Reading
    /// metadata never downloads anything. Blocking: call off the main thread.
    static func scan(_ path: String, cancelled: () -> Bool = { false }) -> CloudUsage {
        var u = CloudUsage()
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys,
                                                     options: [], errorHandler: { _, _ in true }) else { return u }
        var biggest: [CloudFile] = []
        for case let url as URL in e {
            if cancelled() { u.partial = true; break }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let logical = UInt64(v.fileSize ?? 0)
            let onMac = UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            u.files += 1
            u.totalBytes += logical
            u.onMacBytes += onMac
            if logical > 0 && onMac == 0 { u.onlineOnly += 1 }
            if onMac > 1_000_000 {
                let up = try? url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey])
                biggest.append(CloudFile(path: url.path, bytes: onMac, uploading: up?.ubiquitousItemIsUploaded == false))
                if biggest.count > 200 { biggest.sort { $0.bytes > $1.bytes }; biggest.removeLast(100) }
            }
        }
        u.largest = Array(biggest.sorted { $0.bytes > $1.bytes }.prefix(40))
        u.scanned = Date()
        return u
    }

    // MARK: Offload everything

    enum EvictResult: Equatable, Sendable { case done, waitingForUpload, failed(String) }

    /// Every file stored on this Mac in the folder (to offload them all).
    static func storedFiles(_ path: String, cancelled: () -> Bool = { false }) -> [CloudFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys,
                                                     options: [], errorHandler: { _, _ in true }) else { return [] }
        var out: [CloudFile] = []
        for case let url as URL in e {
            if cancelled() { break }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let onMac = UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            if onMac > 0 { out.append(CloudFile(path: url.path, bytes: onMac)) }
        }
        return out
    }

    /// Offloads one file. A file that isn't uploaded yet can't be: macOS keeps
    /// it so nothing is lost, and Apex tries again later.
    static func evict(_ f: CloudFile) -> EvictResult {
        let url = URL(fileURLWithPath: f.path)
        do {
            try FileManager.default.evictUbiquitousItem(at: url)
            return .done
        } catch {
            let v = try? url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey])
            if let e = v?.ubiquitousItemUploadingError { return .failed("Upload problem: " + e.localizedDescription) }
            if v?.ubiquitousItemIsUploaded == false { return .waitingForUpload }
            // Uploaded, yet refused: the provider keeps it here (e.g. "always keep downloaded").
            return .failed("The cloud app keeps “\(f.name)” on this Mac (it may be set to always keep it downloaded).")
        }
    }

    // MARK: WebDAV quota (RFC 4331)

    static let quotaBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:"><d:prop><d:quota-used-bytes/><d:quota-available-bytes/></d:prop></d:propfind>
    """

    /// Quota from a PROPFIND reply. Pure: tested. Negative "available" means unknown or unlimited.
    static func parseQuota(_ xml: String) -> CloudQuota? {
        func value(_ tag: String) -> Int64? {
            guard let r = xml.range(of: tag + ">", options: .caseInsensitive),
                  let end = xml.range(of: "</", range: r.upperBound..<xml.endIndex) else { return nil }
            return Int64(xml[r.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let used = value("quota-used-bytes") else { return nil }
        let avail = value("quota-available-bytes")
        return CloudQuota(used: UInt64(max(0, used)), available: avail.flatMap { $0 >= 0 ? UInt64($0) : nil })
    }

    static func quota(url: String, username: String, password: String) async -> Result<CloudQuota, Error> {
        guard let u = URL(string: url), ["https", "http"].contains(u.scheme ?? "") else {
            return .failure(err("That doesn’t look like a web address (https://…)."))
        }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = "PROPFIND"
        req.setValue("0", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(quotaBody.utf8)
        if !username.isEmpty {
            req.setValue("Basic " + Data("\(username):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { return .failure(err("The server didn’t accept the user name or password.")) }
            guard code == 207 || code == 200 else { return .failure(err("The server answered \(code); check the address.")) }
            guard let q = parseQuota(String(decoding: data, as: UTF8.self)) else {
                return .failure(err("The server doesn’t report its storage quota."))
            }
            return .success(q)
        } catch {
            return .failure(error)
        }
    }

    private static func err(_ s: String) -> NSError { NSError(domain: "Apex", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
}

/// Passwords for added servers, in the login keychain (never in settings files).
enum Keychain {
    private static let service = "Apex Activity Manager"

    static func set(_ password: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func remove(account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}
