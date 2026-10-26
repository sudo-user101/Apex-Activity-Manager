import AppKit
import Foundation
import ProcessIdentityCore

/// Apex Agent: built-in answers to the questions Mac users ask most, worked
/// out on this Mac with no internet and no AI. It matches the question to a
/// topic by its words, answers with this Mac's readings where they help, and
/// offers the Apex button that fixes it. When it can't tell what's asked, it
/// says so and suggests Lumen AI.
enum ApexAgent {
    /// Something an answer can open.
    enum Action: Hashable, Sendable {
        case freeMemory, clean, page(String), section(String)
        /// Things the agent does when asked (after you confirm with the button).
        /// The targets are the exact processes the answer was about (PID +
        /// start time), so a button pressed later never hits a reused PID.
        case quitApps(targets: [ProcessIdentity], names: [String], force: Bool)
        case stopProcesses(targets: [ProcessIdentity], names: [String])
        /// Does something (quit, stop) rather than open a page.
        var acts: Bool {
            switch self { case .quitApps, .stopProcesses: true; default: false }
        }
        var title: String {
            switch self {
            case .quitApps(let targets, let names, let force):
                return (force ? "Force Quit " : "Quit ") + (targets.count == 1 ? names[0] : "\(targets.count) Apps")
            case .stopProcesses(let targets, let names):
                return "Stop " + (targets.count == 1 ? names[0] : "\(targets.count) Processes")
            case .freeMemory: return "Free Up Memory"
            case .clean: return "Open Disk › Clean"
            case .page(let p): return "Open " + (["cpu": "CPU", "memory": "Memory", "disk": "Disk", "network": "Network", "gpu": "GPU",
                                           "battery": "Energy", "sensors": "Sensors", "display": "Display", "cloud": "Cloud Disks"][p] ?? p.capitalized)
            case .section(let s): return "Open " + (["processes": "Processes", "startup": "Startup", "history": "History", "services": "Services",
                                               "users": "Users", "servers": "Servers", "ai": "Assistant"][s] ?? s.capitalized)
            }
        }
        var symbol: String {
            switch self {
            case .freeMemory: "memorychip"
            case .clean: "sparkles"
            case .page: "chart.xyaxis.line"
            case .section: "arrow.up.forward.app"
            case .quitApps(_, _, let force): force ? "xmark.octagon.fill" : "xmark.circle.fill"
            case .stopProcesses: "stop.circle.fill"
            }
        }
    }

    /// An open app the agent can quit.
    struct App: Sendable, Equatable {
        let pid: Int32; let name: String
        /// When it started (µs), so the answer names this process exactly. 0: unknown.
        var startMicros: Int64 = 0
        var identity: ProcessIdentity { ProcessIdentity(pid: pid, startMicros: startMicros) }
    }
    /// One of your own processes the agent can stop.
    struct Proc: Sendable, Equatable {
        let pid: Int32; let name: String; let cpu: Double
        var startMicros: Int64 = 0
        var identity: ProcessIdentity { ProcessIdentity(pid: pid, startMicros: startMicros) }
    }

    /// What the agent knows about this Mac right now (from Apex's sample).
    struct Readings: Sendable {
        var apps: [App] = []
        var processes: [Proc] = []
        var cpu: Double = 0
        var busiest: [(name: String, cpu: Double)] = []
        var largest: [(name: String, bytes: UInt64)] = []
        var memoryUsed: UInt64 = 0, memoryTotal: UInt64 = 0
        var pressure = "Normal"
        var swap: UInt64 = 0
        var diskFree: UInt64 = 0, diskTotal: UInt64 = 0
        var battery: (percent: Int, health: Double, cycles: Int, onPower: Bool, temp: Double?)? = nil
        var cpuTemp: Double? = nil
        var network = ""
        var kernelTaskCPU: Double? = nil
        var windowServerCPU: Double? = nil
    }

    struct Answer: Equatable {
        var text: String
        var actions: [Action] = []
        /// Didn't understand: the reply suggests Lumen AI.
        var unknown = false
    }

    private struct Topic {
        let id: String
        /// Words and phrases with weights; a question scores the sum of the ones it contains.
        let words: [String: Int]
        let answer: (Readings) -> Answer
    }

