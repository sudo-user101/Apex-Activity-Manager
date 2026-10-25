import AVFoundation
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// The menu bar panel: five tabs (Monitor, Energy, Shelf, Clipboard, Sessions).
/// Triple-clicking the menu bar icon opens the app (StatusBar).
struct MenuBarPanel: View {
    @AppStorage("menuTab") private var tab = "monitor"

    private let tabs: [(key: String, title: String, symbol: String)] = [
        ("monitor", "Monitor", "gauge.with.dots.needle.33percent"),
        ("energy", "Energy", "bolt.fill"),
        ("shelf", "Shelf", "tray.full"),
        ("clipboard", "Clipboard", "doc.on.clipboard"),
        ("sessions", "Sessions: close your apps now, reopen them later", "rectangle.stack"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 2) {
                ForEach(tabs, id: \.key) { t in
                    let on = t.key == tab
                    Button { tab = t.key } label: {
                        Image(systemName: t.symbol)
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .background(on ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(on ? Color.white : .secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(t.title)
                }
                Menu {
                    Button("Settings…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil); NSApp.activate(ignoringOtherApps: true) }
                    Divider()
                    Button("Quit Apex") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Settings and Quit. Triple-click the menu bar icon to open Apex.")
            }
            .padding(2)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))

            switch tab {
            case "energy": EnergyTab()
            case "shelf": ShelfTab()
            case "clipboard": ClipboardTab()
            case "sessions": SessionsTab()
            default: MonitorTab()
            }
        }
        .padding(12)
        .frame(width: 360)
    }
}

// MARK: Monitor

private struct MonitorTab: View {
    @Environment(AppModel.self) private var model
    private let hw = HardwareStore.shared

    var body: some View {
        let s = model.snapshot.system, h = model.history, t = hw.sensors
        let level = s.memory.pressureLevel
        VStack(alignment: .leading, spacing: 10) {
            row("CPU", Fmt.percent(s.cpu.total, decimals: 0) + "%", temp(t.cpuTemp),
                LineGraph(series: [.init(values: h.cpu, color: .blue)], gridLines: false, cornerRadius: 4))
            row("GPU", s.gpu.utilization.map { Fmt.percent($0, decimals: 0) + "%" } ?? "—", temp(t.gpuTemp),
                LineGraph(series: [.init(values: h.gpu, color: .pink)], gridLines: false, cornerRadius: 4))
            // Memory pressure, coloured like the Memory page: green Normal, yellow Elevated, red Critical.
            row("Memory", Fmt.bytes(s.memory.used) + " of " + Fmt.bytes(s.memory.total), nil,
                PressureGraph(values: h.pressure, levels: h.pressureLevels),
                badge: (level.title, level.color))
            row("Disk", "R \(Fmt.rate(s.disk.readPerSec))  W \(Fmt.rate(s.disk.writePerSec))", temp(t.average("Storage")),
                LineGraph(series: [.init(values: h.diskRead, color: .green), .init(values: h.diskWrite, color: .red, fill: false)],
                          maxValue: nil, gridLines: false, cornerRadius: 4))
            row("Network", "↓ \(Fmt.rate(s.network.inPerSec))  ↑ \(Fmt.rate(s.network.outPerSec))", nil,
                LineGraph(series: [.init(values: h.netIn, color: .orange), .init(values: h.netOut, color: .blue, fill: false)],
                          maxValue: nil, gridLines: false, cornerRadius: 4))
            row("Temperatures", [t.cpuTemp.map { String(format: "CPU %.0f°", $0) }, t.gpuTemp.map { String(format: "GPU %.0f°", $0) }]
                    .compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "—", nil,
                LineGraph(series: [.init(values: hw.cpuTempHistory, color: .red), .init(values: hw.gpuTempHistory, color: .orange, fill: false)],
                          maxValue: 110, gridLines: false, cornerRadius: 4))
        }
        .task {
            // Temperatures are read only while someone is looking.
            while !Task.isCancelled {
                await hw.poll()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func temp(_ c: Double?) -> String? { c.map { String(format: "%.0f °C", $0) } }

    private func row<G: View>(_ label: String, _ value: String, _ temp: String?, _ graph: G,
                              badge: (String, Color)? = nil) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    if let badge {
                        Text(badge.0).font(.caption2.weight(.semibold)).foregroundStyle(badge.1)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(badge.1.opacity(0.18), in: Capsule())
                    }
                }
                Text(value).font(.callout.weight(.medium)).monospacedDigit().lineLimit(1)
                if let temp { Text(temp).font(.caption2).foregroundStyle(.secondary).monospacedDigit() }
            }
            Spacer(minLength: 8)
            graph.frame(width: 130, height: 34)
        }
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

// MARK: Energy

private struct EnergyTab: View {
    @Environment(AppModel.self) private var model
    @State private var duration: TimeInterval? = 3600
    @State private var displayOn = false
    private let awake = KeepAwake.shared
    private let hw = HardwareStore.shared

    var body: some View {
        let b = hw.battery
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: hw.hasBattery ? (b.onAC ? "battery.100.bolt" : "battery.75") : "powerplug")
                    .font(.title2).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(hw.hasBattery ? "\(b.percent)% · " + (b.onAC ? "On power" : "On battery") : "On power")
                        .font(.callout.weight(.medium))
                    Text(["Power mode: " + PowerMode.current().title,
                          b.systemPower.map { String(format: "using %.1f W", $0) } ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep awake").font(.callout.weight(.medium))
                    Text(awake.isOn ? awake.remainingText() : "Off: your Mac sleeps as usual")
                        .font(.caption).foregroundStyle(awake.isOn ? Color.green : .secondary).monospacedDigit()
                }
                Spacer()
                Toggle("", isOn: Binding(get: { awake.isOn }, set: { on in
                    if on { awake.start(for: duration, keepDisplayOn: displayOn) } else { awake.stop() }
                }))
                .toggleStyle(.switch).labelsHidden()
            }
            HStack {
                Text("For").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { duration ?? -1 }, set: { v in
                    duration = v < 0 ? nil : v
                    if awake.isOn { awake.start(for: duration, keepDisplayOn: displayOn) }
                })) {
                    ForEach(KeepAwake.choices, id: \.0) { c in Text(c.0).tag(c.1 ?? -1) }
                }
                .labelsHidden().fixedSize()
                Spacer()
                Toggle("Keep display on", isOn: Binding(get: { displayOn }, set: { displayOn = $0; awake.setDisplayOn($0) }))
                    .toggleStyle(.checkbox)
            }
            .font(.callout)
            Text("Works while the lid is open. With the display off, downloads and uploads carry on.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { displayOn = awake.displayOn }
        .task { if !hw.loaded { await hw.poll() } }
    }
}

// MARK: Shelf

/// The shelf: in the menu bar panel and in the floating shelf (`FloatingShelf`).
/// A grid of thumbnails; right-click an item to compress (any file: photos and
/// videos re-encoded, PDFs slimmed, the rest zipped), convert, show or remove it.
struct ShelfTab: View {
    /// Floating shelf only: its close button (ends this shelf).
    var onClose: (() -> Void)? = nil
    /// Floating shelf only: minimize (fades it away, then runs the action).
    var onMinimize: ((@escaping @MainActor () -> Void) -> Void)? = nil
    /// Opens a kept shelf (floating: by the edge handle; menu bar: in place).
    var onOpen: ((ShelfTarget) -> Void)? = nil
    private let store = ShelfStore.shared
    @State private var showLibrary = false
    @State private var targeted = false
    @State private var busy = Set<UUID>()
    @State private var note: String?
    @State private var askMetadata: ShelfItem?
    /// The last compress: shown as original (red) → new (green), with Compare.
    @State private var lastResult: (original: URL, result: MediaCompressor.Result)?
    @State private var comparing: ComparePair?
    /// Selected tiles (click; ⌘-click for more), highlighted like Finder.
    @State private var selected = Set<UUID>()
    /// Files as one stack (default) or as a list of everything.
    @AppStorage("shelfListMode") private var listMode = false

