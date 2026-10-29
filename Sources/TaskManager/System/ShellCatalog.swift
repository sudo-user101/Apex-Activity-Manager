import Foundation

/// Ready-made commands for the Shell window, in categories. A command can
/// have blanks (`{Host}`) the person fills in; what they type is quoted so it
/// can only ever be that value, never extra commands.
struct ShellCommand: Identifiable, Hashable, Codable, Sendable {
    var id: String { category + "/" + title }
    let category: String
    let title: String
    let detail: String
    /// The command, with `{Name}` blanks.
    let template: String
    var needsAdmin = false
    /// Changes something (asks first).
    var changes = false

    /// The blanks, in order of first appearance. Pure: tested.
    var fields: [String] {
        var out: [String] = []
        var rest = template[...]
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let name = String(rest[rest.index(after: open)..<close])
            if !name.isEmpty, !out.contains(name) { out.append(name) }
            rest = rest[rest.index(after: close)...]
        }
        return out
    }

    /// The command with the blanks filled in, each value safely quoted. Pure: tested.
    func command(_ values: [String: String]) -> String {
        var c = template
        for f in fields { c = c.replacingOccurrences(of: "{\(f)}", with: Shell.quote(values[f] ?? "")) }
        return c
    }
}

enum ShellCatalog {
    static let categories = ["Network", "System", "Updates", "Disk", "Security"]

    static let commands: [ShellCommand] = [
        // Network
        .init(category: "Network", title: "IP addresses", detail: "This Mac's addresses on every connection.", template: "ifconfig | grep -E '^[a-z]|inet '"),
        .init(category: "Network", title: "Connection summary", detail: "Address, router and DNS for a connection (e.g. en0 for Wi-Fi).", template: "ipconfig getsummary {Interface}"),
        .init(category: "Network", title: "Network services", detail: "The names macOS uses for each connection (needed by the commands below).", template: "networksetup -listallnetworkservices"),
        .init(category: "Network", title: "Ping", detail: "Is a server reachable, and how fast does it answer?", template: "ping -c 5 {Host}"),
        .init(category: "Network", title: "Trace route", detail: "Every hop on the way to a server.", template: "traceroute -m 20 -w 2 {Host}"),
        .init(category: "Network", title: "DNS lookup", detail: "What address a name points to.", template: "dig +short {Host}"),
        .init(category: "Network", title: "Set a manual IP address", detail: "Fixed address, subnet mask and router for a network service.",
              template: "networksetup -setmanual {Service} {IP address} {Subnet mask} {Router}", needsAdmin: true, changes: true),
        .init(category: "Network", title: "Back to automatic (DHCP)", detail: "Let the router give this Mac its address again.",
              template: "networksetup -setdhcp {Service}", needsAdmin: true, changes: true),
        .init(category: "Network", title: "Set DNS servers", detail: "Use these DNS servers for a network service (e.g. 1.1.1.1).",
              template: "networksetup -setdnsservers {Service} {DNS server}", needsAdmin: true, changes: true),
        .init(category: "Network", title: "Flush DNS cache", detail: "Forget remembered names, after a website moved or DNS changed.",
              template: "dscacheutil -flushcache; killall -HUP mDNSResponder", needsAdmin: true, changes: true),
        .init(category: "Network", title: "Open ports", detail: "Which apps are listening for connections.", template: "lsof -nP -iTCP -sTCP:LISTEN"),
        .init(category: "Network", title: "Routing table", detail: "Where traffic goes for each destination.", template: "netstat -rn"),
        .init(category: "Network", title: "Devices nearby (ARP)", detail: "Devices this Mac has talked to on the local network.", template: "arp -a"),
        .init(category: "Network", title: "Internet speed test", detail: "Apple's own speed test (takes about 20 seconds).", template: "networkQuality -s"),
        // System
        .init(category: "System", title: "macOS version", detail: "", template: "sw_vers"),
        .init(category: "System", title: "Hardware overview", detail: "Model, chip, memory, serial.", template: "system_profiler SPHardwareDataType"),
        .init(category: "System", title: "Up time and load", detail: "", template: "uptime"),
        .init(category: "System", title: "Busiest processes", detail: "The top 15 by CPU.", template: "ps -Arco pid,pcpu,pmem,comm | head -16"),
        .init(category: "System", title: "Memory statistics", detail: "", template: "vm_stat; sysctl vm.swapusage"),
        .init(category: "System", title: "Battery", detail: "", template: "pmset -g batt"),
        .init(category: "System", title: "What keeps the Mac awake", detail: "Apps preventing sleep right now.", template: "pmset -g assertions"),
        .init(category: "System", title: "Restart Finder", detail: "When Finder is stuck.", template: "killall Finder", changes: true),
        .init(category: "System", title: "Restart the Dock", detail: "When the Dock or Launchpad misbehaves.", template: "killall Dock", changes: true),
        // Updates
        .init(category: "Updates", title: "Check for macOS updates", detail: "Lists what's available (takes a moment).", template: "softwareupdate -l"),
        .init(category: "Updates", title: "Install all macOS updates", detail: "Downloads and installs them; some need a restart.",
              template: "softwareupdate -ia", needsAdmin: true, changes: true),
        .init(category: "Updates", title: "Update history", detail: "", template: "softwareupdate --history"),
        .init(category: "Updates", title: "Homebrew: what's outdated", detail: "If Homebrew is installed.", template: "brew outdated"),
        .init(category: "Updates", title: "Homebrew: update everything", detail: "", template: "brew update && brew upgrade", changes: true),
        // Disk
        .init(category: "Disk", title: "List disks", detail: "", template: "diskutil list"),
        .init(category: "Disk", title: "Free space", detail: "", template: "df -h"),
        .init(category: "Disk", title: "Verify the startup disk", detail: "Read-only First Aid check.", template: "diskutil verifyVolume /"),
        .init(category: "Disk", title: "APFS containers", detail: "", template: "diskutil apfs list"),
        .init(category: "Disk", title: "Local Time Machine snapshots", detail: "They can take space; macOS removes them when it needs it.", template: "tmutil listlocalsnapshots /"),
        .init(category: "Disk", title: "Spotlight status", detail: "", template: "mdutil -s /"),
        .init(category: "Disk", title: "Rebuild Spotlight index", detail: "When search misses files. Re-indexing takes a while.",
              template: "mdutil -E /", needsAdmin: true, changes: true),
        // Security
        .init(category: "Security", title: "Gatekeeper", detail: "Whether only trusted apps can open.", template: "spctl --status"),
        .init(category: "Security", title: "System Integrity Protection", detail: "", template: "csrutil status"),
        .init(category: "Security", title: "FileVault", detail: "Whether the disk is encrypted.", template: "fdesetup status"),
        .init(category: "Security", title: "Firewall", detail: "", template: "/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate"),
    ]

