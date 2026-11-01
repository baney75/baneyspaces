import Foundation

/// Which apps an agent may start on this Mac. Default deny: only apps verified to start a separate instance
/// that restores nothing of Donovan's, and holds none of his data, are on the list. Everything else
/// (every browser, password managers, Keychain Access, System Settings, mail, messages, notes, calendars, photos,
/// terminals other than the agent's own Ghostty, Office and any app nobody has checked) answers `needs_sandbox`.
public enum AgentAppPolicy {
    /// Started with `-ApplePersistenceIgnoreState YES` as a new instance (`open -n`), so it opens nothing it restored.
    public static let separateInstance: Set<String> = ["com.apple.TextEdit", "com.apple.calculator", "com.apple.Preview"]
    /// Apps that must be started with a document from the handoff folder: with none they would show an Open
    /// panel, and an agent never drives an Open or Save panel (it would browse Donovan's files).
    public static let documentRequired: Set<String> = ["com.apple.TextEdit", "com.apple.Preview"]
    // Finder is not on the list: it runs once per user and shows his folders, and agents use files directly.

    public static func allowed(bundle: String) -> Bool { separateInstance.contains(bundle) }
    public static func needsSeparateInstance(bundle: String) -> Bool { separateInstance.contains(bundle) }

    static let kinds: [(prefixes: [String], why: String)] = [
        (["com.google.Chrome", "org.mozilla.firefox", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "com.apple.Safari", "net.imput.helium", "org.chromium.Chromium", "com.operasoftware.Opera", "com.vivaldi.Vivaldi"],
         "a browser holds Donovan's logins (an agent gets its own browser profile in a later phase)"),
        (["com.1password", "com.agilebits", "com.apple.Passwords", "com.bitwarden", "com.apple.keychainaccess", "org.keepassxc", "com.lastpass"],
         "it holds Donovan's passwords"),
        (["com.apple.systempreferences", "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp", "co.zeit.hyper"],
         "it controls this Mac (settings, a shell)"),
        (["com.apple.Notes", "com.apple.mail", "com.apple.MobileSMS", "com.apple.iCal", "com.apple.Photos", "com.apple.reminders", "com.apple.AddressBook", "com.apple.Music", "com.apple.FaceTime", "com.microsoft."],
         "it holds Donovan's own data and exists once per user"),
    ]

    /// nil when the app may start; else `needs_sandbox`, saying why.
    public static func refusal(app: String, bundle: String) -> HandsError? {
        if allowed(bundle: bundle) { return nil }
        let why = kinds.first { k in k.prefixes.contains { bundle == $0 || bundle.hasPrefix($0.hasSuffix(".") ? $0 : $0 + ".") } }?.why
            ?? "no one has checked that it starts a separate instance that restores nothing of Donovan's"
        return HandsError(.needsSandbox, "\(app): \(why)",
                          suggestion: "Do this work in the sandbox (arrives in a later phase), or ask Donovan to lend \(app) and be away from it while you work. Apps an agent may start today: TextEdit and Preview on a file from the handoff folder, and Calculator. Work with files directly rather than through Finder.",
                          retry: .never)
    }
}

/// `agent open`'s one gate, used by the router and by the deck's raw `open` (which other callers on the socket reach).
public enum AgentOpenGate {
    /// The files to hand over (resolved), or why not.
    public static func check(app: String, bundle: String, targets: [String], handoff: URL) -> Result<[String], HandsError> {
        if let e = AgentAppPolicy.refusal(app: app, bundle: bundle) { return .failure(e) }
        var files: [String] = []
        for t in targets {
            if t.contains("://") {
                return .failure(HandsError(.notSupported, "opening a URL needs an agent browser profile, which arrives in a later phase",
                                           suggestion: "Open a file from the handoff folder instead.", retry: .never))
            }
            guard let r = HandoffPath.resolve(t, in: handoff) else { return .failure(HandoffPath.error(t, folder: handoff)) }
            files.append(r.path)
        }
        if AgentAppPolicy.documentRequired.contains(bundle), files.isEmpty {
            return .failure(HandsError(.badArguments, "\(app) must be started with a file from the handoff folder, or it shows an Open panel",
                                       suggestion: "Put a file in \(handoff.path) and pass its path: `baneyspaces agent open \(app) <file>`.", retry: .safe))
        }
        return .success(files)
    }
}

/// Which files an agent may hand to an app: only ones inside the agent handoff folder.
public enum HandoffPath {
    /// Whether what a window reports as its document (a file URL or a path) is inside the folder.
    public static func contains(document: String, in folder: URL) -> Bool {
        let path = URL(string: document).flatMap { $0.isFileURL ? $0.path : nil } ?? document
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        return url.path.hasPrefix(folder.standardizedFileURL.resolvingSymlinksInPath().path + "/")
    }