    var body: some View {
        let shelf = store.shown
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 20, height: 20).background(Color.white.opacity(0.14), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(store.open == .current ? "Close this shelf. It moves to Recent shelves, and the next drag starts a new one."
                                                 : "Close. It stays where it was kept.")
                }
                if let onMinimize { ShelfMinimizeButton(onMinimize: onMinimize) }
                if store.open != .current {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { store.open = .current } } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless).help("Back to the current shelf")
                }
                Text(title(shelf)).font(.callout.weight(.semibold)).lineLimit(1)
                    .contentTransition(.opacity)
                Spacer()
                iconButton("camera.viewfinder", "Add the latest screenshot") {
                    if let u = ShelfStore.latestScreenshot() { store.add([u]) }
                }
                Button { showLibrary.toggle() } label: { Image(systemName: "square.stack.3d.up") }
                    .buttonStyle(.borderless)
                    .help("Shelves: categories, shelves to the side and recent ones, with what's on them")
                    .popover(isPresented: $showLibrary, arrowEdge: .bottom) {
                        ShelfLibrary(onOpen: { t in showLibrary = false; open(t) },
                                     onRestoreRecent: { s in showLibrary = false; store.restore(s); open(.current) })
                    }
                if store.open == .current {
                    ShelfNewCategoryButton { name in
                        if let onMinimize { onMinimize { store.newCategory(named: name) } } else { store.newCategory(named: name) }
                    }
                    .disabled(shelf.items.isEmpty)
                }
            }
            // In the menu bar panel: shelves minimized to the menu bar, one click away.
            if onClose == nil, store.open == .current, !store.menuBarShelves.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.menuBarShelves) { m in
                            Button { open(.side(m.id)) } label: {
                                HStack(spacing: 6) {
                                    ShelfPreview(items: m.items).frame(width: 52, height: 30).scaleEffect(0.7, anchor: .leading)
                                    Text(m.count).font(.caption)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.white.opacity(0.08), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(m.items.prefix(6).map(\.name).joined(separator: ", "))
                        }
                    }
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(targeted ? Color.accentColor.opacity(0.14) : Color.black.opacity(0.25))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(targeted ? Color.accentColor : Color.white.opacity(0.12),
                                  style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: shelf.items.isEmpty ? [6, 5] : []))
                if shelf.items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 28)).foregroundStyle(.secondary)
                        Text("Drop files here").font(.callout.weight(.medium))
                        Text("Drag them out again wherever you need them").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .transition(.opacity)
                } else if listMode {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(shelf.items) { item in
                                row(item).transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .padding(6)
                    }
                    .background(Color.black.opacity(0.001).onTapGesture { selected = [] })   // click empty space: nothing selected
                    .frame(maxHeight: 300)
                    .transition(.opacity)
                } else {
                    ShelfStackView(items: shelf.items,
                                   onShowList: { withAnimation(.easeInOut(duration: 0.22)) { listMode = true } },
                                   menu: { stackMenu(shelf) })
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: shelf.items.map(\.id))
            .animation(.easeInOut(duration: 0.2), value: shelf.id)
            .animation(.easeInOut(duration: 0.22), value: listMode)
            .frame(minHeight: 130)
            .animation(.easeOut(duration: 0.15), value: targeted)
            .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { providers in accept(providers); return true }
            HStack(spacing: 8) {
                if let r = lastResult, note == nil {
                    SizeChange(before: r.result.before, after: r.result.after)
                    if r.result.url != r.original {
                        Button("Compare") { comparing = ComparePair(original: r.original, copy: r.result.url) }
                            .buttonStyle(.link).font(.caption)
                    }
                } else {
                    Text(note ?? (shelf.items.isEmpty ? "" : listMode ? "Right-click a file for more" : "Drag out all · click to list"))
                        .font(.caption).foregroundStyle(note == nil ? .tertiary : .secondary).lineLimit(2)
                }
                Spacer()
                if !shelf.items.isEmpty {
                    Button { withAnimation(.easeInOut(duration: 0.22)) { listMode.toggle() } } label: {
                        Image(systemName: listMode ? "rectangle.stack" : "list.bullet")
                    }
                    .buttonStyle(.borderless)
                    .help(listMode ? "Show as a stack" : "Show every file as a list")
                    Button("Clear") { store.clearCurrent() }.controlSize(.small)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: lastResult?.result.url)
            .popover(item: $comparing, arrowEdge: .bottom) { pair in
                CompareView(pair: pair,
                            onKeep: pair.choose ? { keepCopy(pair) } : nil,
                            onDiscard: pair.choose ? { discardCopy(pair) } : nil)
            }
        }
        .onAppear {
            // Test switch: APEX_SHELF_SELECT=1 selects the first item (to check the highlight).
            if ProcessInfo.processInfo.environment["APEX_SHELF_SELECT"] == "1", let first = store.shown.items.first { selected = [first.id] }
        }
        .confirmationDialog("Keep the photo or video details?", isPresented: Binding(get: { askMetadata != nil }, set: { if !$0 { askMetadata = nil } }),
                            presenting: askMetadata) { item in
            Button("Keep Details") { compress(item, keepMetadata: true) }
            Button("Remove Details (smaller)") { compress(item, keepMetadata: false) }
        } message: { _ in
            Text("Details are things like when and where it was taken and the camera used. Removing them saves a little more space and keeps your location private.")
        }
    }

    /// One file as a list row: preview, name, size; selection like Finder.
    private func row(_ item: ShelfItem) -> some View {
        let isOn = selected.contains(item.id)
        return HStack(spacing: 8) {
            ZStack {
                ShelfThumbnail(url: item.url).frame(width: 30, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .opacity(item.exists ? 1 : 0.4)
                if busy.contains(item.id) { ProgressView().controlSize(.mini) }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name).font(.caption).lineLimit(1).truncationMode(.middle)
                Text(item.exists ? Fmt.diskBytes(MediaCompressor.fileSize(item.url)) : "Moved or deleted")
                    .font(.caption2).foregroundStyle(isOn ? Color.white.opacity(0.8) : (item.exists ? Color.secondary : Color.orange))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .foregroundStyle(isOn ? Color.white : Color.primary)
        .background(isOn ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .simultaneousGesture(TapGesture().onEnded {
            if NSEvent.modifierFlags.contains(.command) {
                if isOn { selected.remove(item.id) } else { selected.insert(item.id) }
            } else { selected = [item.id] }
        })
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .help(item.name + " · drag out to use it, double-click to open")
        .contextMenu { menu(item) }
    }

    /// Right-click on the stack: things for every file.
    private func stackMenu(_ shelf: ShelfSet) -> NSMenu? {
        let urls = shelf.items.filter(\.exists).map(\.url)
        return NSMenu.build([
            ClosureMenuItem(title: "Show as List") { withAnimation(.easeInOut(duration: 0.22)) { listMode = true } },
            .separator(),
            ClosureMenuItem(title: "Compress All") { compressAll(shelf.items.filter(\.exists)) },
            .separator(),
            ClosureMenuItem(title: "Open All") { urls.forEach { NSWorkspace.shared.open($0) } },
            ClosureMenuItem(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) },
            .separator(),
            ClosureMenuItem(title: "Clear Shelf") { store.clearCurrent() },
        ])
    }

    /// Compresses every file (photos and videos keep their details), adds the
    /// smaller copies, and shows the total before → after.
    private func compressAll(_ items: [ShelfItem]) {
        guard !items.isEmpty else { return }
        items.forEach { busy.insert($0.id) }
        note = "Compressing \(items.count) files…"
        Task {
            var before: UInt64 = 0, after: UInt64 = 0, made = 0
            for item in items {
                let url = item.url, out = MediaCompressor.outputURL(for: url, suffix: "compressed", fallback: fallbackFolder)
                if let r = try? await MediaCompressor.compress(url, keepMetadata: true, output: out) {
                    before += r.before; after += min(r.after, r.before)
                    if r.url != url { store.add([r.url], original: url); made += 1 }
                }
                busy.remove(item.id)
            }
            note = nil
            lastResult = (items[0].url, MediaCompressor.Result(url: items[0].url, before: before, after: after))
            if made == 0 { note = "Already as small as they get." }
        }
    }

    /// Keep the compressed copy: it takes the original's place on the shelf
    /// (the original file itself is left where it is).
    private func keepCopy(_ pair: ComparePair) {
        if let o = store.shown.items.first(where: { $0.path == pair.original.path }) { store.remove(o) }
        comparing = nil
        note = "Kept \(pair.copy.lastPathComponent). The original is still where it was."
    }

    /// Discard the compressed copy: off the shelf and into the Trash.
    private func discardCopy(_ pair: ComparePair) {
        if let c = store.shown.items.first(where: { $0.path == pair.copy.path }) { store.remove(c) }
        try? FileManager.default.trashItem(at: pair.copy, resultingItemURL: nil)
        comparing = nil; lastResult = nil
        note = "Discarded the compressed copy (it’s in the Trash)."
    }

    private func title(_ shelf: ShelfSet) -> String {
        switch store.open {
        case .category: return (shelf.name ?? "Category") + " · \(shelf.items.count)"
        case .side: return "Shelf (side) · \(shelf.items.count)"
        case .current: return shelf.items.isEmpty ? "Shelf" : "Shelf · \(shelf.items.count)"
        }
    }

    private func open(_ t: ShelfTarget) {
        if let onOpen { onOpen(t) } else { withAnimation(.easeInOut(duration: 0.2)) { store.open = t } }
    }

    @ViewBuilder private func menu(_ item: ShelfItem) -> some View {
        let kind = MediaCompressor.kind(item.url)
        Button(MediaCompressor.compressTitle(kind)) {
            if kind == .image || kind == .video { askMetadata = item } else { compress(item, keepMetadata: true) }
        }
        .disabled(!item.exists || busy.contains(item.id))
        if kind == .image || kind == .video {
            Menu("Convert To") {
                if kind == .image {
                    ForEach(MediaCompressor.imageFormats, id: \.0) { f in
                        Button(f.0) { convertImage(item, f.1) }
                            .disabled(item.url.pathExtension.lowercased() == f.1.preferredFilenameExtension)
                    }
                } else {
                    ForEach(MediaCompressor.videoFormats, id: \.0) { f in Button(f.0) { convertVideo(item, f.1, f.2) } }
                }
            }
            .disabled(!item.exists)
        }
        if kind == .image || kind == .video {
            Button("Remove Details") { removeDetails(item) }
                .disabled(!item.exists || busy.contains(item.id))
                .help("A copy without camera, place, date and other details, at exactly the same quality")
        }
        if let o = item.original {
            Button("Compare with Original") { comparing = ComparePair(original: URL(fileURLWithPath: o), copy: item.url) }
        }
        Divider()
        Button("Open") { NSWorkspace.shared.open(item.url) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Divider()
        Button("Remove from Shelf") { store.remove(item) }
    }

    private var fallbackFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    private func compress(_ item: ShelfItem, keepMetadata: Bool) {
        busy.insert(item.id); note = "Compressing \(item.name)…"
        let url = item.url, out = MediaCompressor.outputURL(for: item.url, suffix: "compressed", fallback: fallbackFolder)
        Task {
            do {
                let r = try await MediaCompressor.compress(url, keepMetadata: keepMetadata, output: out)
                if r.url != url { store.add([r.url], original: url) }
                if r.url == url || r.after >= r.before { note = r.summary } else { note = nil }
                lastResult = (url, r)
                // Side by side, to keep the smaller copy or not.
                if r.url != url { comparing = ComparePair(original: url, copy: r.url, choose: true) }
            } catch { note = error.localizedDescription }
            busy.remove(item.id)
        }
    }

    private func removeDetails(_ item: ShelfItem) {
        busy.insert(item.id); note = "Removing details from \(item.name)…"
        let url = item.url, out = MediaCompressor.outputURL(for: item.url, suffix: "no details", fallback: fallbackFolder)
        Task {
            do {
                let copy = try await MediaInfo.removeDetails(url, output: out)
                store.add([copy], original: url)
                let before = await MediaInfo.read(url), after = await MediaInfo.read(copy)
                let gone = MediaInfo.removed(original: before, copy: after)
                note = gone.isEmpty ? "Saved \(copy.lastPathComponent). It had no personal details to remove."
                    : "Saved \(copy.lastPathComponent) without: " + gone.joined(separator: ", ").lowercased() + ". Same quality."
                lastResult = nil
                comparing = ComparePair(original: url, copy: copy)
            } catch { note = error.localizedDescription }
            busy.remove(item.id)
        }
    }

    private func convertImage(_ item: ShelfItem, _ type: UTType) {
        busy.insert(item.id)
        let url = item.url, out = MediaCompressor.outputURL(for: item.url, suffix: "converted", fallback: fallbackFolder)
        Task {
            do {
                let r = try await Task.detached(priority: .userInitiated) { try MediaCompressor.convertImage(url, to: type, output: out) }.value
                store.add([r]); note = "Saved \(r.lastPathComponent)."
            } catch { note = error.localizedDescription }
            busy.remove(item.id)
        }
    }

    private func convertVideo(_ item: ShelfItem, _ preset: String, _ type: AVFileType) {
        busy.insert(item.id); note = "Converting \(item.name)…"
        let url = item.url, out = MediaCompressor.outputURL(for: item.url, suffix: "converted", fallback: fallbackFolder)
        Task {
            do {
                let r = try await MediaCompressor.convertVideo(url, preset: preset, type: type, output: out)
                store.add([r]); note = "Saved \(r.lastPathComponent)."
            } catch { note = error.localizedDescription }
            busy.remove(item.id)
        }
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }.buttonStyle(.borderless).help(help)
    }

    private func accept(_ providers: [NSItemProvider]) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in ShelfStore.shared.add([url]) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { img, _ in
                    guard let img = img as? NSImage else { return }
                    Task { @MainActor in ShelfStore.shared.add(image: img) }
                }
            }
        }
    }
}

