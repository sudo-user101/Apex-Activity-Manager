import XCTest
@testable import TaskManager

/// APEX_ACCURACY=1: Apex's live readings next to macOS's own tools on this
/// Mac (sysctl, vm_stat, df, ps, top), and a busy process whose CPU use is
/// known. Reports every pair; fails when one is outside its tolerance.
final class AccuracyTests: XCTestCase {
    private func sh(_ cmd: String) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try? p.run(); let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func report(_ what: String, apex: Double, macOS: Double, unit: String) {
        print(String(format: "ACCURACY %-28@ Apex %12.2f   macOS %12.2f  %@", what as NSString, apex, macOS, unit as NSString))
    }

    func testReadingsMatchMacOS() throws {
        guard ProcessInfo.processInfo.environment["APEX_ACCURACY"] == "1" else { throw XCTSkip("set APEX_ACCURACY=1") }
        let sys = SystemSampler()
        _ = sys.sample()
        Thread.sleep(forTimeInterval: 1)
        let s = sys.sample()
        let page = Double(vm_kernel_page_size)
        let vm = sh("vm_stat")
        func pages(_ label: String) -> Double {
            let line = vm.split(separator: "\n").first { $0.contains(label) } ?? ""
            return Double(line.split(separator: ":").last?.trimmingCharacters(in: CharacterSet(charactersIn: " .")) ?? "") ?? -1
        }

        // Memory
        let memsize = Double(sh("sysctl -n hw.memsize")) ?? 0
        report("Memory installed", apex: Double(s.memory.total) / 1e9, macOS: memsize / 1e9, unit: "GB")
        XCTAssertEqual(Double(s.memory.total), memsize)
        let wired = pages("Pages wired down") * page, compressed = pages("Pages occupied by compressor") * page
        report("Memory wired", apex: Double(s.memory.wired) / 1e9, macOS: wired / 1e9, unit: "GB")
        report("Memory compressed", apex: Double(s.memory.compressed) / 1e9, macOS: compressed / 1e9, unit: "GB")
        XCTAssertEqual(Double(s.memory.wired), wired, accuracy: max(wired * 0.05, 64e6))
        XCTAssertEqual(Double(s.memory.compressed), compressed, accuracy: max(compressed * 0.05, 64e6))
        let swap = sh("sysctl -n vm.swapusage")      // "total = 2048.00M  used = 1023.25M  free = …"
        let usedMB = Double(swap.components(separatedBy: "used = ").last?.split(separator: "M").first ?? "") ?? 0
        report("Swap used", apex: Double(s.memory.swapUsed) / 1e6, macOS: usedMB * 1_048_576 / 1e6, unit: "MB")
        XCTAssertEqual(Double(s.memory.swapUsed), usedMB * 1_048_576, accuracy: max(usedMB * 1_048_576 * 0.05, 32e6))

        // CPU and load
        let cores = Double(sh("sysctl -n hw.logicalcpu")) ?? 0
        report("CPU cores", apex: Double(s.cpu.logicalCores), macOS: cores, unit: "")
        XCTAssertEqual(Double(s.cpu.logicalCores), cores)
        let load = Double(sh("sysctl -n vm.loadavg").split(separator: " ").dropFirst().first ?? "") ?? -1
        report("Load average (1 min)", apex: s.cpu.loadAverage[0], macOS: load, unit: "")
        XCTAssertEqual(s.cpu.loadAverage[0], load, accuracy: 0.5)

        // Disk: the startup drive
        let df = sh("df -k / | tail -1").split(separator: " ", omittingEmptySubsequences: true)
        let dfSize = (Double(df.count > 1 ? df[1] : "") ?? 0) * 1024
        report("Startup drive size", apex: Double(s.disk.capacity) / 1e9, macOS: dfSize / 1e9, unit: "GB")
        XCTAssertEqual(Double(s.disk.capacity), dfSize, accuracy: dfSize * 0.01)

        // Processes: count, and one whose CPU use is known (a busy loop on one core)
        let busy = Process(); busy.executableURL = URL(fileURLWithPath: "/usr/bin/yes"); busy.standardOutput = FileHandle.nullDevice
        try busy.run()
        defer { busy.terminate() }
        let ps = ProcessSampler()
        _ = ps.sample(regularApps: [:], refreshRestricted: true, netRates: [:], gpuPercent: [:])
        Thread.sleep(forTimeInterval: 2)
        let list = ps.sample(regularApps: [:], refreshRestricted: true, netRates: [:], gpuPercent: [:])
        let psCount = Double(sh("ps -A -o pid= | wc -l")) ?? 0
        report("Processes running", apex: Double(list.count), macOS: psCount, unit: "")
        XCTAssertEqual(Double(list.count), psCount, accuracy: max(psCount * 0.03, 5))
        let mine = list.first { $0.pid == busy.processIdentifier }
        let psCPU = Double(sh("ps -o %cpu= -p \(busy.processIdentifier)")) ?? -1
        report("CPU of a busy loop", apex: mine?.cpu ?? -1, macOS: psCPU, unit: "% of one core")
        XCTAssertEqual(mine?.cpu ?? -1, 100, accuracy: 15, "a busy loop uses one whole core")

        // Whole-Mac CPU over the same seconds as top
        _ = sys.sample()
        let top = sh("top -l 2 -s 2 -n 0 | grep 'CPU usage' | tail -1")   // "CPU usage: 9.1% user, 6.2% sys, 84.6% idle"
        let s2 = sys.sample()
        let idle = Double(top.components(separatedBy: "sys, ").last?.split(separator: "%").first ?? "") ?? -1
        report("CPU in use (whole Mac)", apex: s2.cpu.total, macOS: 100 - idle, unit: "%")
        XCTAssertEqual(s2.cpu.total, 100 - idle, accuracy: 15)
    }
}
