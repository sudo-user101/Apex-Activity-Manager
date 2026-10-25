import SwiftUI

/// Storage hub: pick Optimize, Analyze or Clean first.
struct CleanupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    enum Mode { case home, optimize, analyze, clean }
    @State private var mode: Mode = .home

    var body: some View {
        Group {
            switch mode {
            case .home:
                if let v = model.storageVolume { DriveStorageView(volumePath: v, onAnalyze: { mode = .analyze }, onDone: { dismiss() }) }
                else { home }
            case .optimize: OptimizeView(onBack: { mode = .home }, onDone: { dismiss() })
            case .analyze: AnalyzeView(onBack: { mode = .home }, onDone: { dismiss() }, startAt: model.storageVolume.map {
                DiskEntry(name: ($0 as NSString).lastPathComponent, path: $0, isDirectory: true)
            })
            case .clean: CleanView(onBack: { mode = .home }, onDone: { dismiss() })
            }
        }
        .padding(22)
        .frame(width: 720)
    }

    private var home: some View {
        let d = model.snapshot.system.disk
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Storage").font(.title2).bold()
                Spacer()
                Text("\(Fmt.diskBytes(d.available)) free of \(Fmt.diskBytes(d.capacity))").foregroundStyle(.secondary).monospacedDigit()
            }
            StackedBar(parts: [.init(value: Double(d.capacity > d.available ? d.capacity - d.available : 0), color: .green)], total: Double(max(1, d.capacity)))
            HStack(spacing: 12) {
                tile("Optimize", "gauge.with.dots.needle.67percent", "Check what slows your Mac and refresh caches and services.") { mode = .optimize }
                tile("Analyze", "chart.pie", "See what uses your disk, folder by folder, and remove big things you don’t need.") { mode = .analyze }
                tile("Clean", "sparkles", "Remove caches, logs, leftovers and other junk, sorted into categories.") { mode = .clean }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
    }

    private func tile(_ title: String, _ symbol: String, _ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.tint)
                Text(title).font(.title3.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: Optimize

struct OptimizeView: View {
    var onBack: () -> Void
    var onDone: () -> Void
    @State private var diagnosis: [Diagnosis] = []
    @State private var chosen = Set(OptimizeTask.all.filter(\.defaultOn).map(\.id))
    @State private var outcomes: [OptimizeTask.ID: OptimizeOutcome] = [:]
    @State private var runningTask: Set<OptimizeTask.ID> = []
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { onBack() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless).help("Back").disabled(working)
                Text("Optimize").font(.title2).bold()
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("PERFORMANCE CHECK").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(diagnosis, id: \.self) { d in
                    Label(d.text, systemImage: d.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(d.ok ? Color.primary : Color.orange)
                        .symbolRenderingMode(.multicolor)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(OptimizeTask.all) { t in row(t) }
                }
            }
            .frame(minHeight: 280, maxHeight: 380)

            HStack {
                if !outcomes.isEmpty && !working {
                    let applied = outcomes.values.filter { if case .applied = $0 { return true }; return false }.count
                    let unchanged = outcomes.values.filter { if case .unchanged = $0 { return true }; return false }.count
                    let skipped = outcomes.count - applied - unchanged
                    Text("Applied \(applied) · \(unchanged) unchanged · \(skipped) skipped or failed").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { onDone() }.disabled(working)
                Button(working ? "Optimizing…" : "Optimize (\(chosen.count))") { run() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || working)
            }
        }
        .onAppear { diagnosis = Optimizer.diagnose() }
    }

    private func row(_ t: OptimizeTask) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { chosen.contains(t.id) }, set: { if $0 { chosen.insert(t.id) } else { chosen.remove(t.id) } }))
                .toggleStyle(.checkbox).labelsHidden().disabled(working)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(t.title).fontWeight(.medium)
                    if t.needsAdmin { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).help("Needs your administrator password") }
                }
                Text(t.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let o = outcomes[t.id] {
                    Label(o.text, systemImage: icon(o)).font(.caption).foregroundStyle(color(o))
                }
            }
            Spacer()
            if runningTask.contains(t.id) { ProgressView().controlSize(.small) }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func icon(_ o: OptimizeOutcome) -> String {
        switch o { case .applied: return "checkmark.circle.fill"; case .unchanged: return "equal.circle"; case .skipped: return "minus.circle"; case .failed: return "xmark.circle.fill" }
    }
    private func color(_ o: OptimizeOutcome) -> Color {
        switch o { case .applied: return .green; case .unchanged: return .secondary; case .skipped: return .orange; case .failed: return .red }
    }

    private func run() {
        working = true; outcomes = [:]
        let ids = chosen
        Task {
            await Task.detached(priority: .userInitiated) {
                Optimizer.run(ids) { id, outcome in
                    Task { @MainActor in
                        if let outcome { outcomes[id] = outcome; runningTask.remove(id) } else { runningTask.insert(id) }
                    }
                }
            }.value
            working = false
            runningTask = []
            diagnosis = Optimizer.diagnose()
        }
    }
}

