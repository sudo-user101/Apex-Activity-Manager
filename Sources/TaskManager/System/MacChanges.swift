import AppKit
import Foundation

/// Settings › MacOSX Change: macOS settings that System Settings hides (or
/// buries), switched for this user only (no password). Turning a switch on
/// remembers exactly what was there before; turning it off puts that back
/// (or macOS's default, if it was never set). What's shown is read live from
/// macOS, so a change made in System Settings or Terminal shows here too.
/// Written through CFPreferences (cfprefsd), like `defaults write`.

/// A preference value as it's written.
enum PrefValue: Codable, Hashable, Sendable {
    case bool(Bool), int(Int), double(Double), string(String)

    var plist: CFPropertyList {
        switch self {
        case .bool(let b): return b as CFBoolean
        case .int(let i): return i as NSNumber
        case .double(let d): return d as NSNumber
        case .string(let s): return s as CFString
        }
    }

    /// Does the value read from macOS mean the same? Booleans come back as
    /// 0 / 1 numbers, numbers as either kind, doubles within a hair. Pure: tested.
    func matches(_ read: Any?) -> Bool {
        switch self {
        case .bool(let b):
            if let n = read as? NSNumber { return n.boolValue == b }
            if let s = read as? String { return (s == "1" || s.lowercased() == "true" || s.uppercased() == "YES") == b }
            return false
        case .int(let i): return (read as? NSNumber)?.doubleValue == Double(i)
        case .double(let d): return (read as? NSNumber).map { abs($0.doubleValue - d) < 0.0001 } ?? false
        case .string(let s): return (read as? String) == s
        }
    }

    /// From what macOS holds, to remember and put back later. Pure: tested.
    static func from(_ any: Any?) -> PrefValue? {
        switch any {
        case let s as String: return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return CFNumberIsFloatType(n as CFNumber) ? .double(n.doubleValue) : .int(n.intValue)
        default: return nil
        }
    }
}

/// One preference: `domain` is an app's ("com.apple.dock") or the global one.
struct Pref: Hashable, Sendable {
    static let global = "NSGlobalDomain"
    var domain: String
    var key: String
    var value: PrefValue
    var id: String { domain + "|" + key }
}

/// What has to restart before macOS uses the change.
enum MacRestart: Sendable {
    case none, dock, finder, systemUI, apps, logout
    var note: String {
        switch self {
        case .none: return ""
        case .dock: return "The Dock restarts."
        case .finder: return "Finder restarts (its windows reopen)."
        case .systemUI: return ""
        case .apps: return "Apps opened after this use it."
        case .logout: return "Takes effect after you log out and back in."
        }
    }
}

/// A switch: on = every pref holds its value.
struct MacChange: Identifiable, Sendable {
    var id: String
    var group: String
    var title: String
    var detail: String
    var prefs: [Pref]
    var restart: MacRestart
}

/// A choice between values of one preference ("" = macOS's default, key removed).
struct MacChoice: Identifiable, Sendable {
    var id: String
    var group: String
    var title: String
    var detail: String
    var domain: String
    var key: String
    var options: [(title: String, value: PrefValue?)]
    var restart: MacRestart
}

enum MacChanges {
    static let groups = ["Desktop & Spaces", "Dock", "Finder", "Screenshots", "Windows & dialogs", "Keyboard & typing", "Mouse",
                         "Clipboard & links", "Apps & system"]

    private static func p(_ domain: String, _ key: String, _ v: PrefValue) -> Pref { Pref(domain: domain, key: key, value: v) }
    private static let dock = "com.apple.dock", finder = "com.apple.finder", shots = "com.apple.screencapture", g = Pref.global