/// A Quick Look thumbnail (the file's real preview), falling back to its icon.
struct ShelfThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit().padding(6) }
        }
        .background(Color.white.opacity(0.06))
        .task(id: url) {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 144, height: 120),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
            if let t = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { image = t.nsImage }
        }
    }
}

// MARK: Clipboard

private struct ClipboardTab: View {
    private let history = ClipboardHistory.shared
    @State private var search = ""
    @State private var copied: UUID?

    var body: some View {
        let items = history.items.filter { search.isEmpty || $0.preview.localizedCaseInsensitiveContains(search) || $0.app.localizedCaseInsensitiveContains(search) }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search clipboard", text: $search).textFieldStyle(.roundedBorder)
                Toggle("", isOn: Binding(get: { history.enabled }, set: { history.enabled = $0 }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .help(history.enabled ? "Stop recording what you copy" : "Record what you copy")
            }
            if !history.enabled {
                Text("Clipboard history is off.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else if items.isEmpty {
                Text(search.isEmpty ? "Things you copy will appear here." : "Nothing matches.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(items) { item in clipRow(item) }
                    }
                }
                .frame(maxHeight: 320)
            }
            HStack {
                Text("Kept until Apex quits · passwords are never kept").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Clear") { history.clear() }.controlSize(.small).disabled(history.items.isEmpty)
            }
        }
    }

