import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Bootable Media Creator: Image → Drive → Customise → Review → Create.
/// Every option shown is one the chosen image supports; nothing is erased
/// before the Review step's explicit confirmation.
struct BootableCreatorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var deviceID: String

    enum Step: Int, CaseIterable { case image, drive, customise, review, create
        var title: String { ["Image", "Drive", "Customise", "Review", "Create"][rawValue] }
    }
    @State private var step: Step = .image
    @State private var image: BootImage?
    @State private var inspecting = false
    @State private var options = WindowsSetupOptions()
    @State private var useMacRegion = false
    @State private var drivers: String?
    @State private var scheme: PartitionScheme = .gpt
    @State private var verify = true
    @State private var fullVerify = false
    @State private var understood = false
    @State private var lockedRegistryID: UInt64?
    // Create
    @State private var running = false
    @State private var fraction: Double?
    @State private var status = ""
    @State private var result: String??          // nil running/not started; .some(nil) success; .some(msg) failure
    @State private var cancel = DriveTools.CancelFlag()

    private var devices: [StorageDevice] { DriveTools.eligible(model.snapshot.system.storageDevices) }
    private var device: StorageDevice? { devices.first { $0.id == deviceID } }
    private var problem: String? { image.flatMap { img in device.flatMap { BootMedia.validate(img, on: $0) } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                Group {
                    switch step {
                    case .image: imageStep
                    case .drive: driveStep
                    case .customise: customiseStep
                    case .review: reviewStep
                    case .create: createStep
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 600)
    }

    // MARK: Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "opticaldiscdrive.fill").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Bootable Media Creator").font(.title2).bold()
                    Text("Make a USB installer from an image you already have.").foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    HStack(spacing: 6) {
                        ZStack {
                            Circle().fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25)).frame(width: 20, height: 20)
                            if s.rawValue < step.rawValue { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white) }
                            else { Text("\(s.rawValue + 1)").font(.caption2.bold()).foregroundStyle(s == step ? .white : .secondary) }
                        }
                        Text(s.title).font(.callout.weight(s == step ? .semibold : .regular)).foregroundStyle(s == step ? .primary : .secondary)
                            .lineLimit(1).fixedSize()
                    }
                    if s != .create { Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1).frame(maxWidth: .infinity) }
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    private var footer: some View {
        HStack {
            if step == .create {
                if running { Button("Cancel") { cancel.cancelled = true }.keyboardShortcut(.cancelAction) }
                Spacer()
                if !running {
                    if case .some(.some) = result { Button("Back to Review") { step = .review; result = nil } }
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if step != .image { Button("Back") { step = Step(rawValue: step.rawValue - 1)! } }
                if step == .review {
                    Button("Erase and Create") { start() }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .disabled(!understood || problem != nil || device?.registryID != lockedRegistryID)
                } else {
                    Button("Continue") { advance() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(!canContinue)
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    private var canContinue: Bool {
        switch step {
        case .image: if let image, case .unsupported = image.kind { return false }; return image != nil && !inspecting
        case .drive: return device != nil && problem == nil
        default: return true
        }
    }

    private func advance() {
        if step == .drive { lockedRegistryID = device?.registryID }
        if step == .customise { options.locale = useMacRegion ? Self.macLocale : "" ; understood = false }
        // Images without setup options skip Customise only if there's nothing to set there.
        step = Step(rawValue: step.rawValue + 1)!
    }

    static var macLocale: String {
        let l = Locale.current
        return [l.language.languageCode?.identifier, l.region?.identifier].compactMap { $0 }.joined(separator: "-")
    }

    // MARK: 1 Image

    private var imageStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose an image").font(.title3.weight(.semibold))
            Text("A Windows or Linux .iso, a disk image (.img), or a macOS installer app from Apple. Apex doesn’t download or include any operating system; use one you got from its maker.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { choose() } label: {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 30)).foregroundStyle(.tint)
                    Text(image == nil ? "Choose Image… or drop it here" : "Choose a Different Image…").font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: 110)
                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])).foregroundStyle(.tertiary))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { load(url) } }
                }
                return true
            }
            if inspecting { HStack { ProgressView().controlSize(.small); Text("Looking inside the image…").foregroundStyle(.secondary) } }
            if let img = image, !inspecting { imageCard(img) }
        }
    }

    private func imageCard(_ img: BootImage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon(img.kind)).font(.title).foregroundStyle(usable(img.kind) ? Color.accentColor : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(img.title).font(.headline)
                    Text("\(img.url.lastPathComponent) · \(Fmt.diskBytes(img.size))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if img.windows?.isWindows11 == true { Text("Windows 11").font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3).background(.blue.opacity(0.15), in: Capsule()) }
            }
            Label(img.kind.title, systemImage: usable(img.kind) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(usable(img.kind) ? .green : .orange).fixedSize(horizontal: false, vertical: true)
            if let w = img.windows, !w.editions.isEmpty {
                Text("Editions: " + w.editions.prefix(8).map(\.name).joined(separator: ", ") + (w.editions.count > 8 ? "…" : ""))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Windows Setup asks which edition to install; your licence decides which one you can activate.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if case .windows(true) = img.kind {
                Label(DriveTools.wimlib == nil ? "Its install.wim is over 4 GB. Apex splits it with wimlib, which isn’t installed (Terminal: brew install wimlib)."
                                               : "Its install.wim is over 4 GB; Apex splits it into parts FAT32 can hold.",
                      systemImage: "scissors").font(.callout).foregroundStyle(DriveTools.wimlib == nil ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 2 Drive

    private var driveStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose the USB drive").font(.title3.weight(.semibold))
            Text("Everything on it will be erased. Only removable drives are listed; your Mac’s own drives never are.")
                .foregroundStyle(.secondary)
            if devices.isEmpty {
                Label("Plug in a USB drive (8 GB or larger). It appears here as soon as macOS sees it.", systemImage: "externaldrive.badge.plus")
                    .foregroundStyle(.secondary).padding(.vertical, 20)
            }
            ForEach(devices) { d in
                Button { deviceID = d.id } label: {
                    HStack(spacing: 12) {
                        Image(systemName: d.id == deviceID ? "largecircle.fill.circle" : "circle").foregroundStyle(d.id == deviceID ? Color.accentColor : .secondary)
                        Image(systemName: d.symbol).font(.title2).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name).font(.headline)
                            Text([d.model, Fmt.diskBytes(d.size), d.usb?.short ?? d.connection].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            if !d.volumes.isEmpty {
                                Text("On it now: " + d.volumes.map { "\($0.name) (\(Fmt.diskBytes($0.capacity - min($0.capacity, $0.available))) used)" }.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                    }
                    .padding(12).contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 10).fill(d.id == deviceID ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.03)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(d.id == deviceID ? Color.accentColor : .clear))
                }
                .buttonStyle(.plain)
            }
            if let p = problem { Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
    }

    // MARK: 3 Customise

    @ViewBuilder private var customiseStep: some View {
        if let img = image, img.supportsWindowsOptions {
            VStack(alignment: .leading, spacing: 16) {
                Text("Windows setup options").font(.title3.weight(.semibold))
                Text("Apex adds an answer file (autounattend.xml) to the USB drive. Windows Setup reads it; the Windows image itself isn’t changed. Leave everything off for a normal installation.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                if img.supportsHardwareBypass {
                    group("Windows 11 hardware checks", note: "For older PCs Windows 11 doesn’t officially support. Microsoft may not provide every update to such PCs, and turning off Secure Boot checks lowers protection against boot-level malware. Your Mac isn’t affected.") {
                        Toggle("Skip the TPM 2.0 check", isOn: $options.skipTPM)
                        Toggle("Skip the Secure Boot check", isOn: $options.skipSecureBoot)
                        Toggle("Skip the 4 GB memory check", isOn: $options.skipRAM)
                    }
                }
                group("Account", note: "A local account works without a Microsoft account. It starts with no password and Windows asks you to set one the first time you sign in.") {
                    Toggle("Allow setting up without internet or a Microsoft account", isOn: $options.allowOfflineAccount)
                    HStack {
                        Text("Create a local account")
                        TextField("Name (optional)", text: $options.localAccount).textFieldStyle(.roundedBorder).frame(width: 200)
                    }
                }
                group("Region and privacy", note: nil) {
                    Toggle("Use this Mac’s region and keyboard (\(Self.macLocale))", isOn: $useMacRegion)
                    let tz = Autounattend.windowsTimeZone()
                    if !tz.isEmpty {
                        Toggle("Use this Mac’s time zone (\(tz))", isOn: Binding(get: { options.timeZone == tz },
                                                                                set: { options.timeZone = $0 ? tz : "" }))
                    }
                    Toggle("Choose the most private answers to Windows’ privacy questions", isOn: $options.minimalPrivacy)
                }
                group("This PC", note: "Device encryption normally turns on by itself and needs your Microsoft account to unlock if something changes. Turning it off lets you switch on BitLocker yourself later, once you've saved the recovery key.") {
                    HStack {
                        Text("Computer name")
                        TextField("Optional, e.g. OFFICE-PC", text: $options.computerName).textFieldStyle(.roundedBorder).frame(width: 200)
                        if !options.computerName.isEmpty && Autounattend.cleanComputerName(options.computerName) != options.computerName {
                            Text("→ \(Autounattend.cleanComputerName(options.computerName))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Don’t turn on device encryption automatically", isOn: $options.noAutoEncryption)
                }
                group("Drivers", note: "For PCs whose disk or Wi-Fi Windows Setup doesn't see (common on new laptops with Intel RST / VMD, or new Wi-Fi chips). Get the drivers from the PC maker; Apex copies the folder to the drive as $WinPEDriver$, which Windows Setup loads by itself during setup and into the new Windows.") {
                    HStack {
                        Text(drivers.map { (($0 as NSString).lastPathComponent) } ?? "No drivers added").foregroundStyle(drivers == nil ? .secondary : .primary)
                        Spacer()
                        if drivers != nil { Button("Remove") { drivers = nil } }
                        Button("Choose Folder…") { chooseDrivers() }
                    }
                }
                group("Apps to install at first sign-in", note: "Installed with winget, Windows’ own package manager, from each app’s official source. Needs an internet connection at first sign-in and takes a few minutes after the desktop appears. Windows 10 PCs without the App Installer update skip this.") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(WindowsApp.catalogue) { app in
                            Toggle(app.name, isOn: Binding(get: { options.apps.contains(app.id) },
                                                           set: { if $0 { options.apps.append(app.id) } else { options.apps.removeAll { $0 == app.id } } }))
                        }
                    }
                }
                advanced(canVerify: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Nothing to customise").font(.title3.weight(.semibold))
                Text(image?.kind == .macInstaller
                     ? "macOS installers are made with Apple’s own tool (createinstallmedia), which has no setup options."
                     : "This image is written to the drive exactly as it is, which is how Linux and other bootable images are meant to be used. Setup options depend on that system’s own installer.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if image?.kind == .raw {
                    Text("Writing a raw image needs your administrator password. Apex can’t read it back afterwards without it, so this kind isn’t verified.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func advanced(canVerify: Bool) -> some View {
        group("Advanced", note: nil) {
            Picker("Partition scheme", selection: $scheme) {
                Text("GPT, for UEFI PCs (most PCs since 2012)").tag(PartitionScheme.gpt)
                Text("MBR, for older BIOS PCs").tag(PartitionScheme.mbr)
            }
            Toggle("Check every file after copying", isOn: $verify)
            Toggle("Compare byte for byte (slower: reads the whole drive back)", isOn: $fullVerify).disabled(!verify).padding(.leading, 20)
        }
    }

    private func group<C: View>(_ title: String, note: String?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
            if let note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: 4 Review

    @ViewBuilder private var reviewStep: some View {
        if let img = image, let d = device {
            VStack(alignment: .leading, spacing: 14) {
                Text("Review").font(.title3.weight(.semibold))
                Label("Everything on “\(d.name)” (\(d.model.isEmpty ? "" : d.model + ", ")\(Fmt.diskBytes(d.size))) will be erased. This can’t be undone.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    reviewRow("Image", img.title)
                    reviewRow("Drive", "\(d.name) · \(d.id) · \(Fmt.diskBytes(d.size))")
                    reviewRow("How", method(img))
                    if img.supportsWindowsOptions {
                        reviewRow("Setup options", summary(options, img))
                        if !options.apps.isEmpty {
                            reviewRow("Apps at first sign-in", options.apps.compactMap { id in WindowsApp.catalogue.first { $0.id == id }?.name }.joined(separator: ", "))
                        }
                        reviewRow("Check", verify ? (fullVerify ? "Byte for byte" : "Every file present, same size") : "No")
                    }
                }
                .padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                if device?.registryID != lockedRegistryID {
                    Label("The drive changed since you chose it. Go back and choose it again.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if let p = problem { Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                Toggle("I understand that everything on “\(d.name)” will be erased", isOn: $understood)
            }
        } else {
            Label("The drive was unplugged. Go back and choose a drive.", systemImage: "externaldrive.badge.xmark").foregroundStyle(.orange)
        }
    }

    private func reviewRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(v).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private func method(_ img: BootImage) -> String {
        switch img.kind {
        case .windows(let split): return "Format as FAT32 (\(scheme.rawValue)), copy the installer files" + (split ? ", split install.wim" : "") + (options.isEmpty ? "" : ", add autounattend.xml")
        case .raw: return "Write the image to the drive as it is (needs your administrator password)"
        case .macInstaller: return "Apple’s createinstallmedia (needs your administrator password)"
        case .unsupported(let why): return why
        }
    }

    private func summary(_ o: WindowsSetupOptions, _ img: BootImage) -> String {
        var s: [String] = []
        if o.skipTPM { s.append("skip TPM check") }
        if o.skipSecureBoot { s.append("skip Secure Boot check") }
        if o.skipRAM { s.append("skip memory check") }
        if o.allowOfflineAccount { s.append("offline setup allowed") }
        let name = Autounattend.cleanAccountName(o.localAccount)
        if !name.isEmpty { s.append("local account “\(name)”") }
        if !o.locale.isEmpty { s.append("region \(o.locale)") }
        if o.minimalPrivacy { s.append("most private answers") }
        let pc = Autounattend.cleanComputerName(o.computerName)
        if !pc.isEmpty { s.append("PC name “\(pc)”") }
        if !o.timeZone.isEmpty { s.append("time zone \(o.timeZone)") }
        if o.noAutoEncryption { s.append("no automatic device encryption") }
        if drivers != nil { s.append("drivers added") }
        return s.isEmpty ? "None (a normal Windows installation)" : s.joined(separator: ", ").prefix(1).uppercased() + s.joined(separator: ", ").dropFirst()
    }

    // MARK: 5 Create

    @ViewBuilder private var createStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch result {
            case .none:
                Text("Creating…").font(.title3.weight(.semibold))
                if let f = fraction { ProgressView(value: f).progressViewStyle(.linear) } else { ProgressView().progressViewStyle(.linear) }
                Text(status).foregroundStyle(.secondary).monospacedDigit()
                Text("Keep the drive plugged in. Cancelling leaves it partly written; format it before using it again.")
                    .font(.caption).foregroundStyle(.tertiary)
            case .some(.none):
                Label("Your installer is ready", systemImage: "checkmark.seal.fill").font(.title2.weight(.semibold)).foregroundStyle(.green)
                Text("The drive has been ejected. To use it:").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    if image?.kind == .macInstaller {
                        Text("1. Plug it into the Mac you want to install on.")
                        Text("2. Apple silicon: hold the power button until startup options appear. Intel: hold Option while starting.")
                        Text("3. Choose the installer.")
                    } else {
                        Text("1. Plug it into the PC and switch it on.")
                        Text("2. Press the boot menu key straight away (often F12, F11, F8 or Esc) and choose the USB drive.")
                        Text("3. If the PC doesn’t list it, turn on USB boot in its firmware settings" + (scheme == .mbr ? " (legacy/CSM mode for MBR)." : "."))
                        if !options.isEmpty { Text("4. Windows Setup applies your options by itself; you still pick the edition and the disk to install on.") }
                    }
                }
            case .some(.some(let msg)):
                Label("Couldn’t finish", systemImage: "xmark.octagon.fill").font(.title2.weight(.semibold)).foregroundStyle(.red)
                Text(msg).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Text("If it keeps failing: try another USB port (directly on the Mac, not a hub), another drive, or check the image file isn’t damaged.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Actions

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "iso"), UTType(filenameExtension: "img"), .diskImage, .applicationBundle].compactMap { $0 }
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = "Choose an .iso, .img or macOS installer"
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    private func load(_ url: URL) {
        inspecting = true; image = nil; options = WindowsSetupOptions()
        Task {
            image = await Task.detached(priority: .userInitiated) { BootMedia.inspect(url) }.value
            inspecting = false
        }
    }

    private func chooseDrivers() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.message = "Choose the folder with the PC's drivers (.inf files and their files)"
        if p.runModal() == .OK, let u = p.url { drivers = u.path }
    }

    private func start() {
        guard let img = image, let d = device, d.registryID == lockedRegistryID, understood, problem == nil else { return }
        step = .create; running = true; result = nil; fraction = nil; status = "Starting…"
        cancel = DriveTools.CancelFlag()
        let job = BootMedia.Job(image: img, device: d, scheme: scheme, label: "", options: options, drivers: drivers,
                                verify: verify && img.canVerify, fullVerify: fullVerify)
        let flag = cancel
        Task {
            let r = await Task.detached(priority: .userInitiated) {
                BootMedia.run(job, cancel: flag) { f, s in
                    DispatchQueue.main.async { fraction = f; status = s }
                }
            }.value
            result = .some(r)
            running = false
        }
    }

    private func usable(_ k: ImageKind) -> Bool { if case .unsupported = k { return false }; return true }
    private func icon(_ k: ImageKind) -> String {
        switch k { case .windows: return "pc"; case .macInstaller: return "apple.logo"; case .raw: return "opticaldisc"; case .unsupported: return "questionmark.circle" }
    }
}