    /// The path, resolved through symlinks, when it exists inside `folder`; nil otherwise.
    public static func resolve(_ target: String, in folder: URL) -> URL? {
        let expanded = (target as NSString).expandingTildeInPath
        let base = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : folder.appendingPathComponent(expanded)
        let url = base.standardizedFileURL.resolvingSymlinksInPath()
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        guard url.path.hasPrefix(root + "/"), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    public static func error(_ target: String, folder: URL) -> HandsError {
        HandsError(.badArguments, "\(target) isn't a file in the agent handoff folder",
                   suggestion: "Put the file in \(folder.path) and pass its path. Agents don't open files from anywhere else, and URLs wait for the agent browser profiles.", retry: .safe)
    }

    /// A shot's file name: a plain name, no folder, no dot-dot.
    public static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 120 && !name.contains("/") && !name.contains("\\") && !name.hasPrefix(".") && !name.contains("\0")
    }
}

/// Whether a typed value shows the typing happened: changed from before, and now holds the text.
public enum ValueCheck {
    public static func typed(before: String, after: String, text: String) -> Bool {
        after != before && after.contains(text) && after.count >= text.count
    }
    public static func set(before: String, after: String, expected: String) -> (verified: Bool, changed: Bool) {
        (after == expected, after != before)
    }
}

/// When the user last used each app, so a lent app he is using is left alone.
public struct UserUse: Equatable, Sendable {
    public static let quiet: TimeInterval = 30
    private var leftAt: [Int32: Date] = [:]
    private var front: Int32?

    public init() {}

    /// `pid` came to the front (the app before it just left).
    /// `byAgent`: an agent's action or launch brought it forward. The app before it still counts as just left, but the
    /// agent's app is not one he chose.
    public mutating func activated(_ pid: Int32, now: Date, byAgent: Bool = false) {
        if let old = front, old != pid { leftAt[old] = now }
        front = byAgent ? nil : pid
        if !byAgent { leftAt[pid] = nil }
    }

    /// Whether `pid` is in front (`frontNow`, read from the system), or was within the last 30 s.
    public func inUse(_ pid: Int32, frontNow: Int32?, now: Date) -> Bool {
        if frontNow == pid { return true }
        if let t = leftAt[pid] { return now.timeIntervalSince(t) < Self.quiet }
        return false
    }
}

/// What a refmap file says about a ref's target. The engine writes refmaps as files the agent could edit, so
/// identity is read when the snapshot is taken and compared again before each use; a ref that now points at
/// another process or window is refused.
public struct RefIdentity: Equatable, Sendable {
    public var pid: Int
    public var window: String
    public var instance: String
}

public enum RefmapIdentity {
    /// `@e5` -> identity, from a `refmap.json`'s bytes. Nil when it isn't the expected shape.
    public static func table(from data: Data) -> [String: RefIdentity]? {
        guard let root = JSONValue.parse(data), let inner = root["inner"]?.object else { return nil }
        var out: [String: RefIdentity] = [:]
        for (key, e) in inner {
            guard let pid = e["pid"]?.int, let window = e["source_window_id"]?.string else { return nil }
            out[key] = RefIdentity(pid: pid, window: window, instance: e["process_instance"]?.string ?? "")
        }
        return out
    }

    /// The `@eN` key of `@s8f3k2p9:e5`.
    public static func key(forRef ref: String) -> String? {
        guard let colon = ref.firstIndex(of: ":") else { return nil }
        return "@" + ref[ref.index(after: colon)...]
    }

    /// Whether the ref still means what it meant when it was sealed.
    public static func intact(sealed: [String: RefIdentity], current: Data, ref: String) -> Bool {
        guard let k = key(forRef: ref), let was = sealed[k], let now = table(from: current)?[k] else { return false }
        return was == now
    }

    /// Whether every ref of the snapshot targets this window and process (checked once, when it is taken).
    public static func allTarget(_ t: [String: RefIdentity], window: UInt32, pid: Int32) -> Bool {
        t.values.allSatisfy { $0.window == "w-\(window)" && $0.pid == Int(pid) }
    }
}

/// Whether an event is the user's: from the hardware, not posted by a program. A click on a consent sheet counts
/// only if it is. Synthetic events carry their sender's pid or a private/combined source; hardware ones have pid 0
/// and the HID system state. An accessibility press carries no recent event at all.
public enum UserEventSource {
    public static let hidSystemState: Int64 = 1
    public static func isGenuine(sourcePID: Int64, sourceState: Int64, age: TimeInterval) -> Bool {
        sourcePID == 0 && sourceState == hidSystemState && age >= 0 && age < 2
    }
}

/// What the deck socket refuses outright. Any process of this user can write to it, so the socket is not a place
/// where Donovan's decisions can be made: lending and returning an app, and any grant of access, happen only
/// through a consent sheet the app shows and a real click on it.
public enum SocketPolicy {
    public static let humanOnly: Set<String> = ["lend", "return", "grant"]

