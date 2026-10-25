import Foundation

/// Bootable Media Creator: image inspection, validation and the job that
/// writes it. Writing itself is `DriveTools.run` (erase, copy or raw write);
/// this layer adds what the image supports, Windows Setup options and checks.
struct BootImage: Sendable {
    var url: URL
    var size: UInt64
    var kind: ImageKind
    var windows: WindowsImageInfo?
    var label = ""                     // volume name of an ISO, e.g. "Ubuntu 24.04 LTS amd64"

    var title: String {
        if let w = windows { return w.title }
        switch kind {
        case .macInstaller: return url.deletingPathExtension().lastPathComponent
        case .raw: return label.isEmpty ? url.lastPathComponent : label
        default: return url.lastPathComponent
        }
    }

    /// What can be customised for this image (only options it really supports).
    var supportsWindowsOptions: Bool { if case .windows = kind { return true }; return false }
    var supportsHardwareBypass: Bool { windows?.isWindows11 == true }
    var canVerify: Bool { if case .windows = kind { return true }; return false }
}

enum BootMedia {
    static func inspect(_ url: URL) -> BootImage {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        var img = BootImage(url: url, size: size, kind: DriveTools.inspect(url))
        if case .unsupported = img.kind { return img }
        // ISOs: the volume name says what it is; Windows images list their editions.
        if url.pathExtension.lowercased() == "iso", let m = DriveTools.mountImage(url) {
            defer { _ = Shell.run("/usr/bin/hdiutil", ["detach", m, "-force"]) }
            img.label = (m as NSString).lastPathComponent
            if case .windows = img.kind {
                img.windows = WindowsImage.read(m + "/sources/install.wim") ?? WindowsImage.read(m + "/sources/install.esd")
            }
        }
        return img
    }

    /// Problems with this image on this drive, before anything is erased.
    static func validate(_ img: BootImage, on device: StorageDevice) -> String? {
        let plan = DriveToolsPlan(device: device, boot: .image(img.url, img.kind), scheme: .gpt, fileSystem: .fat32, label: "")
        if let p = DriveTools.preflight(plan) { return p }
        if case .windows = img.kind, device.size > 0, device.size < 8_000_000_000 { return "Windows installers need a drive of at least 8 GB." }
        if case .windows = img.kind, img.size > device.size, device.size > 0 { return "The image is bigger than the drive." }
        return nil
    }

    static let driversFolder = "$WinPEDriver$"

    struct Job: Sendable {
        var image: BootImage
        var device: StorageDevice
        var scheme: PartitionScheme = .gpt
        var label = ""
        var options = WindowsSetupOptions()
        /// A folder of drivers on this Mac, copied to the drive as `$WinPEDriver$`
        /// (Windows Setup loads it by itself, during setup and into the new Windows).
        var drivers: String?
        var verify = true
        var fullVerify = false
    }

    /// Runs the job. nil on success, else what went wrong (and what to do).
    static func run(_ job: Job, cancel: DriveTools.CancelFlag, progress: @escaping DriveTools.Progress) -> String? {
        if let e = validate(job.image, on: job.device) { return e }
        let plan = DriveToolsPlan(device: job.device, boot: .image(job.image.url, job.image.kind), scheme: job.scheme,
                                  fileSystem: .fat32, label: job.label)
        let lang = job.image.windows?.editions.first?.languages.first ?? "en-US"
        let arch = job.image.windows?.arch ?? .unknown
        return DriveTools.run(plan, cancel: cancel, progress: progress) { src, dest in
            if let xml = Autounattend.xml(job.options, arch: arch, imageLanguage: lang) {
                progress(nil, "Adding your setup options…")
                do { try xml.write(toFile: dest + "/" + Autounattend.fileName, atomically: false, encoding: .utf8) }
                catch { return "Couldn’t write the setup options: \(error.localizedDescription)" }
            }
            if let d = job.drivers {
                progress(nil, "Adding your drivers…")
                do { try FileManager.default.copyItem(atPath: d, toPath: dest + "/" + BootMedia.driversFolder) }
                catch { return "Couldn’t copy the drivers: \(error.localizedDescription)" }
            }
            guard job.verify else { return nil }
            let wim = src + "/sources/install.wim"
            let split: Bool = { if case .windows(let s) = job.image.kind { return s }; return false }()
            return DriveTools.verifyTree(from: src, to: dest, skip: split ? [wim] : [], full: job.fullVerify,
                                         cancel: cancel, progress: progress)
        }
    }
}
