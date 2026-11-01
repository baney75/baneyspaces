import BaneySpacesCore
import CAgentDesktop
import Foundation

/// The hands engine: agent-desktop's C library, linked into this app. It reads a window's
/// accessibility tree into snapshot-qualified refs and acts on a ref with strict re-identification.
///
/// Rules this file keeps (HandsSourceTests reads this source and fails if one breaks):
///  - Every action goes through `ad_execute_by_ref_timeout` with the Headless policy. The Headed and
///    FocusFallback policies, which let the engine move the pointer or raise the app, are never named.
///  - Nothing here calls an engine function that focuses, raises, launches, closes or moves a
///    window, posts a mouse event, or sends a key to no particular app.
///  - No activate, SetFrontProcess or global CGEventPost, in this file or its neighbors.
/// Calls run one at a time on `queue`: the engine's element handles belong to the thread that made them.
final class HandsEngine {
    static let shared = HandsEngine()
    private let queue = DispatchQueue(label: "baneyspaces.hands.engine")
    private var adapter: OpaquePointer?
    /// A second adapter, with a session of its own, for the snapshots taken as evidence: the engine
    /// keeps only so many saved snapshots per store, and evidence must never push out the refs an
    /// agent is holding.
    private var evidenceAdapter: OpaquePointer?
    private var failure: HandsError?

    /// AD_POLICY_KIND_HEADLESS: keep each action's built-in behavior, no cursor, no focus.
    static let headlessPolicy: Int32 = 0
    // AdResult values from agent_desktop.h (the type itself is ambiguous in Swift).
    static let surfaceWindow: Int32 = 0 // AD_SNAPSHOT_SURFACE_WINDOW
    static let resultOK: Int32 = 0
    static let resultPermDenied: Int32 = -1
    // AdActionKind values from agent_desktop.h.
    enum Kind: Int32 { case click = 0, setValue = 4, select = 8, toggle = 9, scroll = 12, pressKey = 14, typeText = 17 }

    /// Where the engine keeps its refs: BaneySpaces' own folder, readable by this user only.
    static var home: URL { Wire.supportDir.appendingPathComponent("hands", isDirectory: true) }

    /// What a call to the engine returned: its JSON envelope, or why there is none.
    enum Reply {
        case ok(JSONValue)
        case failed(HandsError)
    }