    /// `sudo …` typed in the command line runs through the macOS password
    /// prompt instead (Apex can't take a password in its own window). Pure: tested.
    static func adminForm(_ line: String) -> (command: String, admin: Bool) {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("sudo ") else { return (t, false) }
        var rest = t.dropFirst(5).trimmingCharacters(in: .whitespaces)
        // sudo's own options (-E, -H…) don't apply to the macOS prompt.
        while rest.hasPrefix("-"), let space = rest.firstIndex(of: " ") { rest = rest[rest.index(after: space)...].trimmingCharacters(in: .whitespaces) }
        return (rest, true)
    }

    /// Programs that need a full terminal (they wait for typing or redraw the screen). Pure: tested.
    static func isInteractive(_ command: String) -> Bool {
        let first = command.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let name = (first as NSString).lastPathComponent
        let interactive: Set<String> = ["top", "htop", "btop", "ssh", "telnet", "vim", "vi", "nano", "emacs", "less", "more", "man",
                                         "sudo", "su", "python", "python3", "node", "irb", "sqlite3", "mysql", "psql", "ftp", "sftp", "screen", "tmux", "watch"]
        if name == "sudo" { return command.split(separator: " ").count == 1 }   // a sudo command runs via the password prompt
        if interactive.contains(name) {
            // python3 script.py / node app.js aren't interactive.
            if ["python", "python3", "node", "irb"].contains(name) { return command.split(separator: " ").count == 1 }
            return true
        }
        return false
    }
}

/// Shell › Custom: commands people add themselves (with `{Name}` blanks like
/// the ready-made ones), kept in UserDefaults as JSON.
enum ShellCustom {
    static let category = "Custom"
    static let key = "shellCustomCommands"

    static func load(_ d: UserDefaults = .standard) -> [ShellCommand] {
        guard let data = d.data(forKey: key), let list = try? JSONDecoder().decode([ShellCommand].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [ShellCommand], _ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(list) { d.set(data, forKey: key) }
    }

    /// A tidy command from what was typed in the editor. Asking for the
    /// password always means asking before running. Pure: tested.
    static func make(title: String, detail: String, template: String, admin: Bool, changes: Bool) -> ShellCommand {
        let t = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let (command, sudo) = ShellCatalog.adminForm(t)
        let needsAdmin = admin || sudo
        return ShellCommand(category: category, title: title.trimmingCharacters(in: .whitespaces),
                            detail: detail.trimmingCharacters(in: .whitespaces), template: command,
                            needsAdmin: needsAdmin, changes: changes || needsAdmin)
    }

    /// What's wrong with a command before it's saved, in plain words; nil = fine.
    /// `replacing`: the title of the command being edited. Pure: tested.
    static func problem(_ c: ShellCommand, existing: [ShellCommand], replacing: String? = nil) -> String? {
        if c.title.isEmpty { return "Give it a name." }
        if c.template.isEmpty { return "Type the command." }
        if existing.contains(where: { $0.title.caseInsensitiveCompare(c.title) == .orderedSame && $0.title != replacing }) {
            return "You already have a command called “\(c.title)”."
        }
        let opens = c.template.filter { $0 == "{" }.count, closes = c.template.filter { $0 == "}" }.count
        if opens != closes { return "A blank is missing its { or }. Blanks look like {Host}." }
        return nil
    }

    /// Adds, or replaces the one called `replacing`, keeping the order. Pure: tested.
    static func upsert(_ c: ShellCommand, into list: [ShellCommand], replacing: String?) -> [ShellCommand] {
        var out = list
        if let replacing, let i = out.firstIndex(where: { $0.title == replacing }) { out[i] = c } else { out.append(c) }
        return out
    }
}
