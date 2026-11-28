import AppKit
import Carbon.HIToolbox

/// The one key that works outside Agent Deck: opening the menu. Off until the user records one.
@MainActor
final class Hotkeys {
    var onMenu: (() -> Void)?
    private var menuRef: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x41_44_63_6B   // "ADck"

    func setMenuKey(_ key: MenuHotkey?) -> Bool {
        if let menuRef { UnregisterEventHotKey(menuRef) }
        menuRef = nil
        guard let key else { return true }
        installHandler()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, EventHotKeyID(signature: Self.signature, id: 1),
                                         GetApplicationEventTarget(), 0, &ref)
        menuRef = status == noErr ? ref : nil
        return status == noErr
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, ctx in
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard let ctx, key.signature == Hotkeys.signature else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<Hotkeys>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in me.onMenu?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}

/// A recorded shortcut, stored as "keyCode,carbonModifiers,title".
struct MenuHotkey: Equatable {
    static let key = "menuHotkey"
    let keyCode: UInt32
    let modifiers: UInt32
    let title: String

    init(keyCode: UInt32, modifiers: UInt32, title: String) { self.keyCode = keyCode; self.modifiers = modifiers; self.title = title }

    init?(stored: String) {
        // Before shortcuts could be recorded, Settings offered three fixed ones.
        let legacy = ["ctrlOptO": "\(kVK_ANSI_O),\(controlKey | optionKey),⌃⌥O",
                      "ctrlOptSpace": "\(kVK_Space),\(controlKey | optionKey),⌃⌥Space",
                      "ctrlOptCmdA": "\(kVK_ANSI_A),\(controlKey | optionKey | cmdKey),⌃⌥⌘A"]
        let parts = (legacy[stored] ?? stored).split(separator: ",", maxSplits: 2).map(String.init)
        guard parts.count == 3, let code = UInt32(parts[0]), let mods = UInt32(parts[1]) else { return nil }
        self.init(keyCode: code, modifiers: mods, title: parts[2])
    }

    var stored: String { "\(keyCode),\(modifiers),\(title)" }

    static var current: MenuHotkey? { MenuHotkey(stored: UserDefaults.standard.string(forKey: key) ?? "") }

    /// nil for a key press that can't be a shortcut. It needs ⌃ or ⌥, or ⌘ with ⇧,
    /// so a plain ⌘ letter never takes Copy or Save away from every other app.
    init?(event: NSEvent) {
        let f = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard f.contains(.control) || f.contains(.option) || f.isSuperset(of: [.command, .shift]) else { return nil }
        let names: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
                                    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                                    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        let code = Int(event.keyCode)
        guard let key = names[code] ?? event.characters(byApplyingModifiers: [])?.uppercased(), !key.isEmpty, code != kVK_Escape else { return nil }
        var mods = 0, symbols = ""
        if f.contains(.control) { mods |= controlKey; symbols += "⌃" }
        if f.contains(.option) { mods |= optionKey; symbols += "⌥" }
        if f.contains(.shift) { mods |= shiftKey; symbols += "⇧" }
        if f.contains(.command) { mods |= cmdKey; symbols += "⌘" }
        self.init(keyCode: UInt32(code), modifiers: UInt32(mods), title: symbols + key)
    }

    /// True when macOS itself has this combination (Spotlight, input sources, Mission Control…).
    var takenBySystem: Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let list = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        return list.contains {
            ($0[kHISymbolicHotKeyEnabled] as? Bool ?? false)
                && ($0[kHISymbolicHotKeyCode] as? Int).map(UInt32.init) == keyCode
                && ($0[kHISymbolicHotKeyModifiers] as? Int).map { UInt32($0) & UInt32(controlKey | optionKey | shiftKey | cmdKey) } == modifiers
        }
    }
}
