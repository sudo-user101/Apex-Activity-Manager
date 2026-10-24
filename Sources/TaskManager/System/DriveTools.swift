import Foundation

// Format a drive, or make it bootable from an image — one window, one flow:
// pick a device, pick a boot selection (Non bootable / disk or ISO image /
// macOS installer), choose partition scheme, label and file system, START.
//
// Safety: only drives that aren't the startup drive and aren't disk images;
// every operation is confirmed first; checks that would fail halfway (image
// too big, missing tool) run before anything is erased.

enum PartitionScheme: String, CaseIterable, Identifiable, Sendable {
    case gpt = "GPT", mbr = "MBR"
    var id: String { rawValue }
    var targetSystem: String { self == .gpt ? "UEFI (non CSM)" : "BIOS or UEFI" }
}

enum DriveFileSystem: String, CaseIterable, Identifiable, Sendable {
    case exfat = "exFAT", fat32 = "FAT32", apfs = "APFS", hfs = "Mac OS Extended (Journaled)"
    var id: String { rawValue }
    /// diskutil's personality name.
    var diskutil: String {
        switch self { case .exfat: return "ExFAT"; case .fat32: return "MS-DOS FAT32"; case .apfs: return "APFS"; case .hfs: return "JHFS+" }
    }
    var note: String {
        switch self {
        case .exfat: return "Works on Mac and Windows; no 4 GB file limit."
        case .fat32: return "Works almost everywhere; files up to 4 GB."
        case .apfs: return "Macs only (macOS 10.13 or later)."
        case .hfs: return "Macs only; also older Macs."
        }
    }
}

enum ImageKind: Equatable, Sendable {
    case windows(splitNeeded: Bool)   // copied file by file onto FAT32
    case raw                          // written as-is (Linux ISOs, .img)
    case macInstaller                 // "Install macOS ….app"
    case unsupported(String)

    var title: String {
        switch self {
        case .windows: return "Windows installer: files copied to a FAT32 drive (UEFI)"
        case .raw: return "Bootable image: written to the drive as-is (DD mode)"
        case .macInstaller: return "macOS installer: made with Apple’s createinstallmedia"
        case .unsupported(let why): return why
        }
    }
}

enum BootSelection: Equatable, Sendable {
    case nonBootable
    case image(URL, ImageKind)
}

struct DriveToolsPlan: Sendable {
    var device: StorageDevice
    var boot: BootSelection
    var scheme: PartitionScheme
    var fileSystem: DriveFileSystem
    var label: String
}

enum DriveTools {
    /// Drives that may be erased.
    static func eligible(_ devices: [StorageDevice]) -> [StorageDevice] {
        devices.filter { $0.connection != "Disk image" && (!$0.isInternal || $0.ejectable) && !$0.volumes.contains { $0.path == "/" } }
    }

