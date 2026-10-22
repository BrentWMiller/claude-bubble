import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut held down and let go (push to talk), wherever the focus is. A Carbon hot key: it hears both
/// the press and the release, and needs no Accessibility permission.
final class HotKey {
    /// Pressed and released (main thread). A held key's repeats aren't passed on.
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var down = false

    /// Talk to a session: ⌃⌥Space (⌥Space alone is often a launcher's).
    static let talk = (keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥Space")

    init(keyCode: UInt32, modifiers: UInt32) {
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            let key = Unmanaged<HotKey>.fromOpaque(data).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async { key.handle(pressed: pressed) }
            return noErr
        }, types.count, &types, me, &handler)
        let id = EventHotKeyID(signature: OSType(0x4342_544B), id: 1)   // "CBTK"
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        // Another app may already own the shortcut; then it just doesn't fire.
        NSLog("ClaudeBubble: talk shortcut %@", status == noErr ? "registered" : "not registered (\(status))")
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    private func handle(pressed: Bool) {
        guard pressed != down else { return }
        down = pressed
        if pressed { onDown?() } else { onUp?() }
    }
}
