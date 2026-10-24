import Foundation

/// launchd services for the current user's GUI domain.
struct ServiceItem: Identifiable, Hashable, Sendable {
    var id: String { label }
    let label: String
    let pid: pid_t?
    let lastExit: Int32?
    var isRunning: Bool { pid != nil }
    var statusText: String { isRunning ? "Running" : "Stopped" }
    var pidSort: Int { Int(pid ?? -1) }
}

enum Launchd {
    static let uid = getuid()
    static var guiDomain: String { "gui/\(uid)" }

    /// `launchctl list` — only run when the Services view asks (and then on a
    /// slow timer), never as part of the main sampling loop.
    static func services() -> [ServiceItem] {
        guard let out = Shell.capture("/bin/launchctl", ["list"]) else { return [] }
        return parseList(out)
    }

    /// `launchctl list` output: "PID\tStatus\tLabel" with a header row.
    static func parseList(_ out: String) -> [ServiceItem] {
        var items: [ServiceItem] = []
        for line in out.split(separator: "\n").dropFirst() {
            let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard f.count == 3 else { continue }
            items.append(ServiceItem(label: String(f[2]), pid: pid_t(f[0]), lastExit: Int32(f[1])))
        }
        return items.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    enum Action { case start, stop, restart }

    /// Actually starts / stops the running job (not just the persistent enabled flag).
    static func perform(_ action: Action, label: String) -> String? {
        let target = "\(guiDomain)/\(label)"
        let args: [String]
        switch action {
        case .start: args = ["kickstart", target]
        case .restart: args = ["kickstart", "-k", target]
        case .stop: args = ["kill", "SIGTERM", target]
        }
        let r = Shell.run("/bin/launchctl", args)
        return r.status == 0 ? nil : nonEmpty(r.stderr) ?? "launchctl exited with status \(r.status)"
    }

    /// Persistently enables/disables a job (takes effect at next login / load).
    /// System daemons need an administrator prompt.
    static func setEnabled(_ enabled: Bool, label: String, systemDomain: Bool) -> String? {
        let target = (systemDomain ? "system" : guiDomain) + "/" + label
        let verb = enabled ? "enable" : "disable"
        if !systemDomain {
            let r = Shell.run("/bin/launchctl", [verb, target])
            if r.status == 0 { return nil }
        }
        let r = Shell.runAsAdmin("/bin/launchctl \(verb) \(Shell.quote(target))")
        if r.status == 0 { return nil }
        if Shell.isUserCancelled(r) { return "Cancelled" }
        return nonEmpty(r.stderr) ?? "Requires administrator privileges"
    }

    /// launchd's enable/disable overrides (label -> enabled) for the user and
    /// system domains, from `launchctl print-disabled`.
    static func enabledOverrides() -> [String: Bool] {
        var map: [String: Bool] = [:]
        for domain in [guiDomain, "system"] {
            guard let out = Shell.capture("/bin/launchctl", ["print-disabled", domain], allowFailure: true) else { continue }
            for line in out.split(separator: "\n") {
                guard let a = line.firstIndex(of: "\""),
                      let b = line[line.index(after: a)...].firstIndex(of: "\""),
                      let arrow = line.range(of: "=>") else { continue }
                let value = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                let disabled = value.hasPrefix("disabled") || value.hasPrefix("true")
                map[String(line[line.index(after: a)..<b])] = !disabled
            }
        }
        return map
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