    /// Picks the topic and answers. Pure: tested.
    static func answer(_ question: String, _ r: Readings) -> Answer {
        let q = " " + normalized(question) + " "
        if q.trimmingCharacters(in: .whitespaces).isEmpty { return fallback }
        if let a = command(q, r) { return a }
        if ["hi", "hello", "hey", "good morning", "good evening", "good afternoon"].contains(where: { q == " \($0) " }) {
            return Answer(text: "Hello! Ask me about your Mac: why it’s slow, what’s filling the disk, the battery, Wi-Fi and more.")
        }
        if ["thanks", "thank you", "thx", "cheers"].contains(where: { q.contains(" \($0) ") }) {
            return Answer(text: "You’re welcome. Anything else about your Mac?")
        }
        var best: (Topic, Int)?
        for t in topics {
            let score = t.words.reduce(0) { $0 + (q.contains(" \($1.key) ") ? $1.value : 0) }
            if score > (best?.1 ?? 0) { best = (t, score) }
        }
        guard let (topic, score) = best, score >= 2 else { return fallback }
        return topic.answer(r)
    }

    /// The topic an answer came from (for tests).
    static func topic(_ question: String) -> String? {
        let q = " " + normalized(question) + " "
        var best: (String, Int)?
        for t in topics {
            let score = t.words.reduce(0) { $0 + (q.contains(" \($1.key) ") ? $1.value : 0) }
            if score > (best?.1 ?? 0) { best = (t.id, score) }
        }
        return (best?.1 ?? 0) >= 2 ? best?.0 : nil
    }

    // MARK: Doing things

    /// The ways people ask to quit or stop something.
    private static let quitWords = ["quit", "close", "exit", "kill", "end", "stop", "terminate", "shut", "shutdown", "force"]
    private static let allWords = ["all", "every", "everything", "everyone", "each"]
    private static let appWords = ["app", "apps", "window", "windows", "task", "tasks", "running", "open"]
    private static let processWords = ["process", "processes"]
    /// Words that aren't an app's name when looking for one ("quit **word**" is Word only if Word is open).
    private static let filler: Set<String> = ["the", "my", "a", "an", "please", "can", "you", "could", "would", "for", "me", "i", "want",
                                              "to", "and", "of", "now", "just", "okay", "ok", "it", "that", "this", "are", "is", "not",
                                              "using", "use", "in", "on", "too", "also", "some"]

    /// "Close all my apps", "quit Chrome", "close everything except Safari",
    /// "force quit Word", "stop process node". Nil when it isn't a command. Pure: tested.
    static func command(_ q: String, _ r: Readings) -> Answer? {
        let words = q.split(separator: " ").map(String.init)
        guard let verbAt = words.firstIndex(where: { quitWords.contains($0) }) else { return nil }
        // "Why won't it shut down" or "how do I force quit" are questions, not commands.
        if let first = words.first, ["how", "why", "what", "when", "where", "does", "is", "should"].contains(first) { return nil }
        let force = words.contains("force")
        var rest = Array(words[(verbAt + 1)...]).filter { !quitWords.contains($0) }
        // "...except Safari and Word" / "but Safari": those stay open.
        var keepNames: [String] = []
        if let cut = rest.firstIndex(where: { ["except", "but", "besides", "apart", "other", "without", "excluding", "keep"].contains($0) }) {
            keepNames = Array(rest[(cut + 1)...]); rest = Array(rest[..<cut])
        }
        let wantsProcesses = rest.contains(where: processWords.contains)
        let saysAll = rest.contains(where: allWords.contains) || (rest.contains(where: appWords.contains) && !wantsProcesses)
        let named = matches(rest, in: r.apps)
        let kept = matches(keepNames, in: r.apps)

        if wantsProcesses {
            let wanted = rest.filter { !filler.contains($0) && !processWords.contains($0) && !allWords.contains($0) }
            let found = r.processes.filter { p in wanted.contains { p.name.lowercased() == $0 || p.name.lowercased().hasPrefix($0) } }
            if !found.isEmpty {
                return Answer(text: "I found " + list(found.map(\.name)) + ". Stopping " + (found.count == 1 ? "it" : "them") + " ends " + (found.count == 1 ? "it" : "them") + " straight away; anything unsaved in " + (found.count == 1 ? "it" : "them") + " is lost.",
                              actions: [.stopProcesses(targets: found.map(\.identity), names: found.map(\.name))])
            }
            let busy = r.processes.filter { $0.cpu >= 5 }.prefix(3)
            if busy.isEmpty { return Answer(text: "None of your processes is doing much right now, so there’s nothing worth stopping. macOS’s own processes are never stopped.") }
            return Answer(text: "Which one? Your busiest processes right now are " + list(busy.map { "**\($0.name)** (\(Int($0.cpu))% CPU)" }) + ". I only stop your own processes, never macOS’s.",
                          actions: busy.map { .stopProcesses(targets: [$0.identity], names: [$0.name]) } + [.section("processes")])
        }
        if !named.isEmpty && !saysAll {
            return Answer(text: (force ? "I’ll force quit " : "I’ll quit ") + list(named.map { "**\($0.name)**" }) + "." + (force ? " Force quitting loses anything unsaved." : " It will ask you to save anything unsaved first."),
                          actions: [.quitApps(targets: named.map(\.identity), names: named.map(\.name), force: force)])
        }
        if saysAll {
            let targets = r.apps.filter { a in !kept.contains(a) }
            guard !targets.isEmpty else { return Answer(text: "There are no other apps open to quit.") }
            let keepNote = kept.isEmpty ? "" : " " + list(kept.map { "**\($0.name)**" }) + " stays open."
            return Answer(text: "I’ll quit these \(targets.count) app\(targets.count == 1 ? "" : "s"): " + list(targets.map(\.name)) + "." + keepNote
                          + (force ? " Force quitting loses anything unsaved." : " Each one asks you to save first if it needs to.") + " Finder and Apex stay open.",
                          actions: [.quitApps(targets: targets.map(\.identity), names: targets.map(\.name), force: force)])
        }
        let wanted = rest.filter { !filler.contains($0) && !appWords.contains($0) }
        if !wanted.isEmpty {
            return Answer(text: "I can’t find an open app called “\(wanted.joined(separator: " "))”. " + (r.apps.isEmpty ? "No apps are open." : "Open apps: " + list(r.apps.map(\.name)) + "."))
        }
        return nil
    }