    static let switches: [MacChange] = [
        // Desktop & Spaces
        .init(id: "spaces.fixed", group: "Desktop & Spaces", title: "Keep Spaces in the order you set",
              detail: "macOS normally moves Spaces around by which you used last.", prefs: [p(dock, "mru-spaces", .bool(false))], restart: .dock),
        .init(id: "desktop.hideIcons", group: "Desktop & Spaces", title: "Hide the icons on the desktop",
              detail: "The files stay in the Desktop folder; only the icons on screen go.", prefs: [p(finder, "CreateDesktop", .bool(false))], restart: .finder),
        .init(id: "mission.group", group: "Desktop & Spaces", title: "Group windows by app in Mission Control",
              detail: "", prefs: [p(dock, "expose-group-apps", .bool(true))], restart: .dock),
        .init(id: "mission.fast", group: "Desktop & Spaces", title: "Faster Mission Control animation",
              detail: "", prefs: [p(dock, "expose-animation-duration", .double(0.1))], restart: .dock),
        .init(id: "desktop.foldersFirst", group: "Desktop & Spaces", title: "Keep folders on top on the desktop",
              detail: "When the desktop is sorted by name.", prefs: [p(finder, "_FXSortFoldersFirstOnDesktop", .bool(true))], restart: .finder),
        // Dock
        .init(id: "dock.autohide", group: "Dock", title: "Hide the Dock until you point at it",
              detail: "", prefs: [p(dock, "autohide", .bool(true))], restart: .dock),
        .init(id: "dock.instant", group: "Dock", title: "Show a hidden Dock straight away",
              detail: "No pause before it slides in, and a quicker slide.",
              prefs: [p(dock, "autohide-delay", .double(0)), p(dock, "autohide-time-modifier", .double(0.25))], restart: .dock),
        .init(id: "dock.noRecents", group: "Dock", title: "Don’t show recent apps in the Dock",
              detail: "", prefs: [p(dock, "show-recents", .bool(false))], restart: .dock),
        .init(id: "dock.dimHidden", group: "Dock", title: "Dim the icons of hidden apps",
              detail: "Apps hidden with ⌘H look faded, so you can tell them apart.", prefs: [p(dock, "showhidden", .bool(true))], restart: .dock),
        .init(id: "dock.runningOnly", group: "Dock", title: "Only show open apps in the Dock",
              detail: "Apps kept in the Dock appear only while they’re open.", prefs: [p(dock, "static-only", .bool(true))], restart: .dock),
        .init(id: "dock.minimizeIntoApp", group: "Dock", title: "Minimize windows into their app’s icon",
              detail: "", prefs: [p(dock, "minimize-to-application", .bool(true))], restart: .dock),
        .init(id: "dock.scrollToOpen", group: "Dock", title: "Scroll up on a Dock icon to see its windows",
              detail: "", prefs: [p(dock, "scroll-to-open", .bool(true))], restart: .dock),
        .init(id: "dock.singleApp", group: "Dock", title: "Clicking an app in the Dock hides the others",
              detail: "Only the app you click stays visible.", prefs: [p(dock, "single-app", .bool(true))], restart: .dock),
        .init(id: "dock.noLaunchAnimation", group: "Dock", title: "Don’t bounce icons while apps open",
              detail: "", prefs: [p(dock, "launchanim", .bool(false))], restart: .dock),
        .init(id: "dock.noBouncing", group: "Dock", title: "Apps don’t bounce to get your attention",
              detail: "They still show a badge.", prefs: [p(dock, "no-bouncing", .bool(true))], restart: .dock),
        .init(id: "dock.lockContents", group: "Dock", title: "Lock what’s in the Dock",
              detail: "Icons can’t be dragged off or added by accident.", prefs: [p(dock, "contents-immutable", .bool(true))], restart: .dock),
        .init(id: "dock.lockSize", group: "Dock", title: "Lock the Dock’s size",
              detail: "", prefs: [p(dock, "size-immutable", .bool(true))], restart: .dock),
        .init(id: "dock.stackHighlight", group: "Dock", title: "Highlight items when pointing at a stack’s grid",
              detail: "", prefs: [p(dock, "mouse-over-hilite-stack", .bool(true))], restart: .dock),
        .init(id: "dock.springAll", group: "Dock", title: "Drag a file onto any Dock icon to open it there",
              detail: "Hold a dragged file over an app to bring it forward.", prefs: [p(dock, "enable-spring-load-actions-on-all-items", .bool(true))], restart: .dock),
        // Finder
        .init(id: "finder.hidden", group: "Finder", title: "Show hidden files",
              detail: "Files starting with a dot and system folders appear, faded. ⇧⌘. does the same in a window.",
              prefs: [p(finder, "AppleShowAllFiles", .bool(true))], restart: .finder),
        .init(id: "finder.extensions", group: "Finder", title: "Show every file extension",
              detail: "", prefs: [p(g, "AppleShowAllExtensions", .bool(true))], restart: .finder),
        .init(id: "finder.pathbar", group: "Finder", title: "Show the path bar", detail: "Where the folder is, at the bottom of each window.",
              prefs: [p(finder, "ShowPathbar", .bool(true))], restart: .finder),
        .init(id: "finder.statusbar", group: "Finder", title: "Show the status bar", detail: "Item count and free space.",
              prefs: [p(finder, "ShowStatusBar", .bool(true))], restart: .finder),
        .init(id: "finder.foldersFirst", group: "Finder", title: "Keep folders on top when sorting by name",
              detail: "", prefs: [p(finder, "_FXSortFoldersFirst", .bool(true))], restart: .finder),
        .init(id: "finder.searchHere", group: "Finder", title: "Search the folder you’re in",
              detail: "Instead of the whole Mac.", prefs: [p(finder, "FXDefaultSearchScope", .string("SCcf"))], restart: .finder),
        .init(id: "finder.noExtensionWarning", group: "Finder", title: "Don’t warn when changing an extension",
              detail: "", prefs: [p(finder, "FXEnableExtensionChangeWarning", .bool(false))], restart: .finder),
        .init(id: "finder.fullPathTitle", group: "Finder", title: "Show the full path in the window title",
              detail: "", prefs: [p(finder, "_FXShowPosixPathInTitle", .bool(true))], restart: .finder),
        .init(id: "finder.noDSStore", group: "Finder", title: "No .DS_Store files on network and USB drives",
              detail: "Keeps drives shared with Windows and Linux tidy. Finder forgets view settings there.",
              prefs: [p("com.apple.desktopservices", "DSDontWriteNetworkStores", .bool(true)),
                      p("com.apple.desktopservices", "DSDontWriteUSBStores", .bool(true))], restart: .finder),
        .init(id: "finder.quit", group: "Finder", title: "Add Quit Finder to the Finder menu",
              detail: "⌘Q closes Finder like any app; its desktop icons go until you open it again.",
              prefs: [p(finder, "QuitMenuItem", .bool(true))], restart: .finder),
        .init(id: "finder.noAnimations", group: "Finder", title: "No Finder animations",
              detail: "Get Info and other windows appear at once.", prefs: [p(finder, "DisableAllAnimations", .bool(true))], restart: .finder),
        .init(id: "finder.fastSpring", group: "Finder", title: "Folders spring open faster while dragging",
              detail: "", prefs: [p(g, "com.apple.springing.delay", .double(0.2))], restart: .apps),
        .init(id: "finder.titleIcon", group: "Finder", title: "Show the folder icon in the title straight away",
              detail: "Normally it appears only after pointing at the title for a moment.",
              prefs: [p(g, "NSToolbarTitleViewRolloverDelay", .double(0))], restart: .apps),
        // Screenshots
        .init(id: "shots.noShadow", group: "Screenshots", title: "No shadow around window screenshots",
              detail: "", prefs: [p(shots, "disable-shadow", .bool(true))], restart: .systemUI),
        .init(id: "shots.noThumbnail", group: "Screenshots", title: "No floating thumbnail after a screenshot",
              detail: "The file is saved straight away instead of after a few seconds.", prefs: [p(shots, "show-thumbnail", .bool(false))], restart: .systemUI),
        .init(id: "shots.noDate", group: "Screenshots", title: "No date and time in screenshot names",
              detail: "Files are named “Screenshot”, “Screenshot 1”…", prefs: [p(shots, "include-date", .bool(false))], restart: .systemUI),
        // Windows & dialogs
        .init(id: "ui.scrollbars", group: "Windows & dialogs", title: "Always show scroll bars",
              detail: "", prefs: [p(g, "AppleShowScrollBars", .string("Always"))], restart: .apps),
        .init(id: "ui.expandSave", group: "Windows & dialogs", title: "Open Save dialogs expanded",
              detail: "With the folder list showing, not just the name field.",
              prefs: [p(g, "NSNavPanelExpandedStateForSaveMode", .bool(true)), p(g, "NSNavPanelExpandedStateForSaveMode2", .bool(true))], restart: .apps),
        .init(id: "ui.expandPrint", group: "Windows & dialogs", title: "Open Print dialogs expanded",
              detail: "", prefs: [p(g, "PMPrintingExpandedStateForPrint", .bool(true)), p(g, "PMPrintingExpandedStateForPrint2", .bool(true))], restart: .apps),
        .init(id: "ui.saveLocal", group: "Windows & dialogs", title: "Save new documents to this Mac, not iCloud",
              detail: "", prefs: [p(g, "NSDocumentSaveNewDocumentsToCloud", .bool(false))], restart: .apps),
        .init(id: "ui.noWindowAnimations", group: "Windows & dialogs", title: "No zoom animation when windows open",
              detail: "", prefs: [p(g, "NSAutomaticWindowAnimationsEnabled", .bool(false))], restart: .apps),
        .init(id: "ui.quitPrinter", group: "Windows & dialogs", title: "Close the printer app when printing is done",
              detail: "", prefs: [p("com.apple.print.PrintingPrefs", "Quit When Finished", .bool(true))], restart: .none),
        .init(id: "ui.fastSheets", group: "Windows & dialogs", title: "Faster sheets and dialogs",
              detail: "Save and other sheets drop down almost at once.", prefs: [p(g, "NSWindowResizeTime", .double(0.001))], restart: .apps),
        .init(id: "ui.noAutoTerminate", group: "Windows & dialogs", title: "Don’t let macOS quietly quit idle apps",
              detail: "Apps with no windows stay open until you quit them.", prefs: [p(g, "NSDisableAutomaticTermination", .bool(true))], restart: .apps),
        .init(id: "ui.noScrollAnimation", group: "Windows & dialogs", title: "No animation when paging with keys",
              detail: "Page Up / Page Down and space jump at once.", prefs: [p(g, "NSScrollAnimationEnabled", .bool(false))], restart: .apps),
        // Keyboard & typing
        .init(id: "keys.repeat", group: "Keyboard & typing", title: "Holding a key repeats it",
              detail: "Instead of showing the accent menu (é, ü…).", prefs: [p(g, "ApplePressAndHoldEnabled", .bool(false))], restart: .apps),
        .init(id: "keys.fastRepeat", group: "Keyboard & typing", title: "Faster key repeat",
              detail: "Faster than the fastest setting in System Settings.",
              prefs: [p(g, "KeyRepeat", .int(2)), p(g, "InitialKeyRepeat", .int(15))], restart: .logout),
        .init(id: "keys.noSmartQuotes", group: "Keyboard & typing", title: "No smart quotes and dashes",
              detail: "Keeps \" and -- as typed (handy for code).",
              prefs: [p(g, "NSAutomaticQuoteSubstitutionEnabled", .bool(false)), p(g, "NSAutomaticDashSubstitutionEnabled", .bool(false))], restart: .apps),
        .init(id: "keys.noAutocorrect", group: "Keyboard & typing", title: "No automatic spelling correction",
              detail: "", prefs: [p(g, "NSAutomaticSpellingCorrectionEnabled", .bool(false))], restart: .apps),
        .init(id: "keys.noAutoCaps", group: "Keyboard & typing", title: "No automatic capital letters",
              detail: "", prefs: [p(g, "NSAutomaticCapitalizationEnabled", .bool(false))], restart: .apps),
        .init(id: "keys.noDoubleSpacePeriod", group: "Keyboard & typing", title: "Two spaces don’t type a full stop",
              detail: "", prefs: [p(g, "NSAutomaticPeriodSubstitutionEnabled", .bool(false))], restart: .apps),
        .init(id: "keys.noInlinePrediction", group: "Keyboard & typing", title: "No grey word predictions while typing",
              detail: "", prefs: [p(g, "NSAutomaticInlinePredictionEnabled", .bool(false))], restart: .apps),
        // Mouse
        .init(id: "mouse.noAcceleration", group: "Mouse", title: "Turn off mouse acceleration",
              detail: "The pointer moves the same distance however fast you move the mouse.",
              prefs: [p(g, "com.apple.mouse.scaling", .int(-1))], restart: .logout),
        // Apps & system
        .init(id: "sys.noCameraAutoOpen", group: "Apps & system", title: "Don’t open Photos when a phone or camera is plugged in",
              detail: "", prefs: [p("com.apple.ImageCapture", "disableHotPlug", .bool(true))], restart: .none),
        .init(id: "sys.noTimeMachineOffer", group: "Apps & system", title: "Don’t offer new drives for Time Machine",
              detail: "No “use this disk for backups?” each time a drive is plugged in.",
              prefs: [p("com.apple.TimeMachine", "DoNotOfferNewDisksForBackup", .bool(true))], restart: .none),
        .init(id: "sys.textEditPlain", group: "Apps & system", title: "TextEdit starts new documents as plain text",
              detail: "", prefs: [p("com.apple.TextEdit", "RichText", .bool(false))], restart: .none),
        .init(id: "sys.mailAddressOnly", group: "Apps & system", title: "Mail copies just the email address",
              detail: "“name@example.com” instead of “Name <name@example.com>”.",
              prefs: [p("com.apple.mail", "AddressesIncludeNameOnPasteboard", .bool(false))], restart: .none),
        .init(id: "sys.noMusicNotifications", group: "Apps & system", title: "No notification when the next song starts in Music",
              detail: "", prefs: [p("com.apple.Music", "userWantsPlaybackNotifications", .bool(false))], restart: .none),
    ]

