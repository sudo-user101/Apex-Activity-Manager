import AppKit
import Darwin

/// Keeps Apex's own memory small (target: under 80 MB).
/// Caches are dropped when the window is hidden or macOS reports memory
/// pressure, and freed pages are handed back to the system.
@MainActor
enum MemoryGuard {
    private static var source: DispatchSourceMemoryPressure?

    static func start() {
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        s.setEventHandler { MainActor.assumeIsolated { purge() } }
        s.resume()
        source = s
    }

    /// Everything here is rebuilt on demand.
    static func purge() {
        IconCache.shared.purge()
        CodeSignature.purge()
        StartupCache.items = nil
        ServicesCache.items = nil
        InstalledModelsCache.items = nil
        MemorySpecCache.value = nil
        malloc_zone_pressure_relief(nil, 0)
    }

    private static var lastTrim = Date.distantPast

    /// Called on every sample. Freed heap pages stay counted against Apex
    /// (macOS compresses them instead of taking them back), so every 30 s,
    /// once the footprint passes 60 MB, hand them back even while the window
    /// is visible. Takes about a millisecond; nothing is dropped.
    static func trimIfNeeded(now: Date = Date()) {
        guard now.timeIntervalSince(lastTrim) >= 30 else { return }
        lastTrim = now
        if footprint > 60 << 20 { malloc_zone_pressure_relief(nil, 0) }
    }

    /// Apex's own footprint (the figure macOS reports as an app's memory).
    static var footprint: UInt64 {
        var ru = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &ru) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) == 0 }
        }
        return ok ? ru.ri_phys_footprint : 0
    }
}
