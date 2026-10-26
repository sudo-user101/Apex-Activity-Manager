import AppKit
import Foundation

/// Runs one command for the Shell window and streams what it prints.
@MainActor @Observable
final class ShellRunner {
    private(set) var output = ""
    private(set) var running = false
    private(set) var exitCode: Int32?
    private(set) var started: Date?
    private(set) var finished: Date?
    @ObservationIgnored private var process: Process?

    /// Plain commands run in your login shell (same PATH as Terminal) with
    /// output as it comes; admin ones through the macOS password prompt.
    func run(_ command: String, admin: Bool) {
        guard !running else { return }
        output = "$ " + command + "\n"
        running = true; exitCode = nil; started = Date(); finished = nil
        if admin {
            Task.detached(priority: .userInitiated) {
                let r = Shell.runAsAdmin(command, prompt: "Apex wants to run: \(command)")
                await MainActor.run {
                    self.output += r.stdout + (r.stderr.isEmpty ? "" : "\n" + r.stderr)
                    self.finish(Shell.isUserCancelled(r) ? -128 : r.status)
                }
            }
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self.append(text) }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            let code = proc.terminationStatus
            Task { @MainActor in
                if !rest.isEmpty { self.append(String(decoding: rest, as: UTF8.self)) }
                self.finish(code)
            }
        }
        do { try p.run(); process = p } catch { output += error.localizedDescription + "\n"; finish(-1) }
    }

    func stop() { process?.terminate() }

    func clear() { if !running { output = ""; exitCode = nil; started = nil } }

    private func append(_ s: String) {
        output += s
        // Keep the last ~200 KB so a chatty command can't slow the window.
        if output.utf8.count > 200_000 { output = String(output.suffix(150_000)) }
    }

    private func finish(_ code: Int32) {
        running = false; exitCode = code; finished = Date(); process = nil
    }

    /// For interactive programs: opens Terminal and types the command there.
    static func openInTerminal(_ command: String) {
        let esc = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(esc)\"\nend tell"
        Task.detached { _ = Shell.run("/usr/bin/osascript", ["-e", script]) }
    }
}