// MARK: Analyze

struct AnalyzeView: View {
    var onBack: () -> Void
    var onDone: () -> Void
    var startAt: DiskEntry? = nil                            // open inside this folder (a plugged-in drive)
    @State private var stack: [DiskEntry] = []              // breadcrumbs (empty = overview)
    @State private var entries: [DiskEntry] = []
    @State private var sizes: [String: (UInt64, Bool)] = [:] // cache across navigation
    @State private var generation = 0
    @State private var toTrash: DiskEntry?
    @State private var removeApp: DiskEntry?
    @State private var message: String?

    private var protectedRoots: Set<String> {
        [NSHomeDirectory(), NSHomeDirectory() + "/Library", "/Applications", "/Library", "/System", DiskAnalyzer.oldDownloadsKey]
    }

    var body: some View {
        let measured = entries.map { e -> DiskEntry in
            var e = e; if let s = sizes[e.path] { e.size = s.0; e.partial = s.1 }; return e
        }
        .sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        let total = max(1, measured.reduce(0) { $0 + ($1.size ?? 0) })
        let shown = Array(measured.prefix(60))
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { if stack.isEmpty { onBack() } else { stack.removeLast(); load() } } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).help(stack.isEmpty ? "Back" : "Up one level")
                Text("Analyze").font(.title2).bold()
                Spacer()
            }
            // Breadcrumbs
            HStack(spacing: 4) {
                Button("Overview") { stack = []; load() }.buttonStyle(.link)
                ForEach(Array(stack.enumerated()), id: \.offset) { i, e in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(e.name) { stack = Array(stack.prefix(i + 1)); load() }.buttonStyle(.link).lineLimit(1)
                }
                Spacer()
                let pending = entries.filter { sizes[$0.path] == nil }.count
                if pending > 0 { ProgressView().controlSize(.small); Text("Measuring \(pending)…").font(.caption).foregroundStyle(.secondary) }
                else { Text("\(Fmt.diskBytes(total)) in \(entries.count) items").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            if let message { Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(shown) { e in row(e, total: total) }
                    if measured.count > shown.count {
                        Text("+ \(measured.count - shown.count) smaller items").font(.caption).foregroundStyle(.secondary).padding(6)
                    }
                    if entries.isEmpty { Text("Empty, or macOS doesn’t let Apex look inside.").foregroundStyle(.secondary).padding() }
                }
            }
            .frame(minHeight: 380, maxHeight: 460)
            HStack {
                Text("Sizes are space used on disk. Moving to Trash can be undone until you empty it.").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { onDone() }
            }
        }
        .onAppear { if let s = startAt, stack.isEmpty { stack = [s] }; load() }
        .sheet(item: $removeApp) { e in
            AppRemovalSheet(path: e.path) { msg in
                message = msg
                sizes[e.path] = nil
                for s in stack { sizes[s.path] = nil }
                load()
            }
        }
        .confirmationDialog("Move “\(toTrash?.name ?? "")” to the Trash?", isPresented: Binding(get: { toTrash != nil }, set: { if !$0 { toTrash = nil } })) {
            Button("Move to Trash", role: .destructive) { trash() }
        } message: {
            Text(toTrash.flatMap { sizes[$0.path] }.map { "This frees about \(Fmt.diskBytes($0.0)) once the Trash is emptied." } ?? "")
        }
    }

    private func row(_ e: DiskEntry, total: UInt64) -> some View {
        let fraction = Double(e.size ?? 0) / Double(total)
        return HStack(spacing: 10) {
            Image(systemName: e.isDirectory ? "folder.fill" : "doc.fill").foregroundStyle(e.isDirectory ? Color.accentColor : .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(e.name).lineLimit(1).truncationMode(.middle)
                    if !e.note.isEmpty { Text(e.note).font(.caption2).foregroundStyle(.secondary) }
                }
                GeometryReader { g in
                    Capsule().fill(Color.primary.opacity(0.08))
                        .overlay(alignment: .leading) { Capsule().fill(Color.accentColor.opacity(0.75)).frame(width: max(2, g.size.width * fraction)) }
                }
                .frame(height: 5)
            }
            Text(e.size == nil ? "…" : Fmt.diskBytes(e.size!) + (e.partial ? "+" : ""))
                .monospacedDigit().frame(width: 90, alignment: .trailing).foregroundStyle(e.size == nil ? .secondary : .primary)
                .help(e.partial ? "Some contents couldn’t be read, so the real size is larger" : "")
            Text(String(format: "%.1f%%", fraction * 100)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
            Button { ProcessActions.reveal(path: e.path) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Show in Finder").disabled(e.path == DiskAnalyzer.oldDownloadsKey)
            Button { if e.path.hasSuffix(".app") { removeApp = e } else { toTrash = e } } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help(e.path.hasSuffix(".app") ? "Remove this app (app only, or with its files)" : "Move to Trash")
                .disabled(protectedRoots.contains(e.path) || e.path.hasPrefix("/System") || stack.isEmpty)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { if e.isDirectory { stack.append(e); load() } }
    }

    private func load() {
        generation += 1
        let gen = generation
        message = nil
        let path = stack.last?.path
        let list = path.map(DiskAnalyzer.children(of:)) ?? DiskAnalyzer.roots()
        entries = list
        let todo = list.filter { sizes[$0.path] == nil }.map(\.path)
        Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: (String, UInt64, Bool).self) { group in
                var it = todo.makeIterator()
                func next() -> String? { it.next() }
                for _ in 0..<4 { if let p = next() { group.addTask { let (s, part) = DiskAnalyzer.measure(p); return (p, s, part) } } }
                while let (p, s, part) = await group.next() {
                    let still = await MainActor.run { () -> Bool in
                        sizes[p] = (s, part)
                        return gen == generation
                    }
                    if !still { group.cancelAll(); break }
                    if let n = next() { group.addTask { let (s, part) = DiskAnalyzer.measure(n); return (n, s, part) } }
                }
            }
        }
    }

    private func trash() {
        guard let e = toTrash else { return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: e.path), resultingItemURL: nil)
            message = "Moved “\(e.name)” to the Trash."
            sizes[e.path] = nil
            for s in stack { sizes[s.path] = nil }       // parents shrink
            load()
        } catch {
            message = "Couldn’t move “\(e.name)”: \(error.localizedDescription)"
        }
        toTrash = nil
    }
}