    static let choices: [MacChoice] = [
        .init(id: "shots.format", group: "Screenshots", title: "Screenshot format", detail: "", domain: shots, key: "type",
              options: [("PNG (macOS’s default)", nil), ("JPEG (smaller)", .string("jpg")), ("HEIC (smallest)", .string("heic")),
                        ("PDF", .string("pdf")), ("TIFF", .string("tiff"))], restart: .systemUI),
        .init(id: "shots.place", group: "Screenshots", title: "Save screenshots to", detail: "", domain: shots, key: "location",
              options: [("Desktop (macOS’s default)", nil), ("Pictures › Screenshots", .string(NSHomeDirectory() + "/Pictures/Screenshots")),
                        ("Downloads", .string(NSHomeDirectory() + "/Downloads")), ("Documents", .string(NSHomeDirectory() + "/Documents"))],
              restart: .systemUI),
        .init(id: "dock.minimizeEffect", group: "Dock", title: "Minimize effect", detail: "", domain: dock, key: "mineffect",
              options: [("Genie (macOS’s default)", nil), ("Scale", .string("scale")), ("Suck (hidden in System Settings)", .string("suck"))],
              restart: .dock),
        .init(id: "finder.view", group: "Finder", title: "New windows open as", detail: "For folders you haven’t set a view for.",
              domain: finder, key: "FXPreferredViewStyle",
              options: [("Icons (macOS’s default)", nil), ("List", .string("Nlsv")), ("Columns", .string("clmv")), ("Gallery", .string("glyv"))],
              restart: .finder),
        .init(id: "sys.crashDialog", group: "Apps & system", title: "When an app crashes", detail: "", domain: "com.apple.CrashReporter", key: "DialogType",
              options: [("Show the report window (macOS’s default)", nil), ("Only a notification", .string("notification")),
                        ("Show nothing", .string("none"))], restart: .none),
    ]

