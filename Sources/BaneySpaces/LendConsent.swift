import AppKit
import BaneySpacesCore

/// The only way an app gets lent: a sheet in BaneySpaces that Donovan answers with a real click. The session socket
/// is open to every process of his, so a request there can ask for a lend but never make one; this sheet is
/// where it is decided. "Don't Lend" is the default button; "Lend" stays disabled for the first second, so a
/// click meant for what was under the pointer can't land on it; and it counts only if the event is a click on
/// the button (or Space/Return on it) made after it was enabled, from the hardware: an event posted by a program,
/// or an accessibility press with only some older event lying around, is refused. Asking is slowed down by
/// every refusal, and stops for an app after three.
enum LendConsent {
    private static var showing = false
    private static var lastShown = Date.distantPast
    private static var pause: TimeInterval = 15
    private static var refusals: [String: (count: Int, last: Date)] = [:]
    static let giveUp: TimeInterval = 60
    static let enableAfter: TimeInterval = 1
    static let maxRefusals = 3

    /// Must run on the main thread. False for "Don't Lend", a timeout, a second sheet while one is up or
    /// within the pause of the last, and any answer that did not come from a real click or key.
    static func ask(app: String, minutes: Int, takeBack: Bool) -> Bool {
        // Taking back narrows access: it is never throttled, counted, or stopped.
        guard Thread.isMainThread, !showing, takeBack || Date().timeIntervalSince(lastShown) >= pause else { return false }
        if !takeBack, let r = refusals[app], r.count >= maxRefusals, Date().timeIntervalSince(r.last) < 3600 { return false }
        showing = true
        defer { showing = false; if !takeBack { lastShown = Date() } }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if takeBack {
            alert.messageText = "Take back \(app) from agents?"
            alert.informativeText = "Agents will no longer be able to read or act on its windows."
        } else {
            alert.messageText = "Let agents use \(app)?"
            alert.informativeText = "A program on this Mac asked. If you didn't start it, choose Don't Lend. Agents could read and act on \(app)'s windows as they are now for \(minutes) minutes, but never while you are using it."
        }
        alert.addButton(withTitle: takeBack ? "Keep Lent" : "Don't Lend")   // first button: the default (Return)
        alert.addButton(withTitle: takeBack ? "Take Back" : "Lend")
        let button = alert.buttons[1]
        button.isEnabled = false
        let enabledAt = ProcessInfo.processInfo.systemUptime + enableAfter
        let enable = Timer(timeInterval: enableAfter, repeats: false) { _ in button.isEnabled = true }
        RunLoop.main.add(enable, forMode: .common)
        var timedOut = false
        let timer = Timer(timeInterval: giveUp, repeats: false) { _ in timedOut = true; NSApp.abortModal() }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate(); enable.invalidate() }
        let response = alert.runModal()
        func refuse(_ why: String) -> Bool {
            if takeBack { return false }
            let r = refusals[app] ?? (0, .distantPast)
            refusals[app] = (r.count + 1, Date())
            pause = min(pause * 2, 600)
            Trace.log("lend refused: \(why)")
            return false
        }
        guard response == .alertSecondButtonReturn, !timedOut else { return refuse("not confirmed") }
        // The click (or key) that ended the sheet: the right kind, on the button, after it was enabled, hardware only.
        guard let event = NSApp.currentEvent, let cg = event.cgEvent,
              UserEventSource.isGenuine(sourcePID: cg.getIntegerValueField(.eventSourceUnixProcessID),
                                        sourceState: cg.getIntegerValueField(.eventSourceStateID),
                                        age: ProcessInfo.processInfo.systemUptime - event.timestamp) else {
            return refuse("the answer did not come from a real click")
        }
        let kind: ConsentClick.Kind
        switch event.type {
        case .leftMouseDown: kind = .mouseDown
        case .leftMouseUp: kind = .mouseUp
        case .keyDown: kind = .keyDown
        default: kind = .other
        }
        let inside: Bool = {
            guard event.window === alert.window else { return false }
            return button.convert(button.bounds, to: nil).contains(event.locationInWindow)
        }()
        let activation = event.type == .keyDown && [" ", "\r"].contains(event.charactersIgnoringModifiers ?? "") && alert.window.firstResponder === button
        guard ConsentClick.valid(kind: kind, eventTime: event.timestamp, buttonEnabledAt: enabledAt, insideButton: inside, keyIsActivation: activation) else {
            return refuse("the answer was not a click on the button")
        }
        refusals[app] = nil
        pause = 15
        return true
    }
}
