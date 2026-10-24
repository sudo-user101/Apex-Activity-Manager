import SwiftUI
import UniformTypeIdentifiers

/// Format a drive or make it bootable — one window: Drive Properties,
/// Format Options, Status, then START / CLOSE. One window, top to bottom.
struct DriveToolsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let startBootable: Bool
    @State var deviceID: String

    @State private var bootChoice = 0               // 0 Non bootable, 1 Disk or ISO image, 2 macOS installer
    @State private var image: URL?
    @State private var kind: ImageKind?
    @State private var inspecting = false
    @State private var scheme: PartitionScheme = .gpt
    @State private var fileSystem: DriveFileSystem = .exfat
    @State private var label = ""
    @State private var running = false
    @State private var fraction: Double?
    @State private var status = "READY"
    @State private var failed = false
    @State private var confirm = false
    @State private var cancel = DriveTools.CancelFlag()

    private var devices: [StorageDevice] { DriveTools.eligible(model.snapshot.system.storageDevices) }
    private var device: StorageDevice? { devices.first { $0.id == deviceID } }

    private var plan: DriveToolsPlan? {
        guard let d = device else { return nil }
        let boot: BootSelection
        switch bootChoice {
        case 0: boot = .nonBootable
        default:
            guard let image, let kind else { return nil }
            boot = .image(image, kind)
        }
        return DriveToolsPlan(device: d, boot: boot, scheme: scheme, fileSystem: effectiveFS, label: label)
    }

    /// Bootable modes decide the file system themselves.
    private var effectiveFS: DriveFileSystem {
        switch kind {
        case .windows?: return .fat32
        case .macInstaller?: return .hfs
        default: return fileSystem
        }
    }
    private var fsLocked: Bool { bootChoice != 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Drive Properties")
            field("Device") {
                Picker("", selection: $deviceID) {
                    if devices.isEmpty { Text("No drive plugged in").tag(deviceID) }
                    ForEach(devices) { d in
                        Text("\(d.name) (\(d.id)) [\(Fmt.diskBytes(d.size))]" + (d.usb.map { " · \($0.short)" } ?? "")).tag(d.id)
                    }
                }
                .labelsHidden()
            }
            field("Boot selection") {
                HStack {
                    Picker("", selection: $bootChoice) {
                        Text("Non bootable").tag(0)
                        Text("Disk or ISO image (please select)").tag(1)
                        Text("macOS installer app").tag(2)
                    }
                    .labelsHidden()
                    Button("SELECT") { choose() }.disabled(bootChoice == 0 || running)
                }
            }
            if bootChoice != 0 {
                HStack(spacing: 6) {
                    if inspecting { ProgressView().controlSize(.small); Text("Looking inside the image…") }
                    else if let image, let kind {
                        Image(systemName: isUsable(kind) ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(isUsable(kind) ? .green : .orange)
                        Text("\(image.lastPathComponent): \(kind.title)")
                    } else { Text("Click SELECT to choose " + (bootChoice == 1 ? "an .iso or .img file." : "an “Install macOS” app.")) }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(alignment: .top, spacing: 16) {
                field("Partition scheme") {
                    Picker("", selection: $scheme) { ForEach(PartitionScheme.allCases) { Text($0.rawValue).tag($0) } }
                        .labelsHidden().disabled(kind == .macInstaller)
                }
                field("Target system") {
                    Text(kind == .macInstaller ? "Mac (Apple Silicon or Intel)" : scheme.targetSystem)
                        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                        .padding(.horizontal, 6)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                }
            }

            section("Format Options")
            field("Volume label") {
                TextField("", text: $label).textFieldStyle(.roundedBorder)
                    .disabled(kind == .macInstaller || (bootChoice != 0 && kind == .raw))
            }
            field("File system") {
                Picker("", selection: $fileSystem) { ForEach(DriveFileSystem.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().disabled(fsLocked)
            }
            Text(fsNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            section("Status")
            ZStack {
                if let f = fraction { ProgressView(value: f).progressViewStyle(.linear) }
                else if running { ProgressView().progressViewStyle(.linear) }
                else { ProgressView(value: status == "DONE" ? 1 : 0).progressViewStyle(.linear) }
                Text(status).font(.callout.weight(.medium)).foregroundStyle(failed ? .red : .primary)
                    .padding(.horizontal, 8).background(.background.opacity(0.85), in: Capsule())
            }
            .frame(height: 26)

            HStack {
                if let d = device {
                    Text("\(d.connection == "USB" || d.usb != nil ? (d.usb?.connectedAs ?? "USB") : d.connection) · \(d.model)")
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                Button(running ? "CANCEL" : "START") { running ? (cancel.cancelled = true) : (confirm = true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!running && (plan == nil || inspecting || (kind.map { !isUsable($0) } ?? false)))
                Button("CLOSE") { dismiss() }.disabled(running).keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 480)
        .onAppear {
            if startBootable { bootChoice = 1 }
            label = device?.name ?? ""
        }
        .onChange(of: bootChoice) { image = nil; kind = nil; status = "READY"; failed = false }
        .onChange(of: deviceID) { label = device?.name ?? label }
        .alert("WARNING: ALL DATA ON DEVICE “\(device?.name ?? "")” (\(device.map { Fmt.diskBytes($0.size) } ?? "")) WILL BE DESTROYED.",
               isPresented: $confirm) {
            Button("Erase and Continue", role: .destructive) { start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To continue with this operation, click Erase and Continue. This can’t be undone.")
        }
    }

    private var fsNote: String {
        switch kind {
        case .windows(let split)?: return "Windows images go on FAT32 so UEFI PCs can boot them" + (split ? "; the 4 GB+ install file is split with wimlib." : ".")
        case .raw?: return "The image replaces everything on the drive, including its partitions and name."
        case .macInstaller?: return "Apple’s installer needs Mac OS Extended; the drive is named by the installer."
        default: return effectiveFS.note
        }
    }

    private func isUsable(_ k: ImageKind) -> Bool { if case .unsupported = k { return false }; return true }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if bootChoice == 2 {
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
            panel.message = "Choose an “Install macOS” app"
        } else {
            panel.allowedContentTypes = ["iso", "img", "raw", "bin"].compactMap { UTType(filenameExtension: $0) } + [.diskImage]
            panel.message = "Choose a bootable .iso or .img file"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        image = url; kind = nil; inspecting = true; status = "READY"; failed = false
        Task {
            let k = await Task.detached(priority: .userInitiated) { DriveTools.inspect(url) }.value
            kind = k; inspecting = false
            if case .windows = k { scheme = .gpt; label = "WINUSB" }
        }
    }

    private func start() {
        guard let plan else { return }
        running = true; failed = false; fraction = nil; status = "Starting…"
        cancel = DriveTools.CancelFlag()
        let flag = cancel
        Task {
            let error = await Task.detached(priority: .userInitiated) {
                DriveTools.run(plan, cancel: flag) { f, s in
                    Task { @MainActor in fraction = f; status = s }
                }
            }.value
            running = false
            DeviceWatcher.shared.bump()
            if let error { failed = true; fraction = nil; status = error }
            else { fraction = 1; status = "DONE" }
        }
    }

    private func section(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            VStack { Divider() }
        }
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