    /// Names each file system accepts (FAT32: 11 characters, upper case).
    static func cleanLabel(_ s: String, for fs: DriveFileSystem) -> String {
        let allowed = s.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "_" || $0 == "-" }
        switch fs {
        case .fat32: return String(allowed.uppercased().prefix(11)).trimmingCharacters(in: .whitespaces).ifEmpty("UNTITLED")
        case .exfat: return String(allowed.prefix(15)).trimmingCharacters(in: .whitespaces).ifEmpty("Untitled")
        default: return String(allowed.prefix(63)).trimmingCharacters(in: .whitespaces).ifEmpty("Untitled")
        }
    }

    static let fat32MaxFile: UInt64 = 4_294_967_295

    /// Looks inside an image to decide how to write it.
    static func inspect(_ url: URL) -> ImageKind {
        if url.pathExtension.lowercased() == "app" {
            let tool = url.appendingPathComponent("Contents/Resources/createinstallmedia").path
            return FileManager.default.isExecutableFile(atPath: tool) ? .macInstaller
                : .unsupported("This app isn’t a macOS installer.")
        }
        let ext = url.pathExtension.lowercased()
        guard ["iso", "img", "raw", "bin"].contains(ext) else { return .unsupported("Choose an .iso or .img file, or a macOS installer app.") }
        if ext != "iso" { return .raw }
        // A Windows ISO has sources/install.wim (or .esd); it isn't bootable written raw.
        if let mount = mountImage(url) {
            defer { _ = Shell.run("/usr/bin/hdiutil", ["detach", mount, "-force"]) }
            let fm = FileManager.default
            let wim = mount + "/sources/install.wim"
            if fm.fileExists(atPath: wim) || fm.fileExists(atPath: mount + "/sources/install.esd") || fm.fileExists(atPath: mount + "/bootmgr") {
                let size = (try? fm.attributesOfItem(atPath: wim)[.size] as? NSNumber)?.uint64Value ?? 0
                let esd = (try? fm.attributesOfItem(atPath: mount + "/sources/install.esd")[.size] as? NSNumber)?.uint64Value ?? 0
                if esd > fat32MaxFile { return .unsupported("This Windows image’s install.esd is over 4 GB, which FAT32 can’t hold.") }
                return .windows(splitNeeded: size > fat32MaxFile)
            }
        }
        return hasBootSignature(url) ? .raw : .unsupported("This ISO isn’t bootable from USB (no boot record).")
    }

    /// Hybrid ISOs (most Linux ISOs) carry a PC boot record: 0x55AA at byte 510.
    static func hasBootSignature(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 512), d.count == 512 else { return false }
        return d[510] == 0x55 && d[511] == 0xAA
    }

    static func mountImage(_ url: URL) -> String? {
        let r = Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-plist", url.path])
        guard r.status == 0, let data = r.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let ents = plist["system-entities"] as? [[String: Any]] else { return nil }
        return ents.compactMap { $0["mount-point"] as? String }.first
    }

    static var wimlib: String? {
        ["/opt/homebrew/bin/wimlib-imagex", "/usr/local/bin/wimlib-imagex"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Problems to fix before anything is erased.
    static func preflight(_ plan: DriveToolsPlan) -> String? {
        guard eligible([plan.device]).count == 1 else { return "Apex won’t erase this drive." }
        switch plan.boot {
        case .nonBootable: return nil
        case .image(let url, let kind):
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            switch kind {
            case .unsupported(let why): return why
            case .raw where size > plan.device.size && plan.device.size > 0:
                return "The image (\(Fmt.diskBytes(size))) is bigger than the drive (\(Fmt.diskBytes(plan.device.size)))."
            case .windows(let split) where split && wimlib == nil:
                return "This Windows image has a file over 4 GB, which FAT32 can’t hold. Install wimlib so Apex can split it (in Terminal: brew install wimlib), then try again."
            case .macInstaller where plan.device.size > 0 && plan.device.size < 14_000_000_000:
                return "macOS installers need a drive of at least 16 GB."
            default: return nil
            }
        }
    }

    /// Parses the byte count from a dd `status=progress` line.
    static func ddBytes(_ log: String) -> UInt64? {
        let lines = log.components(separatedBy: CharacterSet(charactersIn: "\r\n")).filter { $0.contains("bytes") }
        guard let last = lines.last else { return nil }
        return last.split(separator: " ").first.flatMap { UInt64($0) }
    }

    /// Last "NN%" in createinstallmedia output.
    static func lastPercent(_ log: String) -> Double? {
        let scanner = log.components(separatedBy: CharacterSet(charactersIn: " .\r\n"))
        return scanner.compactMap { $0.hasSuffix("%") ? Double($0.dropLast()) : nil }.last.map { $0 / 100 }
    }

    // MARK: Running

    typealias Progress = @Sendable (_ fraction: Double?, _ status: String) -> Void

    final class CancelFlag: @unchecked Sendable { var cancelled = false }

    /// Runs the whole plan. Returns nil on success, or an error message.
    /// `beforeEject` runs on Windows installers once the files are on the
    /// drive (image and drive still mounted): answer file, verification.
    static func run(_ plan: DriveToolsPlan, cancel: CancelFlag, progress: @escaping Progress,
                    beforeEject: ((_ image: String, _ drive: String) -> String?)? = nil) -> String? {
        if let p = preflight(plan) { return p }
        let disk = "/dev/" + plan.device.id
        switch plan.boot {
        case .nonBootable:
            progress(nil, "Formatting…")
            let label = cleanLabel(plan.label, for: plan.fileSystem)
            return erase(disk, fs: plan.fileSystem.diskutil, label: label, scheme: plan.scheme)

        case .image(let url, .raw):
            progress(0, "Unmounting…")
            _ = Shell.run("/usr/sbin/diskutil", ["unmountDisk", "force", disk])
            let total = Double((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 1)
            let log = FileManager.default.temporaryDirectory.appendingPathComponent("apex-dd-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: log) }
            let raw = "/dev/r" + plan.device.id
            let cmd = "/bin/dd if=\(Shell.quote(url.path)) of=\(raw) bs=4m status=progress 2>\(Shell.quote(log.path)) && /bin/sync"
            let watcher = DispatchSource.makeTimerSource(queue: .global())
            watcher.schedule(deadline: .now() + 1, repeating: 0.5)
            watcher.setEventHandler {
                if let s = try? String(contentsOf: log, encoding: .utf8), let b = ddBytes(s) {
                    progress(min(1, Double(b) / total), "Writing image: \(Int(Double(b) / total * 100))%")
                }
            }
            watcher.resume()
            progress(0, "Writing image…")
            let r = Shell.runAsAdmin(cmd, prompt: "Apex Activity Manager wants to write “\(url.lastPathComponent)” to “\(plan.device.name)”. Everything on that drive will be erased.")
            watcher.cancel()
            if r.status != 0 { return Shell.isUserCancelled(r) ? "Cancelled." : "Writing failed: " + r.stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
            progress(1, "Ejecting…")
            _ = Shell.run("/usr/sbin/diskutil", ["eject", disk])
            return nil

        case .image(let url, .windows(let split)):
            let label = cleanLabel(plan.label.isEmpty ? "WINUSB" : plan.label, for: .fat32)
            progress(nil, "Formatting as FAT32…")
            if let e = erase(disk, fs: "MS-DOS FAT32", label: label, scheme: plan.scheme) { return e }
            guard let dest = mountPoint(of: disk) else { return "The drive didn’t mount after formatting." }
            progress(nil, "Opening the image…")
            guard let src = mountImage(url) else { return "Couldn’t open the image." }
            defer { _ = Shell.run("/usr/bin/hdiutil", ["detach", src, "-force"]) }
            let wim = src + "/sources/install.wim"
            if let e = copyTree(from: src, to: dest, skip: split ? [wim] : [], cancel: cancel, progress: progress) { return e }
            if split, let tool = wimlib {
                progress(nil, "Splitting install.wim for FAT32…")
                let r = Shell.run(tool, ["split", wim, dest + "/sources/install.swm", "3800"])
                if r.status != 0 { return "Splitting install.wim failed: " + r.stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            if let extra = beforeEject, let e = extra(src, dest) { return e }
            progress(1, "Ejecting…")
            _ = Shell.run("/usr/sbin/diskutil", ["eject", disk])
            return nil

        case .image(let app, .macInstaller):
            progress(nil, "Formatting…")
            if let e = erase(disk, fs: "JHFS+", label: "Untitled", scheme: .gpt) { return e }
            guard let dest = mountPoint(of: disk) else { return "The drive didn’t mount after formatting." }
            let tool = app.appendingPathComponent("Contents/Resources/createinstallmedia").path
            let log = FileManager.default.temporaryDirectory.appendingPathComponent("apex-cim-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: log) }
            let watcher = DispatchSource.makeTimerSource(queue: .global())
            watcher.schedule(deadline: .now() + 1, repeating: 1)
            watcher.setEventHandler {
                if let s = try? String(contentsOf: log, encoding: .utf8) {
                    let phase = s.contains("Copying") ? "Copying installer" : s.contains("Making disk bootable") ? "Making it bootable" : "Preparing"
                    progress(lastPercent(s), phase + "…")
                }
            }
            watcher.resume()
            let r = Shell.runAsAdmin("\(Shell.quote(tool)) --volume \(Shell.quote(dest)) --nointeraction >\(Shell.quote(log.path)) 2>&1",
                                     prompt: "Apex Activity Manager wants to make “\(plan.device.name)” a macOS installer. Everything on that drive will be erased.")
            watcher.cancel()
            if r.status != 0 { return Shell.isUserCancelled(r) ? "Cancelled." : "createinstallmedia failed: " + ((try? String(contentsOf: log, encoding: .utf8)) ?? r.stderr).suffix(300) }
            return nil

        case .image(_, .unsupported(let why)):
            return why
        }
    }

    private static func erase(_ disk: String, fs: String, label: String, scheme: PartitionScheme) -> String? {
        var r = Shell.run("/usr/sbin/diskutil", ["eraseDisk", fs, label, scheme.rawValue, disk])
        if r.status != 0, r.stderr.localizedCaseInsensitiveContains("permission") || r.stdout.localizedCaseInsensitiveContains("permission") {
            r = Shell.runAsAdmin("/usr/sbin/diskutil eraseDisk \(Shell.quote(fs)) \(Shell.quote(label)) \(scheme.rawValue) \(disk)",
                                 prompt: "Apex Activity Manager wants to erase this drive.")
        }
        if r.status == 0 { return nil }
        let msg = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return Shell.isUserCancelled(r) ? "Cancelled." : "Formatting failed: " + String(msg.suffix(300))
    }

    /// Mount point of the (first mounted) partition on a whole disk.
    static func mountPoint(of disk: String) -> String? {
        for _ in 0..<20 {
            let r = Shell.run("/usr/sbin/diskutil", ["list", "-plist", disk])
            if let d = r.stdout.data(using: .utf8),
               let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
               let all = p["AllDisksAndPartitions"] as? [[String: Any]] {
                for whole in all {
                    for part in (whole["Partitions"] as? [[String: Any]]) ?? [] {
                        if let m = part["MountPoint"] as? String, !m.isEmpty { return m }
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    /// Checks the copy: every file from the image is on the drive with the same
    /// size; with `full`, also byte for byte (reads everything back).
    static func verifyTree(from src: String, to dest: String, skip: Set<String>, full: Bool,
                           cancel: CancelFlag, progress: Progress) -> String? {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: src) else { return "Couldn’t read the image to verify." }
        var files: [(String, UInt64)] = []
        while let rel = en.nextObject() as? String {
            let full = src + "/" + rel
            if skip.contains(full) { continue }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            if !isDir.boolValue { files.append((rel, (try? fm.attributesOfItem(atPath: full)[.size] as? NSNumber)?.uint64Value ?? 0)) }
        }
        let total = max(1, files.reduce(0) { $0 + $1.1 })
        var done: UInt64 = 0
        for (rel, size) in files {
            if cancel.cancelled { return "Verification cancelled. The drive was written but not checked." }
            let copy = dest + "/" + rel
            let copied = (try? fm.attributesOfItem(atPath: copy)[.size] as? NSNumber)?.uint64Value
            guard copied == size else { return "Verification failed: “\(rel)” is missing or a different size on the drive. Try again with another drive or port." }
            if full {
                progress(Double(done) / Double(total), "Verifying: \(Int(Double(done) / Double(total) * 100))%")
                guard let a = FileHandle(forReadingAtPath: src + "/" + rel), let b = FileHandle(forReadingAtPath: copy) else { return "Verification couldn’t read “\(rel)”." }
                defer { try? a.close(); try? b.close() }
                while true {
                    let x = autoreleasepool { try? a.read(upToCount: 4 << 20) } ?? Data()
                    let y = autoreleasepool { try? b.read(upToCount: 4 << 20) } ?? Data()
                    if x != y { return "Verification failed: “\(rel)” differs on the drive. The drive or its connection may be faulty." }
                    if x.isEmpty { break }
                }
            }
            done += size
        }
        progress(1, full ? "Verified byte for byte" : "Verified: all files present")
        return nil
    }

    /// Copies a folder tree with byte-accurate progress.
    static func copyTree(from src: String, to dest: String, skip: Set<String>, cancel: CancelFlag, progress: Progress) -> String? {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: src) else { return "Couldn’t read the image." }
        var files: [(String, UInt64)] = []
        var dirs: [String] = []
        while let rel = en.nextObject() as? String {
            let full = src + "/" + rel
            if skip.contains(full) { continue }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            if isDir.boolValue { dirs.append(rel) }
            else { files.append((rel, (try? fm.attributesOfItem(atPath: full)[.size] as? NSNumber)?.uint64Value ?? 0)) }
        }
        let total = max(1, files.reduce(0) { $0 + $1.1 })
        for d in dirs { try? fm.createDirectory(atPath: dest + "/" + d, withIntermediateDirectories: true) }
        var done: UInt64 = 0
        for (rel, size) in files {
            if cancel.cancelled { return "Cancelled. The drive is only partly written; format it again before use." }
            if size > fat32MaxFile { return "“\(rel)” is over 4 GB and can’t go on FAT32." }
            progress(Double(done) / Double(total), "Copying files: \(Int(Double(done) / Double(total) * 100))%")
            do { try fm.copyItem(atPath: src + "/" + rel, toPath: dest + "/" + rel) }
            catch { return "Copying “\(rel)” failed: \(error.localizedDescription)" }
            done += size
        }
        progress(1, "Files copied")
        return nil
    }
}

private extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}