    // MARK: Reading and writing

    static func read(_ domain: String, _ key: String) -> Any? {
        let app = domain == Pref.global ? kCFPreferencesAnyApplication : domain as CFString
        return CFPreferencesCopyValue(key as CFString, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    static func write(_ domain: String, _ key: String, _ value: PrefValue?) {
        let app = domain == Pref.global ? kCFPreferencesAnyApplication : domain as CFString
        CFPreferencesSetValue(key as CFString, value?.plist, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    static func isOn(_ c: MacChange) -> Bool { c.prefs.allSatisfy { $0.value.matches(read($0.domain, $0.key)) } }

    static func current(_ c: MacChoice) -> Int {
        let v = read(c.domain, c.key)
        return c.options.firstIndex { $0.value.map { $0.matches(v) } ?? (v == nil) } ?? 0
    }

    // MARK: What was there before (UserDefaults `macChangesBefore`: "domain|key" → value, or "" = wasn't set)

    static let beforeKey = "macChangesBefore"

    /// Remembered before the first change to that preference, never overwritten
    /// by a later one, so off always means "as it was before Apex". Pure: tested.
    static func remembering(_ before: [String: Any], _ prefs: [Pref], read: (Pref) -> Any?) -> [String: Any] {
        var out = before
        for p in prefs where out[p.id] == nil {
            let encoded = PrefValue.from(read(p)).flatMap { try? PropertyListEncoder().encode($0) }
            out[p.id] = encoded ?? Data()
        }
        return out
    }

    /// The value to put back for a preference: what was remembered, or nil
    /// (remove it: macOS's default). Pure: tested.
    static func restored(_ before: [String: Any], _ p: Pref) -> PrefValue? {
        guard let d = before[p.id] as? Data, !d.isEmpty else { return nil }
        return try? PropertyListDecoder().decode(PrefValue.self, from: d)
    }

    static func set(_ c: MacChange, on: Bool) {
        var before = UserDefaults.standard.dictionary(forKey: beforeKey) ?? [:]
        if on {
            before = remembering(before, c.prefs) { read($0.domain, $0.key) }
            c.prefs.forEach { write($0.domain, $0.key, $0.value) }
        } else {
            for p in c.prefs { write(p.domain, p.key, restored(before, p)); before[p.id] = nil }
        }
        UserDefaults.standard.set(before, forKey: beforeKey)
        restart(c.restart)
    }

    static func choose(_ c: MacChoice, _ index: Int) {
        guard c.options.indices.contains(index) else { return }
        let v = c.options[index].value
        if case .string(let path)? = v, c.key == "location" {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        write(c.domain, c.key, v)
        restart(c.restart)
    }

    /// Every switch back off and every choice back to macOS's default.
    static func undoAll() {
        for c in switches where isOn(c) || c.prefs.contains(where: { (UserDefaults.standard.dictionary(forKey: beforeKey) ?? [:])[$0.id] != nil }) {
            set(c, on: false)
        }
        for c in choices where current(c) != 0 { choose(c, 0) }
    }

    /// Restarts what reads the setting only at launch. The Dock, Finder and
    /// SystemUIServer come straight back (macOS relaunches them).
    static func restart(_ r: MacRestart) {
        let name: String
        switch r {
        case .dock: name = "Dock"
        case .finder: name = "Finder"
        case .systemUI: name = "SystemUIServer"
        default: return
        }
        _ = Shell.run("/usr/bin/killall", [name])
    }
}
