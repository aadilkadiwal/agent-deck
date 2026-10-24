import Carbon.HIToolbox
import Foundation

/// Registered only while a permission prompt is waiting, so other apps keep ⌃⌥A / ⌃⌥D otherwise.
@MainActor
final class Hotkeys {
    var onKey: ((_ allow: Bool) -> Void)?
    var onMenu: (() -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var menuRef: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x41_44_63_6B   // "ADck"
    private static let menuId: UInt32 = 3

    func setEnabled(_ on: Bool) {
        guard on == refs.isEmpty else { return }
        if !on {
            refs.forEach { UnregisterEventHotKey($0) }
            refs = []
            return
        }
        installHandler()
        for (id, code) in [(UInt32(1), kVK_ANSI_A), (2, kVK_ANSI_D)] {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(code), UInt32(controlKey | optionKey), EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) }
        }
    }

    func setMenuKey(_ key: MenuHotkey) -> Bool {
        if let menuRef { UnregisterEventHotKey(menuRef) }
        menuRef = nil
        guard let code = key.keyCode else { return true }
        installHandler()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(code, key.modifiers, EventHotKeyID(signature: Self.signature, id: Self.menuId),
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
            let id = key.id
            Task { @MainActor in
                if id == Hotkeys.menuId { me.onMenu?() } else { me.onKey?(id == 1) }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}

// Off until turned on (Settings or the welcome card). ⌃⌥O is the suggestion: ⌃⌥Space switches input sources in macOS.
enum MenuHotkey: String, CaseIterable, Identifiable {
    case off, ctrlOptO, ctrlOptSpace, ctrlOptCmdA
    static let key = "menuHotkey"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .ctrlOptO: "⌃⌥O"
        case .ctrlOptSpace: "⌃⌥Space"
        case .ctrlOptCmdA: "⌃⌥⌘A"
        }
    }

    var keyCode: UInt32? {
        switch self {
        case .off: nil
        case .ctrlOptO: UInt32(kVK_ANSI_O)
        case .ctrlOptSpace: UInt32(kVK_Space)
        case .ctrlOptCmdA: UInt32(kVK_ANSI_A)
        }
    }

    var modifiers: UInt32 { UInt32(controlKey | optionKey | (self == .ctrlOptCmdA ? cmdKey : 0)) }

    static var current: MenuHotkey { MenuHotkey(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .off }
}
