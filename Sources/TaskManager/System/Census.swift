import Foundation

/// Census (Processes › More): what's using the most of each resource, with
/// helpers counted towards their app. Right now from the live sample, or
/// today from History. Pure: tested.
enum Census {
    enum Resource: String, CaseIterable, Identifiable {
        case cpu, memory, disk, network, gpu, energy
        var id: String { rawValue }
        var title: String {
            switch self {
            case .cpu: return "CPU"
            case .memory: return "Memory"
            case .disk: return "Disk"
            case .network: return "Network"
            case .gpu: return "GPU"
            case .energy: return "Energy"
            }
        }
        var symbol: String {
            switch self {
            case .cpu: return "cpu"
            case .memory: return "memorychip"
            case .disk: return "internaldrive"
            case .network: return "network"
            case .gpu: return "cube.transparent"
            case .energy: return "bolt.fill"
            }
        }
    }

    struct Entry: Identifiable, Equatable {
        var id: String { key }
        let key: String          // the app (outer .app bundle) or the process name
        let name: String
        let bundlePath: String
        let value: Double
        let share: Double        // of everything, 0–1
        var pids: [pid_t] = []
    }

    static let top = 6

    /// Right now: each process's value, added up per app.
    static func now(_ processes: [ProcessInfoSample]) -> [Resource: [Entry]] {
        var names: [String: String] = [:], paths: [String: String] = [:], pids: [String: [pid_t]] = [:]
        for p in processes {
            let k = p.appKey
            if p.isRegularApp || names[k] == nil { names[k] = p.isRegularApp ? (p.appName ?? p.name) : (p.bundlePath.isEmpty ? p.name : appName(p.bundlePath)) }
            paths[k] = p.bundlePath
            pids[k, default: []].append(p.pid)
        }
        var out: [Resource: [Entry]] = [:]
        for r in Resource.allCases {
            var sum: [String: Double] = [:]
            for p in processes { sum[p.appKey, default: 0] += value(r, p) }
            out[r] = rank(sum.filter { $0.value >= least(r) }) { k, v, share in Entry(key: k, name: names[k] ?? k, bundlePath: paths[k] ?? "", value: v, share: share, pids: pids[k] ?? []) }
        }
        return out
    }

    /// Today: History's totals per app (CPU time, peak memory, disk and network
    /// bytes, energy). History doesn't record the GPU.
    static func today(_ totals: [(key: String, usage: AppUsageDay)]) -> [Resource: [Entry]] {
        var out: [Resource: [Entry]] = [:]
        let byKey = Dictionary(totals.map { ($0.key, $0.usage) }, uniquingKeysWith: { a, _ in a })
        for r in Resource.allCases where r != .gpu {
            var sum: [String: Double] = [:]
            for (k, u) in byKey {
                switch r {
                case .cpu: sum[k] = u.cpuSeconds
                case .memory: sum[k] = Double(u.peakMemory)
                case .disk: sum[k] = u.diskBytes
                case .network: sum[k] = u.netBytes
                case .energy: sum[k] = u.energyJoules ?? 0
                case .gpu: break
                }
            }
            out[r] = rank(sum) { k, v, share in
                Entry(key: k, name: byKey[k]?.name ?? k, bundlePath: byKey[k]?.bundlePath ?? "", value: v, share: share)
            }
        }
        return out
    }

    static func value(_ r: Resource, _ p: ProcessInfoSample) -> Double {
        switch r {
        case .cpu: return p.cpu
        case .memory: return Double(p.memory)
        case .disk: return p.diskReadPerSec + p.diskWritePerSec
        case .network: return p.netPerSec
        case .gpu: return p.gpu
        case .energy: return p.power
        }
    }

    /// Less than this is noise, not worth a line (0.0 W, 0 KB/s).
    static func least(_ r: Resource) -> Double {
        switch r {
        case .cpu, .gpu: return 0.5          // %
        case .memory: return 1               // any
        case .disk, .network: return 1_000   // 1 KB/s
        case .energy: return 0.05            // W
        }
    }

    private static func rank(_ sum: [String: Double], _ make: (String, Double, Double) -> Entry) -> [Entry] {
        let total = sum.values.reduce(0, +)
        guard total > 0 else { return [] }
        return sum.filter { $0.value > 0 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(top)
            .map { make($0.key, $0.value, $0.value / total) }
    }

    /// Apps in the top 3 of two or more resources, and how many.
    static func heavy(_ lists: [Resource: [Entry]]) -> [String: Int] {
        var n: [String: Int] = [:]
        for (_, l) in lists { for e in l.prefix(3) { n[e.key, default: 0] += 1 } }
        return n.filter { $0.value >= 2 }
    }

    private static func appName(_ bundlePath: String) -> String {
        ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