// MARK: A plugged-in drive

/// Storage for one plugged-in drive: Analyze starts inside it, and the two
/// things that are always safe to remove (its Trash, macOS helper files) are
/// listed for review. Nothing else is suggested for deletion.
struct DriveStorageView: View {
    @Environment(AppModel.self) private var model
    let volumePath: String
    var onAnalyze: () -> Void
    var onDone: () -> Void
    @State private var scan: DriveCleaner.Scan?
    @State private var showHelpers = false
    @State private var confirm: Kind?
    @State private var message: String?
    @State private var working = false
    enum Kind { case trash, helpers }

    private var volume: VolumeInfo? {
        model.snapshot.system.storageDevices.lazy.flatMap(\.volumes).first { $0.path == volumePath }
    }

    var body: some View {
        let v = volume
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Storage · \(v?.name ?? (volumePath as NSString).lastPathComponent)").font(.title2).bold()
                Spacer()
                if let v { Text("\(Fmt.diskBytes(v.available)) free of \(Fmt.diskBytes(v.capacity))").foregroundStyle(.secondary).monospacedDigit() }
            }
            if let v {
                StackedBar(parts: [.init(value: Double(v.capacity > v.available ? v.capacity - v.available : 0), color: .green)], total: Double(max(1, v.capacity)))
                if !v.format.isEmpty { Text(v.format).font(.caption).foregroundStyle(.secondary) }
            } else {
                Label("This drive is no longer connected.", systemImage: "externaldrive.badge.xmark").foregroundStyle(.orange)
            }
            if let message { Label(message, systemImage: "checkmark.circle").foregroundStyle(.secondary) }