    /// Open apps named in the words: the whole name ("google chrome"), or one
    /// of its distinctive words ("chrome", "word"). Pure.
    static func matches(_ words: [String], in apps: [App]) -> [App] {
        let text = " " + words.joined(separator: " ") + " "
        return apps.filter { a in
            let name = normalized(a.name)
            if text.contains(" \(name) ") { return true }
            return name.split(separator: " ").contains { w in w.count >= 3 && !filler.contains(String(w)) && words.contains(String(w)) }
        }
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }

    static let fallback = Answer(text: "I can’t answer that one. I know the common questions about your Mac, like speed, storage, battery, heat, Wi-Fi and apps that freeze, but not this. **Please try Lumen AI**: it can look at what’s going on and answer anything about your Mac.", unknown: true)

    /// Lower case, letters and digits only, single spaces; a few spellings evened out.
    static func normalized(_ s: String) -> String {
        let lowered = s.lowercased().replacingOccurrences(of: "’", with: "'")
        var out = ""
        for ch in lowered { out.append(ch.isLetter || ch.isNumber ? ch : " ") }
        var words = out.split(separator: " ").map(String.init)
        let same = ["macbook": "mac", "imac": "mac", "laptop": "mac", "computer": "mac", "wifi": "wi fi", "wireless": "wi fi",
                    "ram": "memory", "storage": "disk", "space": "disk", "hdd": "disk", "ssd": "disk", "drive": "disk",
                    "laggy": "slow", "lag": "slow", "lagging": "slow", "sluggish": "slow", "slower": "slow", "freezing": "frozen",
                    "freezes": "frozen", "freeze": "frozen", "hung": "frozen", "unresponsive": "frozen", "hot": "heat",
                    "overheating": "heat", "warm": "heat", "temperature": "heat", "fans": "fan", "noisy": "loud", "noise": "loud",
                    "drains": "drain", "draining": "drain", "dies": "drain", "charging": "charge", "charger": "charge",
                    "apps": "app", "applications": "app", "application": "app", "programs": "app", "program": "app",
                    "internet": "wi fi", "connection": "wi fi", "disconnects": "disconnect", "disconnecting": "disconnect",
                    "virus": "malware", "viruses": "malware", "hacked": "malware", "spyware": "malware", "adware": "malware",
                    "startup": "login", "boot": "login", "booting": "login", "full": "full", "cleanup": "clean", "clear": "clean",
                    "beachball": "spinning", "rainbow": "spinning", "wheel": "spinning", "headphones": "bluetooth", "airpods": "bluetooth",
                    "mouse": "bluetooth", "keyboard": "bluetooth", "sleeping": "sleep", "asleep": "sleep", "update": "update", "upgrade": "update",
                    "processes": "process", "kernel_task": "kernel task"]
        words = words.flatMap { (same[$0] ?? $0).split(separator: " ").map(String.init) }
        return words.joined(separator: " ")
    }

