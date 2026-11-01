import AppKit
import Carbon.HIToolbox

/// Shortcuts through RegisterEventHotKey, held only while they apply (`activate`/`deactivate`).
/// A registered shortcut never reaches the front app, so holding ⌘⇧C everywhere would take it from
/// browsers (Inspect Element). Needs no Accessibility permission.
///
/// Each instance has its own signature and handler, and passes on presses that aren't its own, so
/// several sets (Ghostty's keys, the drawer's Esc) can coexist.
final class ScopedHotkeys {
    struct Binding { let keyCode: Int; let modifiers: Int; let action: () -> Void }

    private let signature: OSType
    private var bindings: [Binding] = []
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    init(signature: String) {
        self.signature = signature.utf8.reduce(0) { $0 << 8 | OSType($1) }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<ScopedHotkeys>.fromOpaque(userData).takeUnretainedValue()
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == me.signature, Int(id.id) < me.bindings.count else { return OSStatus(eventNotHandledErr) }
            let action = me.bindings[Int(id.id)].action
            DispatchQueue.main.async { action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func add(keyCode: Int, modifiers: Int, _ action: @escaping () -> Void) {
        bindings.append(Binding(keyCode: keyCode, modifiers: modifiers, action: action))
    }

    var isActive: Bool { !refs.isEmpty }

    func activate() {
        guard refs.isEmpty else { return }
        for (i, b) in bindings.enumerated() {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(b.keyCode), UInt32(b.modifiers),
                                             EventHotKeyID(signature: signature, id: UInt32(i)),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { NSLog("BaneySpaces session: shortcut %d refused (%d)", b.keyCode, status) }
        }
    }

    func deactivate() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }
}