            Button(action: onAnalyze) {
                HStack(spacing: 12) {
                    Image(systemName: "chart.pie").font(.system(size: 26)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Analyze this drive").font(.headline)
                        Text("See what takes the space, folder by folder, largest first. You choose what to move to the Trash.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .padding(14).contentShape(Rectangle())
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(v == nil)

            if let s = scan {
                if !s.writable {
                    Label("macOS can only read this drive (for example NTFS), so Apex can’t remove anything from it. Analyze still shows what uses the space.",
                          systemImage: "lock").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                candidate(title: "Drive’s Trash",
                          text: s.trash.isEmpty ? "Empty." : "\(s.trash.count) item\(s.trash.count == 1 ? "" : "s") you already deleted from this drive. They still take space until this Trash is emptied.",
                          size: s.trashSize, button: "Empty Drive Trash…", enabled: s.writable && !s.trash.isEmpty) { confirm = .trash }
                if s.helpersApply {
                    candidate(title: "macOS helper files (._)",
                              text: s.helpers.isEmpty ? "None found." : "\(s.helpers.count) small files macOS adds next to your files on drives formatted for Windows. Removing them loses Finder tags and labels on those files; the files themselves aren’t touched.",
                              size: s.helperSize, button: "Remove Helper Files…", enabled: s.writable && !s.helpers.isEmpty) { confirm = .helpers }
                    if !s.helpers.isEmpty {
                        DisclosureGroup("Review the list", isExpanded: $showHelpers) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(s.helpers.prefix(300), id: \.self) { i in
                                        Text(String(i.path.dropFirst(volumePath.count))).font(.caption).monospaced().lineLimit(1).truncationMode(.middle)
                                    }
                                    if s.helpers.count > 300 { Text("+ \(s.helpers.count - 300) more").font(.caption).foregroundStyle(.secondary) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 140)
                        }
                        .font(.callout)
                    }
                }
                Text("Caches, logs and app leftovers live on the startup drive, so Clean isn’t offered here. Apex never deletes anything without asking.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            } else if v != nil {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for space to reclaim…").foregroundStyle(.secondary) }
            }
            HStack { Spacer(); Button("Done") { onDone() }.keyboardShortcut(.cancelAction) }
        }
        .task(id: volumePath) { await rescan() }
        .confirmationDialog(confirm == .trash ? "Empty this drive’s Trash?" : "Remove macOS helper files?",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button(confirm == .trash ? "Empty Trash" : "Remove", role: .destructive) { remove(confirm!) }
        } message: {
            if let s = scan {
                Text(confirm == .trash ? "\(s.trash.count) items, \(Fmt.diskBytes(s.trashSize)), are deleted for good. This can’t be undone."
                                       : "\(s.helpers.count) helper files, \(Fmt.diskBytes(s.helperSize)). Your own files stay; only Finder tags and labels stored in these are lost.")
            }
        }
    }

    private func candidate(title: String, text: String, size: UInt64, button: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text(title).font(.headline); if size > 0 { Text(Fmt.diskBytes(size)).foregroundStyle(.secondary).monospacedDigit() } }
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(button, action: action).disabled(!enabled || working)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func rescan() async {
        guard let v = volume else { return }
        let path = v.path, format = v.format
        scan = await Task.detached(priority: .userInitiated) { DriveCleaner.scan(volume: path, format: format) }.value
    }

    private func remove(_ k: Kind) {
        guard let s = scan else { return }
        let items = k == .trash ? s.trash : s.helpers
        working = true
        Task {
            let r = await Task.detached(priority: .userInitiated) { DriveCleaner.remove(items) }.value
            message = "Freed \(Fmt.diskBytes(r.freed))." + (r.failed.isEmpty ? "" : " Couldn’t remove \(r.failed.count) item(s).")
            working = false
            await rescan()
        }
    }
}