    // MARK: Topics

    private static func gb(_ b: UInt64) -> String { Fmt.diskBytes(b) }

    private static let topics: [Topic] = [
        Topic(id: "slow", words: ["slow": 3, "spinning": 3, "speed up": 3, "faster": 2, "performance": 2, "frozen": 1, "mac": 0]) { r in
            var lines = ["Here’s what’s slowing your Mac down right now:"]
            if let top = r.busiest.first, top.cpu >= 50 {
                lines.append("- **\(top.name)** is using \(Int(top.cpu))% of the processor. Quit it if you don’t need it, or click **Optimize** on it in Processes.")
            }
            if r.pressure != "Normal" {
                lines.append("- Memory pressure is **\(r.pressure)**" + (r.swap > 0 ? ", with \(gb(r.swap)) moved to the disk (swap)." : ".") + " The Mac is short of memory.")
            }
            if r.diskTotal > 0, Double(r.diskFree) / Double(r.diskTotal) < 0.1 {
                lines.append("- The startup disk is nearly full (\(gb(r.diskFree)) free). macOS slows down below about 10% free.")
            }
            if let t = r.cpuTemp, t >= 90 { lines.append("- The processor is hot (\(Int(t)) °C), so macOS is slowing it to cool down.") }
            if lines.count == 1 {
                lines = ["Nothing is overloading your Mac right now: the processor is at \(Int(r.cpu))%, memory pressure is \(r.pressure), and there’s \(gb(r.diskFree)) free.",
                         "", "If it felt slow a moment ago, check **History** for what was busy then. A restart once a week also helps."]
            } else {
                lines += ["", "Steps that help most:", "1. Quit apps you’re not using (and browser tabs).", "2. Click **Free Up Memory**.", "3. Restart if it’s been days."]
            }
            return Answer(text: lines.joined(separator: "\n"), actions: [.section("processes"), .freeMemory])
        },
        Topic(id: "storage", words: ["disk": 2, "full": 2, "free up": 3, "clean": 2, "system data": 4, "other": 1, "gb": 1, "large files": 3, "delete": 1, "running out": 2]) { r in
            let pct = r.diskTotal > 0 ? Int(Double(r.diskFree) / Double(r.diskTotal) * 100) : 0
            return Answer(text: """
            Your startup disk has **\(gb(r.diskFree)) free** of \(gb(r.diskTotal)) (\(pct)%).

            To get space back safely:
            1. Open **Disk › Clean**: it finds temporary app files, old installers and leftovers from deleted apps, and moves them to the Trash.
            2. Use **Disk › Analyze** to see which folders are biggest.
            3. Empty the Trash afterwards.

            “System Data” is mostly caches, logs and local Time Machine snapshots; Clean removes the safe parts. Your own documents and photos are never included.
            """, actions: [.clean, .page("disk")])
        },
        Topic(id: "battery-drain", words: ["battery": 1, "drain": 3, "fast": 1, "quickly": 1, "lasts": 2, "battery life": 3, "percent": 1]) { r in
            var t = "Battery life depends most on what’s running."
            if let top = r.busiest.first, top.cpu >= 20 { t += " Right now **\(top.name)** is the busiest app (\(Int(top.cpu))% CPU)." }
            if let b = r.battery { t += " The battery is at \(b.percent)% and its health is \(Int(b.health))%." }
            t += """


            To make it last longer:
            1. Open **Energy** to see which apps use the most power, and quit the ones you don’t need.
            2. Lower the screen brightness: the display uses the most power.
            3. Turn on Low Power Mode in System Settings › Battery.
            4. Video calls, games and browser tabs with video drain it fastest.
            """
            return Answer(text: t, actions: [.page("battery")])
        },
        Topic(id: "battery-health", words: ["battery": 1, "health": 3, "healthy": 3, "cycle": 3, "cycles": 3, "replace": 2, "service": 2, "condition": 2, "capacity": 2]) { r in
            guard let b = r.battery else { return Answer(text: "This Mac has no battery, so there’s nothing to check.") }
            let verdict = b.health >= 80 ? "That’s healthy." : "Below 80% is when Apple suggests a replacement."
            return Answer(text: """
            Your battery holds **\(Int(b.health))%** of its original charge after **\(b.cycles) cycles**. \(verdict)

            Most Mac batteries are designed for 1,000 cycles. To slow the wear, keep it between about 20% and 80% when you can; **Energy** has a charge limit for that.
            """, actions: [.page("battery")])
        },
        Topic(id: "heat", words: ["heat": 3, "fan": 3, "loud": 2, "burning": 2, "cool": 1]) { r in
            var t = r.cpuTemp.map { "The processor is at **\(Int($0)) °C**. " } ?? ""
            if let top = r.busiest.first, top.cpu >= 40 { t += "**\(top.name)** is working hard (\(Int(top.cpu))% CPU), which makes heat. " }
            t += """
            Macs run warm under load; above about 95 °C they slow down to protect themselves.

            To cool it:
            1. Quit or **Optimize** the busiest app.
            2. Keep the vents clear: use it on a hard, flat surface, not a bed or lap.
            3. Close browser tabs that play video or ads.
            """
            return Answer(text: t, actions: [.page("sensors"), .section("processes")])
        },
        Topic(id: "wifi", words: ["wi": 1, "fi": 1, "wi fi": 3, "network": 2, "disconnect": 3, "router": 2, "no internet": 3, "slow internet": 3, "ping": 2]) { r in
            Answer(text: """
            \(r.network.isEmpty ? "Your Mac isn’t connected to a network right now." : "You’re connected through \(r.network).")

            Open **Network** and click **Network Doctor**: it tests each step (Wi-Fi, router, internet, names) and says which one fails.

            Quick fixes:
            1. Turn Wi-Fi off and on from the menu bar.
            2. Restart the router (unplug it for 10 seconds).
            3. Move closer to the router, or away from microwaves and thick walls.
            4. In Network, the **Traffic** list shows which app is using your connection.
            """, actions: [.page("network")])
        },
        Topic(id: "frozen", words: ["frozen": 3, "not responding": 4, "force quit": 4, "stuck": 2, "crash": 2, "crashes": 2, "won t close": 3]) { _ in
            Answer(text: """
            To close an app that’s stuck:
            1. In **Processes**, select it and press **⌘⌫** (Quit), or **⌥⌘⌫** to force it.
            2. Or press **⌥⌘Esc** for macOS’s Force Quit window.

            Unsaved work in a force-quit app is lost. If the same app keeps freezing, update it, and check **History** for when it started using a lot of CPU or memory.
            """, actions: [.section("processes")])
        },
        Topic(id: "kernel", words: ["kernel task": 5, "kernel": 3]) { r in
            let now = r.kernelTaskCPU.map { " Right now it’s using \(Int($0))%." } ?? ""
            return Answer(text: """
            **kernel_task** is macOS itself.\(now) When the Mac gets hot, macOS makes kernel_task look busy on purpose, so other apps get less processor time and the Mac cools down.

            It isn’t a virus and can’t be quit. Bring the heat down instead: quit the busiest app and keep the vents clear.
            """, actions: [.page("sensors"), .section("processes")])
        },
        Topic(id: "windowserver", words: ["windowserver": 5, "window server": 5]) { r in
            let now = r.windowServerCPU.map { " Right now it’s using \(Int($0))%." } ?? ""
            return Answer(text: """
            **WindowServer** draws everything on your screens.\(now) It gets busy with many open windows, big external displays, transparency effects and animated wallpapers.

            To calm it: close windows you don’t need, turn on Reduce Transparency in System Settings › Accessibility › Display, and use fewer or smaller external displays.
            """, actions: [.section("processes"), .page("display")])
        },
        Topic(id: "memory", words: ["memory": 3, "using my memory": 4, "swap": 3, "pressure": 2, "out of": 1, "application memory": 4]) { r in
            var t = "You’re using **\(Fmt.bytes(r.memoryUsed)) of \(Fmt.bytes(r.memoryTotal))**, and memory pressure is **\(r.pressure)**."
            if r.swap > 0 { t += " \(gb(r.swap)) has been moved to the disk (swap)." }
            if let big = r.largest.first { t += " The biggest app is **\(big.name)** (\(Fmt.bytes(big.bytes)))." }
            t += """


            Used memory being high is normal: macOS keeps things ready. What matters is pressure: Normal is fine, Elevated means it’s squeezing, Critical means it’s slowing down.

            **Free Up Memory** quits or trims what you choose, safely.
            """
            return Answer(text: t, actions: [.freeMemory, .page("memory")])
        },
        Topic(id: "login", words: ["login": 3, "turn on": 1, "starts": 1, "open at": 2, "launch": 1, "launch agents": 4, "background items": 4]) { _ in
            Answer(text: """
            Apps that open when you log in slow the start and keep using memory.

            Open **Startup** to see every login item and background helper, what each one is, and turn off the ones you don’t need. Turning one off doesn’t delete the app.
            """, actions: [.section("startup")])
        },
        Topic(id: "sleep", words: ["sleep": 3, "won t sleep": 4, "wakes": 2, "awake": 2, "lid": 2]) { _ in
            Answer(text: """
            When the Mac won’t sleep (or the battery drops overnight), an app is usually holding it awake: a download, music, a backup or a video call.

            **Energy** lists what’s keeping the Mac awake right now. Quit that app, or let it finish, and it will sleep. Apex can also keep it awake on purpose with the lid closed.
            """, actions: [.page("battery")])
        },
        Topic(id: "eject", words: ["eject": 4, "external": 2, "usb": 2, "not showing": 3, "in use": 3, "can t eject": 4]) { _ in
            Answer(text: """
            If a drive won’t eject, an app still has a file on it open. Press **⇧⌘U** (What’s Using a File or Disk) to see which app, close it, then eject.

            If a drive doesn’t show up, open **Disk** and choose it: **Drive Doctor** checks and repairs it. Try another cable and port, too.
            """, actions: [.page("disk")])
        },
        Topic(id: "bluetooth", words: ["bluetooth": 4, "pair": 2, "pairing": 2, "connect": 1]) { _ in
            Answer(text: """
            For a Bluetooth device that drops or won’t connect:
            1. Charge it: low batteries cause most drop-outs (the menu bar panel shows their charge).
            2. Turn Bluetooth off and on in Control Centre.
            3. Remove the device in System Settings › Bluetooth and pair it again.
            4. Keep it close; USB 3 hubs and Wi-Fi on 2.4 GHz can interfere.
            """)
        },
        Topic(id: "malware", words: ["malware": 5, "safe": 1, "suspicious": 3, "unknown process": 3, "security": 2]) { _ in
            Answer(text: """
            Signs of unwanted software: a browser homepage that changed by itself, pop-ups, or an unknown app using a lot of CPU.

            In **Processes**, select anything you don’t recognise and choose **Get Info**: it shows who signed it and where it lives. Anything signed by Apple is part of macOS. Check **Startup** for login items you didn’t add, and keep macOS updated.
            """, actions: [.section("processes"), .section("startup")])
        },
        Topic(id: "background", words: ["mds": 4, "mds stores": 5, "spotlight": 4, "indexing": 4, "photoanalysisd": 5, "cloudd": 5, "bird": 3, "syncing": 2]) { _ in
            Answer(text: """
            Those are macOS’s own background jobs:
            - **mds / mds_stores**: Spotlight indexing your files (busy after updates or new files).
            - **photoanalysisd**: Photos finding faces and objects.
            - **cloudd / bird**: iCloud syncing.

            They calm down by themselves, usually within an hour, and pause on battery. Leaving the Mac plugged in and awake lets them finish faster.
            """, actions: [.section("processes")])
        },
        Topic(id: "backup", words: ["backup": 4, "back up": 4, "time machine": 5]) { _ in
            Answer(text: """
            Time Machine backs up everything to an external drive every hour. Connect a drive at least as big as your Mac’s, then System Settings › General › Time Machine › Add Backup Disk.

            Keep one backup away from the Mac (another drive at work, or iCloud for documents and photos).
            """)
        },
        Topic(id: "macos-update", words: ["update": 2, "macos": 2, "software update": 4, "sequoia": 2, "version": 1]) { _ in
            Answer(text: """
            Updates fix security problems, so it’s worth installing them. Check System Settings › General › Software Update.

            Before a big update: have a backup, about 25 GB free on the disk, and the Mac plugged in.
            """)
        },
        Topic(id: "restart", words: ["restart": 3, "shut down": 3, "reboot": 3, "how often": 2]) { _ in
            Answer(text: "Restarting once a week clears memory and finishes updates. You don’t need to shut down every night: sleep uses very little power.")
        },
        Topic(id: "disk-health", words: ["disk health": 5, "health": 1, "wear": 3, "smart": 3, "failing": 3, "dying": 3]) { _ in
            Answer(text: """
            Open **Disk** and look at **Drive health**: it shows the drive’s own health reading, how much has been written over its life, and whether anything is wrong. **Drive Doctor** can check and repair the file system.
            """, actions: [.page("disk")])
        },
        Topic(id: "usage", words: ["using my": 2, "what s using": 3, "which app": 3, "who is using": 3, "bandwidth": 3, "data usage": 3]) { r in
            var t = "Right now:"
            if let c = r.busiest.first { t += "\n- Processor: **\(c.name)** (\(Int(c.cpu))%)" }
            if let m = r.largest.first { t += "\n- Memory: **\(m.name)** (\(Fmt.bytes(m.bytes)))" }
            t += "\n\nFor the internet, **Network › Traffic** lists each app’s connections and speed. **Processes** sorts every app by CPU, memory, disk, network or energy."
            return Answer(text: t, actions: [.section("processes"), .page("network")])
        },
        Topic(id: "apex", words: ["apex": 4, "what can you do": 4, "help": 1, "how do i use": 3, "features": 2]) { _ in
            Answer(text: """
            Apex shows what your Mac is doing and helps fix it:
            - **Processes**: every app and what it uses; quit, force quit or optimize.
            - **Performance**: CPU, memory, disk, network, GPU, display, energy and temperatures, with **Free Up Memory**, **Disk › Clean**, **Drive Doctor** and **Network Doctor**.
            - **Startup**: what opens at login.
            - **History**: what happened earlier.
            - The **shelf**: shake a file while dragging it to hold it, compress it or share it.
            - **Record**: save a recording to give to an AI.

            Ask me a question, or switch to Lumen AI for anything else.
            """)
        },
    ]
}

