import AppKit
import Carbon.HIToolbox

/// System-wide keyboard shortcuts (Carbon hot keys: no permission needed,
/// they fire only for their exact key combination). Each has an id; one
/// handler sends a press to that id's action.
@MainActor
enum HotKeyCenter {
    private static var handler: EventHandlerRef?
    private static var refs: [UInt32: EventHotKeyRef] = [:]
    private static var actions: [UInt32: () -> Void] = [:]

    /// Registers `combo` for `id` (replacing what that id had; nil = none).
    /// False if another app already uses the combination.
    @discardableResult
    static func set(id: UInt32, combo: (code: UInt32, modifiers: UInt32)?, action: @escaping () -> Void) -> Bool {
        if let r = refs[id] { UnregisterEventHotKey(r); refs[id] = nil }
        actions[id] = action
        guard let combo else { return true }
        installHandler()
        var r: EventHotKeyRef?
        let hk = EventHotKeyID(signature: OSType(0x4150_5853), id: id)   // "APXS"
        let ok = RegisterEventHotKey(combo.code, combo.modifiers, hk, GetApplicationEventTarget(), 0, &r) == noErr
        if let r { refs[id] = r }
        return ok
    }

    fileprivate static func fire(_ id: UInt32) { actions[id]?() }

    private static func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.fire(id) } }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

/// A keyboard shortcut that shows or hides the shelf from anywhere
/// (UserDefaults `shelfHotKey`).
@MainActor
final class ShelfHotKey {
    static let shared = ShelfHotKey()
    static let key = "shelfHotKey"
    static let id: UInt32 = 1

    enum Choice: String, CaseIterable, Identifiable {
        case off, optionCommandS, controlOptionSpace, controlOptionCommandS
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: return "None"
            case .optionCommandS: return "⌥⌘S"
            case .controlOptionSpace: return "⌃⌥Space"
            case .controlOptionCommandS: return "⌃⌥⌘S"
            }
        }
        /// Carbon key code and modifiers. Pure: tested.
        var combo: (code: UInt32, modifiers: UInt32)? {
            switch self {
            case .off: return nil
            case .optionCommandS: return (UInt32(kVK_ANSI_S), UInt32(optionKey | cmdKey))
            case .controlOptionSpace: return (UInt32(kVK_Space), UInt32(controlKey | optionKey))
            case .controlOptionCommandS: return (UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey | cmdKey))
            }
        }
    }

    var choice: Choice {
        get { Choice(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.key) }
    }

    /// Registers the chosen shortcut. False if another app already uses it.
    @discardableResult
    func apply() -> Bool {
        HotKeyCenter.set(id: Self.id, combo: choice.combo) { FloatingShelf.shared.toggleFromShortcut() }
    }
}