    private func ready() -> HandsError? {
        if adapter != nil { return nil }
        if let failure { return failure }
        try? FileManager.default.createDirectory(at: Self.home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        setenv("AGENT_DESKTOP_HOME", Self.home.path, 1)
        guard ad_init(UInt32(AD_ABI_VERSION_MAJOR)) == Self.resultOK else {
            failure = HandsError(.engineError, "the hands engine library doesn't match this build", suggestion: "Reinstall BaneySpaces (make install).", retry: .never)
            return failure
        }
        guard let a = ad_adapter_create() else {
            failure = HandsError(.engineError, "the hands engine didn't start: \(lastError().message)", suggestion: "Check `baneyspaces doctor`.", retry: .never)
            return failure
        }
        adapter = a
        evidenceAdapter = "evidence".withCString { ad_adapter_create_with_session($0) } ?? a
        return nil
    }

    private func lastError() -> (message: String, suggestion: String) {
        (ad_last_error_message().map { String(cString: $0) } ?? "", ad_last_error_suggestion().map { String(cString: $0) } ?? "")
    }

    /// Reads and frees the engine's output string, then turns its envelope into a reply.
    private func finish(_ code: Int32, _ out: UnsafeMutablePointer<CChar>?) -> Reply {
        var json: JSONValue?
        if let out {
            json = JSONValue.parse(String(cString: out))
            ad_free_string(out)
        }
        if let json, json["ok"]?.bool == true { return .ok(json["data"] ?? .object([:])) }
        if let err = json?["error"] { return .failed(Self.translate(err)) }
        let e = lastError()
        if code == Self.resultPermDenied || e.message.lowercased().contains("permission") {
            return .failed(HandsError(.permissionDenied, "Accessibility isn't allowed for BaneySpaces",
                                      suggestion: "Allow BaneySpaces in System Settings > Privacy & Security > Accessibility.", retry: .safe))
        }
        return .failed(HandsError(.engineError, e.message.isEmpty ? "the engine failed (\(code))" : e.message,
                                  suggestion: e.suggestion.isEmpty ? "Take a new snapshot and try again." : e.suggestion, retry: .never))
    }

    /// An engine error object as one of ours. Its own retry verdict decides `retry`; a ref that needs
    /// a new snapshot says so.
    static func translate(_ err: JSONValue) -> HandsError {
        let code = err["code"]?.string ?? ""
        let message = err["message"]?.string ?? "the engine refused"
        let suggestion = err["suggestion"]?.string ?? "Take a new snapshot and try again."
        let mapped: HandsErrorCode
        switch code {
        case "STALE_REF", "SNAPSHOT_NOT_FOUND", "ELEMENT_NOT_FOUND": mapped = .staleRef
        case "AMBIGUOUS_TARGET": mapped = .ambiguousTarget
        case "ACTION_NOT_SUPPORTED", "POLICY_DENIED", "PLATFORM_NOT_SUPPORTED": mapped = .notSupported
        case "ACTION_FAILED": mapped = .actionFailed
        case "TIMEOUT", "APP_UNRESPONSIVE": mapped = .timeout
        case "PERM_DENIED": mapped = .permissionDenied
        case "APP_NOT_FOUND": mapped = .appNotFound
        case "WINDOW_NOT_FOUND": mapped = .windowNotFound
        case "INVALID_ARGS": mapped = .badArguments
        default: mapped = .engineError
        }
        var retry = mapped.defaultRetry
        // An action that may have landed is never repeated blindly, whatever the code says.
        let verdict = err["disposition"]?["retry"]?.string
        if verdict == "unsafe" || verdict == "unknown", mapped != .staleRef { retry = .never }
        if verdict == "safe", retry == .never, mapped != .notSupported { retry = .safe }
        return HandsError(mapped, message, suggestion: suggestion, retry: retry)
    }

    /// One window's tree with refs. `windowID` is the engine's id for it ("w-4211").
    func snapshot(app: String?, windowID: UInt32, interactive: Bool, compact: Bool, depth: UInt8, evidence: Bool = false) -> Reply {
        queue.sync {
            if let e = ready() { return .failed(e) }
            let adapter = evidence ? evidenceAdapter : adapter
            var out: UnsafeMutablePointer<CChar>?
            let id = "w-\(windowID)"
            let code: Int32
            if let app {
                code = app.withCString { a in id.withCString { w in
                    ad_snapshot_window(adapter, a, w, Self.surfaceWindow, depth, interactive, compact, &out)
                } }
            } else {
                code = id.withCString { w in
                    ad_snapshot_window(adapter, nil, w, Self.surfaceWindow, depth, interactive, compact, &out)
                }
            }
            return finish(code, out)
        }
    }

    /// One property of a ref, read from the live element.
    func get(ref: String, property: String) -> Reply {
        queue.sync {
            if let e = ready() { return .failed(e) }
            var out: UnsafeMutablePointer<CChar>?
            let code = ref.withCString { r in property.withCString { p in ad_get_ref(adapter, r, p, &out) } }
            return finish(code, out)
        }
    }

    /// An action on a ref. Always Headless; the auto-wait is the engine's default.
    func act(ref: String, kind: Kind, text: String? = nil, direction: Int32 = 1, amount: UInt32 = 3, key: String? = nil, modifiers: [Int32] = []) -> Reply {
        queue.sync {
            if let e = ready() { return .failed(e) }
            var out: UnsafeMutablePointer<CChar>?
            var action = AdAction()
            action.kind = kind.rawValue
            action.scroll.direction = direction
            action.scroll.amount = amount
            func run(_ text: UnsafePointer<CChar>?, _ key: UnsafePointer<CChar>?) -> Int32 {
                action.text = text
                action.key.key = key
                return modifiers.withUnsafeBufferPointer { mods in
                    action.key.modifiers = mods.baseAddress
                    action.key.modifier_count = UInt32(mods.count)
                    return ref.withCString { r in
                        ad_execute_by_ref_timeout(adapter, r, &action, Self.headlessPolicy, 5000, &out)
                    }
                }
            }
            let code: Int32
            switch (text, key) {
            case (let t?, _): code = t.withCString { run($0, nil) }
            case (_, let k?): code = k.withCString { run(nil, $0) }
            default: code = run(nil, nil)
            }
            return finish(code, out)
        }
    }

    /// Whether the engine can read windows at all (Accessibility granted).
    func permissionProblem() -> HandsError? {
        queue.sync {
            if let e = ready() { return e }
            return ad_check_permissions(adapter) == Self.resultOK ? nil
                : HandsError(.permissionDenied, "Accessibility isn't allowed for BaneySpaces",
                             suggestion: "Allow BaneySpaces in System Settings > Privacy & Security > Accessibility.", retry: .safe)
        }
    }
}