    public static func refusal(for r: Wire.Request) -> String? {
        // The cursor is how Donovan sees agent activity: an agent may pick its look, but only he switches it off (Settings).
        if r.op == .agent, r.text?.lowercased() == "cursor", r.args?.first?.lowercased() == "off" {
            return "turning the agent cursor off is Donovan's to do, in BaneySpaces Settings; agents may change its theme: `baneyspaces agent cursor theme <name>`"
        }
        guard r.op == .agent, let text = r.text?.lowercased(), humanOnly.contains(text) else { return nil }
        return "\(text) is Donovan's to do: `baneyspaces agent lend <app>` asks him in a sheet in BaneySpaces; nothing sent on this socket lends an app"
    }

    /// An agent caller may move a window to the agent workspace only if its process was started for an agent.
    public static func mayMove(windowPid: Int32?, startedForAgents: Set<Int32>) -> Bool {
        guard let pid = windowPid else { return false }
        return startedForAgents.contains(pid)
    }
}

/// What the engine may be asked a second time. Only a failure the engine itself reports as "nothing was delivered"
/// (retry safe) is ever repeated, and only while the caller is still waiting and the scope still holds. A timeout or
/// an unresponsive app after dispatch is unsafe or unknown: it goes back to the caller as `timeout`, `retry: never`.
public enum EngineRetry {
    public static func mayRepeat(_ e: HandsError) -> Bool { e.code == .timeout && e.retry == .safe }

    /// Runs `attempt` until it succeeds or fails for good. Between attempts the caller's wait and the scope are
    /// checked, so nothing is dispatched for a caller that left or into a window that is out of scope.
    public static func run<T>(attempt: () -> Result<T, HandsError>, stop: () -> HandsError?, cancelled: () -> Bool,
                              giveUp: Date, now: () -> Date = Date.init, pause: () -> Void) -> Result<T, HandsError> {
        while true {
            let r = attempt()
            guard case .failure(let e) = r, mayRepeat(e), now() < giveUp, !cancelled() else { return r }
            pause()
            if cancelled() { return r }
            if let s = stop() { return .failure(s) }
        }
    }
}

/// A window as the accessibility tree shows it, as much of it as the panel check needs.
public struct AXNodeInfo: Equatable, Sendable {
    public var role: String?, subrole: String?, identifier: String?, title: String?
    public var children: [AXNodeInfo]
    public init(role: String? = nil, subrole: String? = nil, identifier: String? = nil, title: String? = nil, children: [AXNodeInfo] = []) {
        self.role = role; self.subrole = subrole; self.identifier = identifier; self.title = title; self.children = children
    }
}

/// Windows an agent never works in: the Open and Save panels of the apps it starts. They browse Donovan's files.
public enum PanelDetector {
    /// Whether the window is such a panel, or has one (or any sheet) attached: a sheet is a child of its document
    /// window, so the window is refused for every snapshot, action and ref while one is up.
    public static func windowIsOffLimits(_ w: AXNodeInfo) -> Bool {
        if isOpenOrSavePanel(identifier: w.identifier, subrole: w.subrole, title: w.title) { return true }
        func sheetOrPanel(_ n: AXNodeInfo, depth: Int) -> Bool {
            if n.role == "AXSheet" || n.subrole == "AXSheet" { return true }
            if isOpenOrSavePanel(identifier: n.identifier, subrole: n.subrole, title: n.title) { return true }
            return depth < 3 && n.children.contains { sheetOrPanel($0, depth: depth + 1) }
        }
        return w.children.contains { sheetOrPanel($0, depth: 1) }
    }

    public static func isOpenOrSavePanel(identifier: String?, subrole: String?, title: String?) -> Bool {
        let id = (identifier ?? "").lowercased()
        if id.contains("open-panel") || id.contains("save-panel") || id.contains("openpanel") || id.contains("savepanel") { return true }
        let t = (title ?? "").lowercased()
        return (subrole == "AXDialog" || subrole == "AXSystemDialog") && ["open", "save", "save as", "export", "import", "choose"].contains(t)
    }
}

/// Processes started for an agent, each with its start time, so a process id that macOS reuses for one of Donovan's
/// apps is never taken for the agent's.
public struct AgentOwnedSet: Equatable, Sendable {
    private var started: [Int32: Double] = [:]
    public init() {}
    public mutating func add(_ pid: Int32, startedAt: Double) { started[pid] = startedAt }
    public mutating func remove(_ pid: Int32) { started[pid] = nil }
    /// True only for the same process: same pid and the same start time.
    public func contains(_ pid: Int32, startedAt: Double?) -> Bool {
        guard let was = started[pid], let now = startedAt else { return false }
        return abs(was - now) < 0.5
    }
    public var pids: Set<Int32> { Set(started.keys) }
}

/// Whether a click or key may answer the consent sheet: the right kind of event, after the button was enabled,
/// on the button.
public enum ConsentClick {
    public enum Kind: Sendable { case mouseDown, mouseUp, keyDown, other }
    public static func valid(kind: Kind, eventTime: Double, buttonEnabledAt: Double, insideButton: Bool, keyIsActivation: Bool) -> Bool {
        guard eventTime >= buttonEnabledAt else { return false }
        switch kind {
        case .mouseUp, .mouseDown: return insideButton
        case .keyDown: return keyIsActivation
        case .other: return false
        }
    }
}
