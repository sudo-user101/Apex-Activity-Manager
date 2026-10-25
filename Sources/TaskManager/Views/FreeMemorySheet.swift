import AppKit
import SwiftUI

/// "Free Up Memory": optimize everything for this session, quit chosen apps,
/// or clear the cache — with the memory each option frees.
struct FreeMemorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<pid_t>()
    @State private var initialised = false
    @State private var usedBefore: UInt64?
    @State private var result: String?
    @State private var working = false
    @State private var session: QuitSession? = AppSession.last

    struct AppUsage: Identifiable {
        let id: pid_t
        let name: String
        let bundlePath: String
        let memory: UInt64
        let pids: [pid_t]
    }

    /// Regular apps with their helper processes' memory included.
    private var apps: [AppUsage] {
        let procs = model.snapshot.processes
        let me = ProcessInfo.processInfo.processIdentifier
        return procs.filter { $0.isRegularApp && $0.pid != me }.map { app in
            let members = procs.filter { $0.pid == app.pid || (!app.bundlePath.isEmpty && $0.bundlePath == app.bundlePath) }
            return AppUsage(id: app.pid, name: app.name, bundlePath: app.bundlePath,
                            memory: members.reduce(0) { $0 + $1.memory }, pids: members.map(\.pid))
        }
        .sorted { $0.memory > $1.memory }
    }


    /// Remembered as optimized (see `AppModel.optimizedApps`), or the app itself is in background mode.
    private func isOptimized(_ a: AppUsage) -> Bool {
        model.optimizedApps.contains(a.bundlePath) || model.optimized.contains(a.id)
    }

    var body: some View {
        let mem = model.snapshot.system.memory
        let list = apps
        let chosen = list.filter { selected.contains($0.id) }
        let allPIDs = list.flatMap(\.pids)
        let optimizedCount = list.filter(isOptimized).count
        let allOptimized = !list.isEmpty && optimizedCount == list.count
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Free Up Memory").font(.title2).bold()
                Spacer()
                Text("\(Fmt.bytes(mem.used)) of \(Fmt.bytes(mem.total)) used · swap \(Fmt.bytes(mem.swapUsed))")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            StackedBar(parts: [.init(value: Double(mem.used), color: mem.pressure >= 70 ? .orange : .windowsBlue)],
                       total: Double(max(1, mem.total)))
            if let result {
                Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }

            // Choose apps, then optimize or quit just those.
            HStack(alignment: .firstTextBaseline) {
                Text("Your apps").font(.headline)
                Text("tick the ones to act on").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if optimizedCount > 0 {
                    Label("\(optimizedCount) optimized", systemImage: "leaf.fill").font(.caption).foregroundStyle(.green)
                }
                Button(selected.count == list.count ? "Deselect All" : "Select All") {
                    selected = selected.count == list.count ? [] : Set(list.map(\.id))
                }
                .buttonStyle(.link).font(.caption)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                        Toggle(isOn: Binding(get: { selected.contains(a.id) },
                                             set: { if $0 { selected.insert(a.id) } else { selected.remove(a.id) } })) {
                            HStack(spacing: 8) {
                                Image(nsImage: IconCache.shared.icon(forBundle: a.bundlePath)).resizable().frame(width: 18, height: 18)
                                Text(a.name)
                                if isOptimized(a) {
                                    Label("Optimized", systemImage: "leaf.fill").labelStyle(.iconOnly)
                                        .font(.caption).foregroundStyle(.green).help("Optimized")
                                }
                                Spacer()
                                Text(Fmt.bytes(a.memory)).monospacedDigit().foregroundStyle(.secondary)
                                Text(mem.total > 0 ? "\(Int(Double(a.memory) / Double(mem.total) * 100))%" : "")
                                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(i % 2 == 1 ? Color.primary.opacity(0.035) : .clear)
                    }
                }
            }
            .frame(height: 240)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))

            let chosenPIDs = chosen.flatMap(\.pids)
            let chosenOptimized = !chosen.isEmpty && chosen.allSatisfy(isOptimized)
            let chosenMemory = Fmt.bytes(chosen.reduce(0) { $0 + $1.memory })

            option(icon: "leaf.fill", tint: .green, title: "Optimize",
                   text: "Keeps the apps running, but hides them, runs them at the lowest priority on efficiency cores, and lets macOS compress their memory first. Restore brings them back on screen with their windows where they were.") {
                VStack(alignment: .trailing, spacing: 6) {
                    if chosenOptimized {
                        Button("Restore \(chosen.count) App\(chosen.count == 1 ? "" : "s")") {
                            model.setOptimized(pids: chosenPIDs, false)
                            result = "\(chosen.count) app\(chosen.count == 1 ? "" : "s") restored to normal."
                        }
                    } else {
                        Button("Optimize \(chosen.count) Selected") {
                            model.setOptimized(pids: chosenPIDs, true)
                            result = "\(chosen.count) app\(chosen.count == 1 ? "" : "s") optimized. macOS will reclaim their memory as it needs it."
                        }
                        .buttonStyle(.borderedProminent).tint(.green)
                        .disabled(chosen.isEmpty)
                    }
                    HStack(spacing: 10) {
                        if !allOptimized {
                            Button("Optimize All") {
                                model.setOptimized(pids: allPIDs, true)
                                result = "\(list.count) apps optimized."
                            }
                            .buttonStyle(.link).font(.caption)
                        }
                        // Always here: no need to find and tick the optimized apps again.
                        Button(optimizedCount > 0 ? "Restore All (\(optimizedCount))" : "Restore All") {
                            model.restoreAllOptimized()
                            result = "All apps restored to normal."
                        }
                        .font(.caption)
                        .disabled(optimizedCount == 0 && model.optimized.isEmpty)
                        .help("Every optimized app back to normal, on screen with its windows where they were.")
                    }
                }
            }

            option(icon: "xmark.octagon.fill", tint: .red, title: "Quit",
                   text: "Frees all of their memory now. Apps quit normally, so they can ask you to save first. Apex remembers them, so Reopen brings them back with their windows.") {
                Button("Quit \(chosen.count) Selected · \(chosenMemory)") { quit(chosen) }
                    .disabled(chosen.isEmpty || working)
            }
            if let session, !session.apps.isEmpty { reopenRow(session) }

            // 3. File cache
            option(icon: "internaldrive.fill", tint: .blue, title: "Clear cache",
                   text: "Drops \(Fmt.bytes(mem.cached)) of recently used files that macOS keeps in memory for speed. Safe, but things may open a little slower at first. Needs your password.") {
                Button("Clear Cache…") { purge() }.disabled(working)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 620)
        .onAppear {
            guard !initialised else { return }
            initialised = true
            selected = []
        }
    }

    private func option<B: View>(icon: String, tint: Color, title: String, text: String,
                                 @ViewBuilder button: () -> B) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            button()
        }
    }

    private func quit(_ list: [AppUsage]) {
        let before = model.snapshot.system.memory.used
        working = true
        AppSession.quit(list.map(\.id))
        session = AppSession.last
        selected.subtract(list.map(\.id))
        Task {
            try? await Task.sleep(for: .seconds(4))
            model.refreshNow()
            try? await Task.sleep(for: .seconds(1))
            let after = model.snapshot.system.memory.used
            result = before > after ? "Freed \(Fmt.bytes(before - after))." : "Apps are closing. Some may be asking to save."
            working = false
        }
    }

    /// Apps quit earlier (here or in an earlier session), ready to come back.
    private func reopenRow(_ s: QuitSession) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.uturn.backward.circle.fill").font(.title2).foregroundStyle(.blue).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("Reopen what you quit").font(.headline)
                HStack(spacing: 4) {
                    ForEach(s.apps.prefix(8), id: \.bundleID) { a in
                        Image(nsImage: IconCache.shared.icon(forBundle: a.path)).resizable().frame(width: 16, height: 16).help(a.name)
                    }
                    Text(s.apps.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("Quit \(s.date.formatted(.relative(presentation: .named))). Apps come back the way they were: hidden ones hidden, the front one in front, and their windows where the app supports macOS window restoration (browsers use their own “continue where you left off” setting).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button("Reopen \(s.apps.count) App\(s.apps.count == 1 ? "" : "s")") { reopen() }
                    .buttonStyle(.borderedProminent).disabled(working)
                Button("Forget") { AppSession.discard(); session = nil }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func reopen() {
        working = true
        Task {
            let r = await AppSession.reopen()
            session = nil
            result = "Reopened \(r.opened.count) app\(r.opened.count == 1 ? "" : "s")." + (r.failed.isEmpty ? "" : " Couldn’t open: \(r.failed.joined(separator: ", ")).")
            working = false
        }
    }

    private func purge() {
        let before = model.snapshot.system.memory.cached
        working = true
        Task {
            let r = await Task.detached { Shell.runAsAdmin("/usr/sbin/purge") }.value
            model.refreshNow()
            try? await Task.sleep(for: .seconds(2))
            let after = model.snapshot.system.memory.cached
            if r.status == 0 {
                result = "Cache cleared" + (before > after ? " (\(Fmt.bytes(before - after)) freed)." : ".")
            } else if !Shell.isUserCancelled(r) {
                model.errorMessage = r.stderr.isEmpty ? "purge failed" : r.stderr
            }
            working = false
        }
    }
}
