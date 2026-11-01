import AppKit
import BaneySpacesCore

/// The only way an app gets lent: a sheet in BaneySpaces that Donovan answers with a real click. The deck socket
/// is open to every process of his, so a request there can ask for a lend but never make one; this sheet is
/// where it is decided. "Don't Lend" is the default button (Return and Esc), and a click on "Lend" counts only
/// if the event is from the hardware: an event posted by a program, or an accessibility press with no recent
/// event, is refused.
enum LendConsent {
    private static var showing = false
    private static var lastShown = Date.distantPast
    static let pause: TimeInterval = 15
    static let giveUp: TimeInterval = 60

    /// Must run on the main thread. False for "Don't Lend", a timeout, a second sheet while one is up or
    /// within `pause` of the last, and any answer that did not come from a real click or key.
    static func ask(app: String, minutes: Int, takeBack: Bool) -> Bool {
        guard Thread.isMainThread, !showing, Date().timeIntervalSince(lastShown) >= pause else { return false }
        showing = true
        defer { showing = false; lastShown = Date() }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if takeBack {
            alert.messageText = "Take back \(app) from agents?"
            alert.informativeText = "Agents will no longer be able to read or act on its windows."
        } else {
            alert.messageText = "Let agents use \(app)?"
            alert.informativeText = "A program on this Mac asked. If you didn't start it, choose Don't Lend. Agents could read and act on \(app)'s windows as they are now for \(minutes) minutes, but never while you are using it."
        }
        alert.addButton(withTitle: "Don't Lend")                // first button: the default (Return, Esc)
        alert.addButton(withTitle: takeBack ? "Take Back" : "Lend")
        var timedOut = false
        let timer = Timer(timeInterval: giveUp, repeats: false) { _ in timedOut = true; NSApp.abortModal() }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        let response = alert.runModal()
        guard response == .alertSecondButtonReturn, !timedOut else { return false }
        // The click (or key) that ended the sheet: hardware only, and fresh.
        guard let event = NSApp.currentEvent, let cg = event.cgEvent,
              UserEventSource.isGenuine(sourcePID: cg.getIntegerValueField(.eventSourceUnixProcessID),
                                        sourceState: cg.getIntegerValueField(.eventSourceStateID),
                                        age: ProcessInfo.processInfo.systemUptime - event.timestamp) else {
            Trace.log("lend refused: the answer did not come from a real click")
            return false
        }
        return true
    }
}