extension ApexAgent.Readings {
    /// From Apex's latest sample. Main actor.
    @MainActor static func current() -> ApexAgent.Readings {
        let m = AppModel.shared, s = m.snapshot, sys = s.system, hw = HardwareStore.shared
        var r = ApexAgent.Readings()
        r.cpu = sys.cpu.total
        // Apex itself isn't suggested (it's what's asking).
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = s.processes.filter { $0.isRegularApp && $0.pid != me && $0.appName != "Apex Activity Manager" }
        r.busiest = apps.sorted { $0.cpu > $1.cpu }.prefix(3).map { ($0.appName ?? $0.name, $0.cpu) }
        r.largest = apps.sorted { $0.memory > $1.memory }.prefix(3).map { ($0.appName ?? $0.name, $0.memory) }
        r.memoryUsed = sys.memory.used; r.memoryTotal = sys.memory.total
        r.pressure = sys.memory.pressureLevel.title
        r.swap = sys.memory.swapUsed
        r.diskFree = sys.disk.available; r.diskTotal = sys.disk.capacity
        if hw.hasBattery {
            let b = hw.battery
            r.battery = (b.percent, b.health, b.cycleCount, b.onAC, b.temperature)
        }
        r.cpuTemp = hw.sensors.cpuTemp
        r.network = sys.network.interface
        // Open apps that can be quit: not Apex, not Finder.
        r.apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && $0.bundleIdentifier != "com.apple.finder" }
            .compactMap { a in a.localizedName.map {
                ApexAgent.App(pid: a.processIdentifier, name: $0, startMicros: ProcessIdentity.current(a.processIdentifier)?.startMicros ?? 0)
            } }
        // Your own processes that aren't apps (never macOS's own, never Apex).
        let uid = getuid()
        let protected: Set<String> = ["Finder", "Dock", "WindowServer", "loginwindow", "SystemUIServer", "ControlCenter", "launchd", "TaskManager"]
        r.processes = s.processes.filter { $0.uid == uid && !$0.isRegularApp && $0.pid != me && !protected.contains($0.name) && !$0.path.hasPrefix("/System/") && !$0.path.hasPrefix("/usr/libexec/") }
            .sorted { $0.cpu > $1.cpu }.map { ApexAgent.Proc(pid: $0.pid, name: $0.name, cpu: $0.cpu, startMicros: $0.startedMicros) }
        r.kernelTaskCPU = s.processes.first { $0.name == "kernel_task" }?.cpu
        r.windowServerCPU = s.processes.first { $0.name == "WindowServer" }?.cpu
        return r
    }
}
