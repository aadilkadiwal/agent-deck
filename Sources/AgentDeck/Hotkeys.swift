import Carbon.HIToolbox
import Foundation

/// Registered only while a permission prompt is waiting, so other apps keep ⌃⌥A / ⌃⌥D otherwise.
@MainActor
final class Hotkeys {
    var onKey: ((_ allow: Bool) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x41_44_63_6B   // "ADck"

    func setEnabled(_ on: Bool) {
        guard on == refs.isEmpty else { return }
        if !on {
            refs.forEach { UnregisterEventHotKey($0) }
            refs = []
            return
        }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, ctx in
                var key = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
                guard let ctx, key.signature == Hotkeys.signature else { return OSStatus(eventNotHandledErr) }
                let me = Unmanaged<Hotkeys>.fromOpaque(ctx).takeUnretainedValue()
                let allow = key.id == 1
                Task { @MainActor in me.onKey?(allow) }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        for (id, code) in [(UInt32(1), kVK_ANSI_A), (2, kVK_ANSI_D)] {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(code), UInt32(controlKey | optionKey), EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) }
        }
    }
}
