import Foundation

/// Drives all sampling on one background queue with a single coalescing timer.
///
/// Resource rules:
///  * Nothing runs while the window is hidden, minimised or fully covered.
///  * Per-process network (nettop) and GPU client accounting only run while
///    the Processes view is visible.
///  * The setuid `ps` fallback for restricted processes only runs while a view
///    that lists processes is visible.
final class Sampler: @unchecked Sendable {
    struct Needs: Equatable, Sendable {
        var network = false           // per-process network (nettop)
        var gpu = false               // per-process GPU
        var restricted = true         // CPU/memory of root & other users' processes
        var processes = true          // per-process list at all
        var background = false        // window hidden: sample at most every 10 s
    }

    private let queue = DispatchQueue(label: "taskmanager.sampler", qos: .utility, autoreleaseFrequency: .workItem)
    private var timer: DispatchSourceTimer?
    private let processes = ProcessSampler()
    private let system = SystemSampler()
    private let network = NetworkMonitor()
    private var previousGPU: [pid_t: UInt64] = [:]
    private var previousGPUTime: UInt64 = 0

    // Mutated only on `queue`.
    private var interval: Double = 2
    private var needs = Needs()
    private var regularApps: [pid_t: ProcessSampler.RegularApp] = [:]
    private var running = false
    private var lastProcesses: [ProcessInfoSample] = []
    private var effectiveInterval: Double { needs.background ? max(10, interval) : interval }

    private let onSnapshot: @Sendable (Snapshot) -> Void

    init(onSnapshot: @escaping @Sendable (Snapshot) -> Void) {
        self.onSnapshot = onSnapshot
    }

    func setRunning(_ on: Bool) {
        queue.async { [self] in
            guard on != running else { return }
            running = on
            if on { schedule(); tick() } else { timer?.cancel(); timer = nil; network.reset() }
        }
    }

    func setInterval(_ seconds: Double) {
        queue.async { [self] in
            interval = seconds
            if running { schedule() }
        }
    }

    func setNeeds(_ n: Needs) {
        queue.async { [self] in
            guard n != needs else { return }
            let gained = (n.network && !needs.network) || (n.gpu && !needs.gpu) || (n.restricted && !needs.restricted)
                || (n.processes && !needs.processes)
            let reschedule = n.background != needs.background
            if !n.network { network.reset() }
            needs = n
            if running && reschedule { schedule() }
            if running && gained { tick() }   // fill the new columns right away
        }
    }

    func setRegularApps(_ apps: [pid_t: ProcessSampler.RegularApp]) {
        queue.async { [self] in regularApps = apps }
    }

    /// Immediate extra sample (e.g. right after ending a process).
    func refreshNow() {
        queue.async { [self] in if running { tick() } }
    }

    func shutdown() {
        queue.sync { timer?.cancel(); timer = nil; running = false }
    }

    // MARK: - Private (on queue)

    private func schedule() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Generous leeway lets macOS coalesce our wake-ups with others (energy).
        let iv = effectiveInterval
        t.schedule(deadline: .now() + iv, repeating: iv, leeway: .milliseconds(Int(iv * 150)))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() { autoreleasepool { sampleOnce() } }

    private func sampleOnce() {
        let gpuPercent = needs.gpu ? gpuPercentages() : [:]
        let procs: [ProcessInfoSample]
        if needs.processes {
            procs = processes.sample(regularApps: regularApps,
                                     refreshRestricted: needs.restricted,
                                     netRates: needs.network ? network.sample() : [:],
                                     gpuPercent: gpuPercent)
            lastProcesses = procs
        } else {
            procs = lastProcesses
        }
        var sys = system.sample()
        sys.processCount = procs.count
        sys.threadCount = procs.reduce(0) { $0 + Int($1.threads) }
        onSnapshot(Snapshot(date: Date(), processes: procs, system: sys))
    }

    private func gpuPercentages() -> [pid_t: Double] {
        let now = DispatchTime.now().uptimeNanoseconds
        let times = GPU.clientTimes()
        defer { previousGPU = times; previousGPUTime = now }
        guard previousGPUTime > 0 else { return [:] }
        let dt = Double(now - previousGPUTime)
        var out: [pid_t: Double] = [:]
        for (pid, ns) in times {
            if let p = previousGPU[pid], ns > p { out[pid] = min(100, Double(ns - p) / dt * 100) }
        }
        return out
    }
}
