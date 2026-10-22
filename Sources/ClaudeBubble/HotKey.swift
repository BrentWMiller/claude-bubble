import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// A system-wide shortcut held down and let go (push to talk), wherever the focus is. A Carbon hot key: it hears both
/// the press and the release, and needs no Accessibility permission.
final class HotKey {
    /// Pressed and released (main thread). A held key's repeats aren't passed on.
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var down = false

    init() {
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
    }

    deinit {
        unregister()
        if let handler { RemoveEventHandler(handler) }
    }

    /// Listens for `shortcut` (nil: for nothing), in place of whatever it listened for before.
    func register(_ shortcut: TalkShortcut?) {
        unregister()
        guard let shortcut else { return }
        let id = EventHotKeyID(signature: OSType(0x4342_544B), id: 1)   // "CBTK"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        // Another app may already own the shortcut; then it just doesn't fire.
        NSLog("ClaudeBubble: talk shortcut %@ %@", shortcut.label, status == noErr ? "registered" : "not registered (\(status))")
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        if down { handle(pressed: false) }   // let go of a talk the shortcut was holding
    }

    private func handle(pressed: Bool) {
        guard pressed != down else { return }
        down = pressed
        if pressed { onDown?() } else { onUp?() }
    }
}

/// The talk shortcut: a key and its modifiers (Carbon's flags), and how it reads (⌃⌥Space).
struct TalkShortcut: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String

    /// ⌃⌥Space (⌥Space alone is often a launcher's).
    static let standard = TalkShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥Space")

    /// A key pressed with at least ⌘, ⌃ or ⌥ (Shift alone would take a letter from typing); nil otherwise.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        var mods: UInt32 = 0, label = ""
        if flags.contains(.control) { mods |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { mods |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { mods |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { mods |= UInt32(cmdKey); label += "⌘" }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods, label: label + Self.keyName(event))
    }

    init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Delete: "⌫"
        case kVK_Escape: "⎋"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        default:
            if let f = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
                .firstIndex(of: Int(event.keyCode)) { "F\(f + 1)" } else {
                (event.charactersIgnoringModifiers ?? "?").uppercased()
            }
        }
    }
}

/// The talk shortcut you chose (kept across restarts), and whether it's being recorded (it doesn't fire meanwhile).
final class TalkShortcutModel: ObservableObject {
    static let shared = TalkShortcutModel()
    private static let key = "talkShortcut"

    @Published var shortcut: TalkShortcut {
        didSet { (try? JSONEncoder().encode(shortcut)).map { UserDefaults.standard.set($0, forKey: Self.key) } }
    }
    @Published var recording = false

    private init() {
        shortcut = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(TalkShortcut.self, from: $0) }
            ?? .standard
    }
}

/// The settings row's recorder: shows the shortcut; click it, then press the new one (Esc keeps the old).
struct TalkShortcutRecorder: View {
    @ObservedObject private var model = TalkShortcutModel.shared
    @State private var monitor: Any?

    var body: some View {
        Button {
            model.recording ? stop() : start()
        } label: {
            Text(model.recording ? "Press keys…" : model.shortcut.label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.white.opacity(model.recording ? 0.6 : 0.9))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(model.recording ? 0.14 : 0.08)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(model.recording ? 0.3 : 0), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(model.recording ? "Press the new shortcut, or Esc to keep this one" : "Click to change")
        .onDisappear { stop() }
    }

    private func start() {
        model.recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
            } else if let shortcut = TalkShortcut(event: event) {
                model.shortcut = shortcut
                stop()
            } else {
                NSSound.beep()   // needs ⌘, ⌃ or ⌥
            }
            return nil   // the panel doesn't see what was pressed (⌘Q isn't quit while recording)
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if model.recording { model.recording = false }
    }
}
