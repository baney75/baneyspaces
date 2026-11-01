import AppKit
import BaneySpacesCore
import Security

/// Records every app the workspace activates, for as long as it lives. An action holds one from planning to the end
/// of its verification: an activation of the target or of any other app in that span is a focus-guard failure, however
/// briefly it lasted and whenever it was noticed.
final class ActivationWatch {
    private let lock = NSLock()
    private var pids: [Int32] = []
    private var token: NSObjectProtocol?

    init() {
        token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.lock.lock(); self?.pids.append(app.processIdentifier); self?.lock.unlock()
        }
    }

    deinit { stop() }

    func stop() {
        if let t = token { NSWorkspace.shared.notificationCenter.removeObserver(t); token = nil }
    }

    var activated: [Int32] { lock.lock(); defer { lock.unlock() }; return pids }
}

/// A listen-only tap on the session's keyboard, mouse and scroll events for the length of one action: what it sees
/// tells Donovan's hand (source process 0) from anything else, and shows whether one of our own events reached the
/// session. `stop()` answers nil when no tap could be made (Input Monitoring not granted); the pointer check then
/// fails only on a landing where we posted.
final class SessionTap {
    private let lock = NSLock()
    private var seen: [SessionEvent] = []
    private var port: CFMachPort?
    private var loop: CFRunLoop?
    private(set) var available = false

    init() {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                    .otherMouseDown, .otherMouseUp, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let info = Unmanaged.passUnretained(self).toOpaque()
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
                                              callback: { _, _, event, info in
                                                  if let info { Unmanaged<SessionTap>.fromOpaque(info).takeUnretainedValue().record(Int64(event.getIntegerValueField(.eventSourceUnixProcessID))) }
                                                  return Unmanaged.passUnretained(event)
                                              }, userInfo: info) else { ready.signal(); return }
            port = tap
            loop = CFRunLoopGetCurrent()
            available = true
            CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.start()
        ready.wait()
    }

    fileprivate func record(_ pid: Int64) { lock.lock(); seen.append(SessionEvent(sourcePid: pid)); lock.unlock() }

    func stop() -> [SessionEvent]? {
        guard available else { return nil }
        if let loop { CFRunLoopStop(loop) }
        if let port { CFMachPortInvalidate(port) }
        lock.lock(); defer { lock.unlock() }
        return seen
    }
}

/// Whether a probe app (BaneySpaces' own canvas test app) is the one built into this app: inside Resources/probe,
/// its signature valid, signed by the same team as BaneySpaces when it has one, and its code hash the one recorded
/// when the bundle was built (the recording is inside the app's own signed seal). Anything else is refused.
enum ProbeAppTrust {
    static var folder: URL? { Bundle.main.resourceURL?.appendingPathComponent("probe", isDirectory: true) }

    static func trusted(_ appURL: URL) -> Bool {
        guard let folder, AgentAppPolicy.isProbeApp(bundle: AgentAppPolicy.canvasProbeBundle, at: appURL, in: folder, trusted: true) else { return false }
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me, SecCodeCheckValidity(me, [], nil) == errSecSuccess else { return false }
        var mine: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine else { return false }
        var theirs: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &theirs) == errSecSuccess, let theirs,
              SecStaticCodeCheckValidityWithErrors(theirs, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), nil, nil) == errSecSuccess else { return false }
        func info(_ c: SecStaticCode) -> [String: Any]? {
            var out: CFDictionary?
            guard SecCodeCopySigningInformation(c, SecCSFlags(rawValue: kSecCSSigningInformation), &out) == errSecSuccess else { return nil }
            return out as? [String: Any]
        }
        guard let a = info(mine), let b = info(theirs) else { return false }
        // The same team when BaneySpaces has one.
        if let team = a[kSecCodeInfoTeamIdentifier as String] as? String, (b[kSecCodeInfoTeamIdentifier as String] as? String) != team { return false }
        // The code hash recorded at build time, in the app's own sealed Resources.
        guard let unique = b[kSecCodeInfoUnique as String] as? Data,
              let recorded = try? String(contentsOf: folder.appendingPathComponent("CanvasProbe.cdhash"), encoding: .utf8) else { return false }
        return unique.map { String(format: "%02x", $0) }.joined() == recorded.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
