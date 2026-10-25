import AppKit
import Observation
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case processes, performance, ai, history, startup, users, services
    var id: String { rawValue }

    var title: String {
        switch self {
        case .processes: return "Processes"
        case .performance: return "Performance"
        case .ai: return "Local AI"
        case .history: return "App History"
        case .startup: return "Startup Items"
        case .users: return "Users"
        case .services: return "Services"
        }
    }

    var shortTitle: String { self == .startup ? "Startup" : (self == .history ? "History" : title) }

    var symbol: String {
        switch self {
        case .processes: return "square.stack.3d.up"
        case .performance: return "waveform.path.ecg"
        case .ai: return "cpu"
        case .history: return "clock.arrow.circlepath"
        case .startup: return "power"
        case .users: return "person.2"
        case .services: return "gearshape.2"
        }
    }

    /// Views that list processes need the root/other-user `ps` fallback.
    var needsRestricted: Bool { [.processes, .users, .performance, .ai].contains(self) }
}

struct AdminPrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let action: () -> ProcessActions.Outcome
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: Data
    private(set) var snapshot = Snapshot()
    private(set) var history = History()
    /// Just what the menu bar label shows, so only the label redraws while
    /// the window is hidden.
    private(set) var menuStats = MenuStats()
    @ObservationIgnored private var latest = Snapshot()
    @ObservationIgnored private var historyBuffer = History()

    struct MenuStats: Equatable { var cpu = 0; var memory = 0 }
    private(set) var hasData = false

    // MARK: UI state
    var section: AppSection = AppSection(rawValue: UserDefaults.standard.string(forKey: "section") ?? "") ?? .processes {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: "section"); updateNeeds() }
    }
    var search = ""
    var processFilter: ProcessFilter = ProcessFilter(rawValue: UserDefaults.standard.string(forKey: "processFilter") ?? "") ?? .all {
        didSet { UserDefaults.standard.set(processFilter.rawValue, forKey: "processFilter") }
    }
    var processSelection = Set<String>()
    var collapsed = Set<String>()          // collapsed section rows
    var expanded = Set<String>()           // expanded app / name groups
    var showRunTask = false
    var showFreeMemory = false
    var showWelcome = false
    /// Performance graphs show the last N minutes (1–10; 10 minutes is recorded).
    var graphMinutes: Double = {
        let v = UserDefaults.standard.double(forKey: "graphMinutes")
        return v > 0 ? min(10, v) : 2
    }() {
        didSet { UserDefaults.standard.set(graphMinutes, forKey: "graphMinutes") }
    }
    /// Range menu → "Advanced graph": axes, low/avg/peak, exact values on hover.
    var advancedGraph: Bool = UserDefaults.standard.bool(forKey: "advancedGraph") {
        didSet { UserDefaults.standard.set(advancedGraph, forKey: "advancedGraph") }
    }
    var graphTimeline: GraphTimeline {
        GraphTimeline(times: history.times, window: graphMinutes * 60, end: history.times.last ?? Date())
    }
    var showInspector: Bool = UserDefaults.standard.object(forKey: "showInspector") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInspector, forKey: "showInspector") }
    }
    var showWhoIsUsing = false
    var showCleanup = false { didSet { if !showCleanup { storageVolume = nil } } }
    /// Storage hub target: nil = the startup drive, else a plugged-in volume's path.
    var storageVolume: String?
    func openStorage(volume: String?) { storageVolume = volume; showCleanup = true }
    var menuPanelOpen = false { didSet { if menuPanelOpen { publish() }; updateNeeds() } }
    @ObservationIgnored var openMainWindow: (() -> Void)?

    // Background features (work while the window is closed).
    var menuBarStyle: String = UserDefaults.standard.string(forKey: "menuBarStyle") ?? "cpu" {
        didSet { UserDefaults.standard.set(menuBarStyle, forKey: "menuBarStyle") }
    }
    var showMenuBar: Bool = UserDefaults.standard.object(forKey: "showMenuBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showMenuBar, forKey: "showMenuBar"); updateRunning(); StatusBar.shared.update() }
    }
    var historyEnabled: Bool = UserDefaults.standard.object(forKey: "historyEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(historyEnabled, forKey: "historyEnabled"); updateRunning() }
    }
    /// History tab: "apps" (usage) or "events" (alerts and spikes).
    var historyMode: String = UserDefaults.standard.string(forKey: "historyMode") ?? "apps" {
        didSet { UserDefaults.standard.set(historyMode, forKey: "historyMode") }
    }
    var selectedEvent: UUID?
    var alertsEnabled: Bool = Alerts.shared.enabled {
        didSet {
            UserDefaults.standard.set(alertsEnabled, forKey: "alertsEnabled")
            Alerts.shared.enabled = alertsEnabled
            if alertsEnabled { Alerts.shared.requestAuthorization() }
            updateRunning()
        }
    }
    var keepsRunningInBackground: Bool { showMenuBar || historyEnabled || alertsEnabled || Recorder.shared.recording }
    var adminPrompt: AdminPrompt?
    /// Processes currently in "Optimize" (Darwin background) mode.
    var optimized = Set<pid_t>()
    /// Apps the user optimized, by bundle path. Remembered while they run
    /// (closing Free Up Memory or relaunching Apex doesn't forget them), their
    /// new helper processes are optimized too, and they're dropped when the
    /// app quits. Restore All clears it.
    var optimizedApps: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "optimizedApps") ?? []) {
        didSet { UserDefaults.standard.set(Array(optimizedApps), forKey: "optimizedApps") }
    }
    @ObservationIgnored private var optimizeTried = Set<pid_t>()
    var errorMessage: String?


    // MARK: Settings
    var interval: Double = {
        let v = UserDefaults.standard.double(forKey: "interval")
        return v > 0 ? v : 2
    }() {
        didSet { UserDefaults.standard.set(interval, forKey: "interval"); sampler.setInterval(interval) }
    }
    /// false = macOS convention (100 % = one core);
    /// true = Windows convention (100 % = every core busy).
    var cpuShareOfAllCores: Bool = UserDefaults.standard.bool(forKey: "cpuShareOfAllCores") {
        didSet { UserDefaults.standard.set(cpuShareOfAllCores, forKey: "cpuShareOfAllCores") }
    }

    @ObservationIgnored private lazy var sampler = Sampler { [weak self] snap in
        DispatchQueue.main.async { self?.apply(snap) }
    }
    @ObservationIgnored private var windowVisible = false
    /// A real Apex window is on screen (not closed, minimized or covered).
    var isWindowVisible: Bool { windowVisible }
    @ObservationIgnored private var publishedOnce = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        sampler.setInterval(interval)
        publishRunningApps()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishRunningApps() }
            })
        }
        for name in [NSApplication.didChangeOcclusionStateNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Run after AppKit finishes updating window state.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateVisibility() } }
            })
        }
        updateRunning()
        updateNeeds()
        updateVisibility()
        // APEX_OPEN=freememory|storage opens that sheet at launch (screenshots, layout checks).
        switch ProcessInfo.processInfo.environment["APEX_OPEN"] {
        case "freememory": showFreeMemory = true
        case "storage": showCleanup = true
        default: break
        }
        // Test switch: APEX_RECORD=1 (everything) or =cpu,memory,… starts recordings at launch (saved on quit).
        if let v = ProcessInfo.processInfo.environment["APEX_RECORD"] {
            let scopes = v == "1" ? [RecordScope.all] : v.split(separator: ",").compactMap { RecordScope(rawValue: String($0)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { scopes.forEach { Recorder.shared.start($0) } }
        }
    }

    func stop() { sampler.shutdown(); HistoryStore.shared.save(); DriveHealthStore.shared.save() }

    func refreshNow() { sampler.refreshNow() }

    private func apply(_ s: Snapshot) {
        latest = s
        // Local AI's share of the GPU, for the GPU page (only while per-process GPU is sampled).
        let aiGPU = gpuSampled ? LocalAI.detect(s.processes) { _ in nil }.reduce(0) { $0 + $1.gpu } : 0
        historyBuffer.push(s.system, aiGPU: min(100, aiGPU))
        let ms = MenuStats(cpu: Int(s.system.cpu.total.rounded()), memory: Int(s.system.memory.percent.rounded()))
        if ms != menuStats { menuStats = ms }
        if historyEnabled { HistoryStore.shared.record(s) }
        Alerts.shared.evaluate(s)
        HardwareStore.shared.recordCharge()
        DriveHealthStore.shared.update(s)
        keepOptimized(s)
        Recorder.shared.record(s)
        // File copies into each drive (event-driven; re-subscribed only when volumes change).
        let roots = Set(s.system.storageDevices.flatMap { $0.volumes.map(\.path) }).union([NSHomeDirectory()])
        if roots != transferRoots { transferRoots = roots; TransferMonitor.shared.watch(roots) }
        // Only push data into the observed UI state when someone can see it,
        // so hidden views don't redraw.
        // Also once at launch, so a window that opens behind others isn't empty.
        if windowVisible || menuPanelOpen || !publishedOnce { publish(); publishedOnce = true }
        MemoryGuard.trimIfNeeded(now: s.date)
    }

    private func publish() {
        let s = latest
        snapshot = s
        history = historyBuffer
        // Truth comes from the kernel's background flag, so the leaf badge is
        // right even for processes optimized before a relaunch.
        let bg = Set(s.processes.lazy.filter(\.background).map(\.pid))
        if bg != optimized { optimized = bg }
        hasData = true
    }

    private func updateVisibility() {
        // A real window on screen (the menu bar panel and status item don't count).
        let visible = !NSApp.isHidden && NSApp.windows.contains {
            $0.isVisible && !$0.isMiniaturized && $0.canBecomeMain && $0.occlusionState.contains(.visible)
        }
        guard visible != windowVisible else { return }
        windowVisible = visible
        if visible { publish() } else { MemoryGuard.purge() }
        updateNeeds()
        updateRunning()
    }

    private func updateRunning() {
        sampler.setRunning(windowVisible || keepsRunningInBackground)
    }

    /// What to sample. With the window hidden only the menu bar, alerts and
    /// history need data, so sampling drops to every 10 s with no GPU / root
    /// fallback; network is only collected when history records it.
    @ObservationIgnored private var gpuSampled = false
    @ObservationIgnored private var transferRoots = Set<String>()

    /// Record started or stopped: it needs everything, even with the window closed.
    func recordingChanged() {
        // At the chosen rate, but no faster than every 2 s (keeps the file small).
        sampler.setInterval(Recorder.shared.recording ? max(2, interval) : interval)
        updateNeeds()
        updateRunning()
    }

    private func updateNeeds() {
        if Recorder.shared.recording {
            // Every process with its network and GPU use, window open or not.
            gpuSampled = true
            sampler.setNeeds(.init(network: true, gpu: true, restricted: true, processes: true, background: false))
            return
        }
        if windowVisible {
            // Performance includes the GPU page (top GPU processes, Local AI share).
            gpuSampled = [.processes, .ai, .performance].contains(section)
            sampler.setNeeds(.init(network: section == .processes || historyEnabled,
                                   gpu: gpuSampled,
                                   restricted: section.needsRestricted,
                                   processes: true, background: false))
        } else {
            gpuSampled = false
            sampler.setNeeds(.init(network: historyEnabled, gpu: false, restricted: false,
                                   processes: historyEnabled || alertsEnabled || menuPanelOpen,
                                   background: !menuPanelOpen))
        }
    }

    private func publishRunningApps() {
        var map: [pid_t: ProcessSampler.RegularApp] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            map[app.processIdentifier] = .init(name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "App",
                                               bundlePath: app.bundleURL?.path ?? "")
        }
        sampler.setRegularApps(map)
    }

    // MARK: Derived

    var cpuScale: Double {
        cpuShareOfAllCores ? 1 / Double(max(1, snapshot.system.cpu.logicalCores)) : 1
    }

    func process(_ pid: pid_t) -> ProcessInfoSample? {
        snapshot.processes.first { $0.pid == pid }
    }

    /// PIDs targeted by the current selection in the active view.
    /// Like `selectedPIDs`, but an app row expands to the app plus every helper
    /// process in its bundle (a browser's tabs run in helper processes).
    var selectedPIDsWithHelpers: [pid_t] {
        section == .processes ? withHelpers(selectedPIDs) : selectedPIDs
    }

    func withHelpers(_ pids: [pid_t]) -> [pid_t] {
        var out = pids
        for pid in pids {
            if let app = process(pid), app.isRegularApp, !app.bundlePath.isEmpty {
                out += snapshot.processes.filter { $0.bundlePath == app.bundlePath && $0.pid != pid }.map(\.pid)
            }
        }
        return Array(Set(out))
    }

    var selectedPIDs: [pid_t] {
        switch section {
        case .processes: return ProcessTree.pids(for: processSelection, in: snapshot.processes)
        default: return []
        }
    }

    // MARK: Actions

    func endSelected(force: Bool) { end(pids: selectedPIDs, force: force) }

    func end(pids: [pid_t], force: Bool) {
        guard !pids.isEmpty else { return }
        let names = pids.compactMap { process($0)?.name }
        let label = names.count == 1 ? "“\(names[0])”" : "\(pids.count) processes"
        handle(ProcessActions.end(pids: pids, force: force),
               admin: AdminPrompt(title: "End \(label) as administrator?",
                                  message: "This process belongs to another user or the system. macOS will ask for your password.",
                                  action: { ProcessActions.endAsAdmin(pids: pids, force: force) }))
    }

    /// Processes that must never be paused (pausing them freezes the Mac).
    private static let neverPause: Set<String> = ["WindowServer", "loginwindow", "Dock", "Finder", "SystemUIServer",
                                                  "launchd", "kernel_task", "Apex Activity Manager", "TaskManager"]

    func setPaused(pids: [pid_t], _ on: Bool) {
        let me = ProcessInfo.processInfo.processIdentifier
        let safe = pids.filter { pid in
            guard pid != me, pid > 1, let p = process(pid) else { return false }
            return !(on && (Self.neverPause.contains(p.name) || p.kind == .system))
        }
        guard !safe.isEmpty else {
            errorMessage = "System processes can’t be paused — doing so would freeze your Mac."
            return
        }
        handle(ProcessActions.pause(pids: safe, on),
               admin: AdminPrompt(title: on ? "Pause as administrator?" : "Resume as administrator?",
                                  message: "This process belongs to another user. macOS will ask for your password.",
                                  action: { ProcessActions.pauseAsAdmin(pids: safe, on) }))
    }

    func endTree(pids: [pid_t], force: Bool) {
        end(pids: ProcessActions.withDescendants(pids, in: snapshot.processes), force: force)
    }

    func setPriority(_ nice: Int32, pids explicit: [pid_t]? = nil) {
        let pids = explicit ?? selectedPIDs
        guard !pids.isEmpty else { return }
        handle(ProcessActions.setNice(pids: pids, nice),
               admin: AdminPrompt(title: "Change priority as administrator?",
                                  message: "Raising priority, or changing another user's process, needs administrator rights.",
                                  action: { ProcessActions.setNiceAsAdmin(pids: pids, nice) }))
    }

    /// Optimize: keep running, but at the lowest cost to the rest of the Mac.
    func setOptimized(pids: [pid_t], _ on: Bool) {
        guard !pids.isEmpty else { return }
        let bundles = Set(pids.compactMap { process($0)?.bundlePath }.filter { !$0.isEmpty })
        if on {
            optimizedApps.formUnion(pids.compactMap { process($0) }.filter(\.isRegularApp).map(\.bundlePath).filter { !$0.isEmpty })
        } else {
            optimizedApps.subtract(bundles)
        }
        let outcome = ProcessActions.optimize(pids: pids, on)
        if case .ok = outcome {
            // Optimistic update; the next sample confirms it from the kernel.
            if on { optimized.formUnion(pids) } else { optimized.subtract(pids) }
        }
        handle(outcome, admin: AdminPrompt(
            title: on ? "Optimize as administrator?" : "Stop optimizing as administrator?",
            message: "This process belongs to another user or the system. macOS will ask for your password.",
            action: { [weak self] in
                let r = ProcessActions.optimizeAsAdmin(pids: pids, on)
                if case .ok = r {
                    DispatchQueue.main.async {
                        if on { self?.optimized.formUnion(pids) } else { self?.optimized.subtract(pids) }
                    }
                }
                return r
            }))
    }

    /// Every optimized process (remembered apps with their helpers, and any
    /// process in background mode), back to normal in one go.
    func restoreAllOptimized() {
        let pids = snapshot.processes.filter { $0.background || optimizedApps.contains($0.bundlePath) }.map(\.pid)
        optimizedApps = []
        if !pids.isEmpty { setOptimized(pids: pids, false) }
    }

    /// Keeps remembered apps optimized: helper processes they start later
    /// join (each tried once; the app itself is never hidden again here, so
    /// bringing it to the front sticks), and apps that quit are forgotten.
    private func keepOptimized(_ s: Snapshot) {
        guard !optimizedApps.isEmpty, !s.processes.isEmpty else { return }
        let running = Set(s.processes.lazy.filter(\.isRegularApp).map(\.bundlePath))
        let gone = optimizedApps.subtracting(running)
        if !gone.isEmpty { optimizedApps.subtract(gone) }
        let missing = s.processes.filter {
            !$0.isRegularApp && !$0.background && optimizedApps.contains($0.bundlePath) && !optimizeTried.contains($0.pid)
        }.map(\.pid)
        guard !missing.isEmpty else { return }
        optimizeTried.formUnion(missing)
        _ = ProcessActions.optimize(pids: missing, true)
    }

    func toggleOptimizeSelected() {
        let pids = selectedPIDsWithHelpers
        setOptimized(pids: pids, !pids.allSatisfy(optimized.contains))
    }

    func runAdmin(_ prompt: AdminPrompt) {
        Task.detached(priority: .userInitiated) {
            let outcome = prompt.action()
            await MainActor.run {
                if case .failed(let msg) = outcome { self.errorMessage = msg.isEmpty ? "The operation failed." : msg }
                self.refreshNow()
            }
        }
    }

    private func handle(_ outcome: ProcessActions.Outcome, admin: AdminPrompt) {
        switch outcome {
        case .ok: refreshNow()
        case .needsAdmin: adminPrompt = admin
        case .failed(let msg): errorMessage = msg
        }
    }

    /// Opens the Processes tab with `pid` expanded, selected and scrolled to.
    func reveal(pid: pid_t) {
        let procs = snapshot.processes
        guard let p = procs.first(where: { $0.pid == pid }) else { return }
        search = ""
        collapsed.remove("s:\(p.kind.rawValue)")
        var id = "p:\(pid)"
        if p.isRegularApp {
            id = "a:\(pid)"
        } else if let app = procs.first(where: { $0.isRegularApp && !$0.bundlePath.isEmpty && $0.bundlePath == p.bundlePath }) {
            collapsed.remove("s:\(ProcessKind.app.rawValue)")
            expanded.insert("a:\(app.pid)")
        } else if procs.filter({ $0.kind == p.kind && $0.name == p.name && !$0.isRegularApp }).count > 1 {
            expanded.insert("n:\(p.kind.rawValue):\(p.name)")
        }
        processSelection = [id]
        revealRequest = id
        section = .processes
    }
    /// Row the Processes table should scroll to on its next update.
    var revealRequest: String?

    func showInfo() {
        if section != .processes, let pid = selectedPIDs.first { reveal(pid: pid) }
        showInspector.toggle()
    }
}