    private func clipRow(_ item: ClipItem) -> some View {
        Button { history.copy(item); copied = item.id } label: {
            HStack(alignment: .top, spacing: 8) {
                if case .image(let img) = item.kind {
                    Image(nsImage: img).resizable().scaledToFill().frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: item.symbol).frame(width: 18).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.preview).lineLimit(2).font(.callout)
                    Text([item.app, item.date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if copied == item.id { Image(systemName: "checkmark").foregroundStyle(.green) }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to copy again")
        .contextMenu { Button("Remove") { history.remove(item) } }
    }
}

// MARK: Sessions

/// Close the open apps now and reopen them later, the way they were
/// (windows included for apps that support macOS window restoration). The
/// same saved session as Free Up Memory › Quit.
private struct SessionsTab: View {
    @State private var apps: [NSRunningApplication] = []
    @State private var skip = Set<pid_t>()
    @State private var session: QuitSession? = AppSession.last
    @State private var working = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = session {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.stack.fill").font(.title2).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Saved session · \(s.apps.count) app\(s.apps.count == 1 ? "" : "s")").font(.callout.weight(.medium))
                        Text(s.apps.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text("Saved " + s.date.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                HStack {
                    Button { restore() } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                        .keyboardShortcut(.defaultAction).disabled(working)
                    Button("Forget") { AppSession.discard(); session = nil }.disabled(working)
                    if working { ProgressView().controlSize(.small) }
                }
                Divider()
            }
            Text(session == nil ? "Close apps now, reopen them later" : "Close more apps").font(.callout.weight(.medium))
            if apps.isEmpty {
                Text("No other apps are open.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 40)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(apps, id: \.processIdentifier) { app in
                            Toggle(isOn: Binding(get: { !skip.contains(app.processIdentifier) },
                                                 set: { if $0 { skip.remove(app.processIdentifier) } else { skip.insert(app.processIdentifier) } })) {
                                HStack(spacing: 6) {
                                    if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                                    Text(app.localizedName ?? "App").lineLimit(1)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(maxHeight: 200)
                Button { closeAndSave() } label: { Label("Close and Save Session", systemImage: "rectangle.stack.badge.minus") }
                    .disabled(apps.allSatisfy { skip.contains($0.processIdentifier) })
            }
            Text(note ?? "Apps close normally, so they can ask you to save. Restore reopens them, with their windows where the app supports it.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        let me = ProcessInfo.processInfo.processIdentifier
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && $0.bundleIdentifier != "com.apple.finder" }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        session = AppSession.last
    }

    private func closeAndSave() {
        let pids = apps.map(\.processIdentifier).filter { !skip.contains($0) }
        AppSession.quit(pids)
        note = "Closing \(pids.count) app\(pids.count == 1 ? "" : "s")…"
        Task {
            try? await Task.sleep(for: .seconds(2))
            refresh()
            note = nil
        }
    }

    private func restore() {
        working = true
        Task {
            let r = await AppSession.reopen()
            working = false
            session = nil
            note = r.failed.isEmpty ? "Reopened \(r.opened.count) app\(r.opened.count == 1 ? "" : "s")." : "Couldn’t reopen: " + r.failed.joined(separator: ", ")
            try? await Task.sleep(for: .seconds(1))
            refresh()
        }
    }
}

/// The original's size in red, the new one in green.
struct SizeChange: View {
    let before: UInt64
    let after: UInt64
    var body: some View {
        let pct = before > 0 ? Int(((1 - Double(after) / Double(before)) * 100).rounded()) : 0
        HStack(spacing: 4) {
            Text(Fmt.diskBytes(before)).foregroundStyle(.red).strikethrough(after < before, color: .red.opacity(0.6))
            Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            Text(Fmt.diskBytes(after)).foregroundStyle(.green).fontWeight(.semibold)
            if pct > 0 { Text("\(pct)% smaller").foregroundStyle(.secondary) }
        }
        .font(.caption).monospacedDigit()
        .help("Original \(Fmt.diskBytes(before)) → now \(Fmt.diskBytes(after))")
    }
}

struct ComparePair: Identifiable, Hashable {
    var id: String { copy.path }
    let original: URL
    let copy: URL
    /// Just compressed: offer Keep Compressed / Discard.
    var choose = false
}

/// Original next to its compressed or detail-free copy: the pictures, sizes,
/// dimensions, format and every detail, with what was removed.
struct CompareView: View {
    let pair: ComparePair
    var onKeep: (() -> Void)? = nil
    var onDiscard: (() -> Void)? = nil
    @State private var before: [MediaInfo.Field] = []
    @State private var after: [MediaInfo.Field] = []

    var body: some View {
        let labels = before.map(\.label) + after.map(\.label).filter { l in !before.contains { $0.label == l } }
        let removed = MediaInfo.removed(original: before, copy: after)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                side("Original", pair.original, .red)
                side("New", pair.copy, .green)
            }
            if !removed.isEmpty {
                Label("Removed: " + removed.joined(separator: ", "), systemImage: "eye.slash")
                    .font(.callout).foregroundStyle(.orange)
            }
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("").gridColumnAlignment(.trailing)
                        Text("Original").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text("New").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    ForEach(labels, id: \.self) { l in
                        let a = before.first { $0.label == l }?.value, b = after.first { $0.label == l }?.value
                        GridRow {
                            Text(l).foregroundStyle(.secondary)
                            Text(a ?? "—").foregroundStyle(l == "File size" ? Color.red : Color.primary)
                            Group {
                                if let b { Text(b).foregroundStyle(l == "File size" ? Color.green : (b != a ? Color.accentColor : Color.primary)) }
                                else { Text("removed").italic().foregroundStyle(.orange) }
                            }
                        }
                        .font(.callout)
                    }
                }
                .textSelection(.enabled)
            }
            .frame(maxHeight: 260)
            if onKeep != nil || onDiscard != nil {
                HStack {
                    Text("Keep the smaller copy?").font(.callout.weight(.medium))
                    Spacer()
                    if let onDiscard { Button("Discard", role: .destructive, action: onDiscard) }
                    if let onKeep { Button("Keep Compressed", action: onKeep).keyboardShortcut(.defaultAction) }
                }
            }
        }
        .padding(16)
        .frame(width: 480)
        .task {
            async let a = MediaInfo.read(pair.original)
            async let b = MediaInfo.read(pair.copy)
            (before, after) = await (a, b)
        }
    }

    private func side(_ title: String, _ url: URL, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ShelfThumbnail(url: url).frame(width: 214, height: 140).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.6), lineWidth: 1.5))
                .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text(Fmt.diskBytes(MediaCompressor.fileSize(url))).font(.caption).foregroundStyle(tint).monospacedDigit()
            }
            Text(url.lastPathComponent).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .frame(width: 214)
    }
}
