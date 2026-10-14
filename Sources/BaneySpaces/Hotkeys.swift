import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts through RegisterEventHotKey. A registered shortcut never reaches the
/// front app. Like every global shortcut on macOS, it stops while an app holds Secure Input.
final class Hotkeys {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private static var shared: Hotkeys?

    static let digitKeyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    init() {
        Hotkeys.shared = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            // The Deck registers its own shortcuts under other signatures; those aren't ours.
            guard id.signature == OSType(0x42414E59) else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { Hotkeys.shared?.actions[id.id]?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    func removeAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    /// Returns false if macOS refused the shortcut.
    @discardableResult
    func register(keyCode: Int, modifiers: Int, _ action: @escaping () -> Void) -> Bool {
        let id = UInt32(actions.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers),
                                         EventHotKeyID(signature: OSType(0x42414E59), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("BaneySpaces: macOS refused shortcut %d (status %d)", keyCode, status)
            return false
        }
        refs.append(ref)
        actions[id] = action
        return true
    }
}
