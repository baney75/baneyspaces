import Foundation

/// One argument of a hands command. The CLI reads it as a positional word or a `--flag`, MCP as a
/// property of the tool's arguments object; the name is the same in both.
public struct HandsParam: Equatable, Sendable {
    public enum Kind: String, Sendable { case string, integer, boolean, stringList }
    public var name: String
    public var kind: Kind
    public var help: String
    public var required: Bool
    /// Taken from the words after the verb, in order; otherwise `--name value`.
    public var positional: Bool
    /// `-i` for `--interactive`.
    public var short: String?
    /// Takes every remaining positional word (the last parameter only).
    public var rest: Bool

    public init(_ name: String, _ kind: Kind = .string, _ help: String, required: Bool = false, positional: Bool = false, short: String? = nil, rest: Bool = false) {
        self.name = name; self.kind = kind; self.help = help; self.required = required
        self.positional = positional; self.short = short; self.rest = rest
    }
}

public struct HandsTool: Equatable, Sendable {
    /// `snapshot`, `click`, `set-value`: the CLI word. MCP spells the hyphen `_`.
    public var verb: String
    public var summary: String
    public var params: [HandsParam]
    /// Whether it changes anything in an app (all but the readers).
    public var acts: Bool

    public var mcpName: String { verb.replacingOccurrences(of: "-", with: "_") }
}

/// The commands, once, for the CLI parser, the MCP `tools/list` and the app's dispatcher.
public enum HandsTools {
    static let refParam = HandsParam("ref", .string, "A ref printed by snapshot or find, like @s8f3k2p9:e5.", required: true, positional: true)

    /// Not agent tools: lending an app is Donovan's decision (see `HandsParse.askedForLend`).
    public static let userOnly: Set<String> = ["lend", "return"]

    public static let all: [HandsTool] = [
        HandsTool(verb: "windows", summary: "List the windows an agent may use now: those on the agent workspace and those of lent apps, with their ids.", params: [], acts: false),
        HandsTool(verb: "snapshot", summary: "Read the accessibility tree of one window and print a ref for each thing you can act on. Only the agent workspace and lent apps. Refs last until the next snapshot of that window changes the UI; after a stale_ref error take a new snapshot.", params: [
            HandsParam("app", .string, "App name or bundle id. With several windows on the agent workspace the newest is read; pass window to choose."),
            HandsParam("window", .integer, "Window id from `windows`, `open` or a previous snapshot."),
            HandsParam("interactive", .boolean, "Only elements you can act on (smaller, faster).", short: "i"),
            HandsParam("compact", .boolean, "Collapse wrapper groups with no content."),
            HandsParam("depth", .integer, "How deep to read (default 10)."),
        ], acts: false),
        HandsTool(verb: "find", summary: "Search one window's accessibility tree and return the matching elements with refs.", params: [
            HandsParam("app", .string, "App name or bundle id."),
            HandsParam("window", .integer, "Window id."),
            HandsParam("role", .string, "Role, like button or textfield."),
            HandsParam("name", .string, "Part of the accessible name."),
            HandsParam("text", .string, "Part of any text the element shows."),
            HandsParam("value", .string, "Part of its value."),
            HandsParam("limit", .integer, "At most this many matches (default 20)."),
        ], acts: false),
        HandsTool(verb: "get", summary: "Read one property of an element from the live window: value, text, title, role, bounds or states.", params: [
            refParam,
            HandsParam("property", .string, "value (default), text, title, role, bounds or states.", positional: true),
        ], acts: false),
        HandsTool(verb: "click", summary: "Click an element by ref, without moving the pointer or raising the window. Prints what it verified.", params: [refParam], acts: true),
        HandsTool(verb: "type", summary: "Type text into an element by ref: sets the value when the element allows it, otherwise sends keys to that app only. Prints the value it read back.", params: [
            refParam,
            HandsParam("text", .string, "The text.", required: true, positional: true, rest: true),
        ], acts: true),
        HandsTool(verb: "set-value", summary: "Replace an element's whole value (a text field, a slider). Prints the value it read back.", params: [
            refParam,
            HandsParam("value", .string, "The new value.", required: true, positional: true, rest: true),
        ], acts: true),
        HandsTool(verb: "press", summary: "Press a key or combination (Return, cmd+a, shift+tab). Always answers not_supported for now: keys reach only the app in front, and BaneySpaces never raises one for an agent (background keys arrive in a later phase).", params: [
            refParam,
            HandsParam("key", .string, "Key name with optional modifiers, like cmd+shift+z.", required: true, positional: true),
        ], acts: true),
        HandsTool(verb: "scroll", summary: "Scroll an element by ref.", params: [
            refParam,
            HandsParam("direction", .string, "up, down, left or right.", required: true, positional: true),
            HandsParam("amount", .integer, "Notches (default 3)."),
        ], acts: true),
        HandsTool(verb: "select", summary: "Choose an option in a list, menu or popup by ref.", params: [
            refParam,
            HandsParam("option", .string, "The text of the option to choose.", required: true, positional: true, rest: true),
        ], acts: true),
        HandsTool(verb: "toggle", summary: "Flip a checkbox, switch or disclosure by ref. Prints the state it read back.", params: [refParam], acts: true),
        HandsTool(verb: "shot", summary: "Capture one window as a PNG, even while it is parked out of view. Needs Screen Recording for BaneySpaces. The file stays on this Mac.", params: [
            HandsParam("window", .integer, "Window id.", required: true),
            HandsParam("out", .string, "A file name (no folder) for the PNG; it is written in BaneySpaces' own shots folder."),
            HandsParam("cursor", .boolean, "Draw the agent cursor where it last acted in this window, if it did in the last 30 seconds and was on screen. Off by default, so the picture is the app itself."),
        ], acts: true),
        HandsTool(verb: "open", summary: "Open an app, or files from the agent handoff folder in it, on the agent workspace, without switching the user to it. Apps that hold the user's own data (Safari, Notes, Mail, Messages, Calendar, Photos) answer needs_sandbox.", params: [
            HandsParam("app", .string, "App name or bundle id.", required: true, positional: true),
            HandsParam("targets", .stringList, "Files in the agent handoff folder to open in it. URLs need an agent browser profile (a later phase).", positional: true, rest: true),
        ], acts: true),
    ]

    public static func tool(verb: String) -> HandsTool? {
        let v = verb.replacingOccurrences(of: "_", with: "-")
        return all.first { $0.verb == v }
    }
}

/// A command ready to send to the app: the verb and its arguments by name.
public struct HandsRequest: Codable, Equatable, Sendable {
    public var verb: String
    public var args: [String: JSONValue]
    /// The agent session this comes from, for lends.
    public var session: String?

    public init(verb: String, args: [String: JSONValue] = [:], session: String? = nil) {
        self.verb = verb; self.args = args; self.session = session
    }

    public func string(_ k: String) -> String? { args[k]?.string }
    public func int(_ k: String) -> Int? { args[k]?.int }
    public func bool(_ k: String) -> Bool { args[k]?.bool ?? false }
}

public enum HandsParse {
    /// Reads `snapshot --app TextEdit -i` into a request. Unknown flags, missing values and
    /// missing required arguments come back as `bad_arguments` with the usage.
    /// What an agent gets for `lend` or `return`: they are Donovan's, not tools.
    public static func askedForLend(_ app: String?) -> HandsError {
        let name = app ?? "the app"
        return HandsError(.needsLend, "agents can't lend apps; \(name) is not on the agent workspace",
                          suggestion: "Ask Donovan to lend it: he runs `baneyspaces agent lend \(name)` in a terminal he types in, or picks it in the BaneySpaces menu under Lend to Agents. Or do the work on the agent workspace with `baneyspaces agent open \(name)` (apps that hold his data go to the sandbox).",
                          retry: .never)
    }

    public static func command(_ words: [String], session: String? = nil) -> Result<HandsRequest, HandsError> {
        if let verb = words.first, HandsTools.userOnly.contains(verb) { return .failure(askedForLend(words.dropFirst().first)) }
        guard let verb = words.first, let tool = HandsTools.tool(verb: verb) else {
            return .failure(HandsError(.badArguments, "unknown agent command \(words.first ?? "")",
                                       suggestion: "Commands: " + HandsTools.all.map(\.verb).joined(separator: ", ")))
        }
        var args: [String: JSONValue] = [:]
        var positionals: [String] = []
        let flagged = tool.params.filter { !$0.positional }
        var i = 1
        while i < words.count {
            let w = words[i]
            if w == "--" { positionals += words[(i + 1)...]; break }
            if w.hasPrefix("-"), w.count > 1, Int(w) == nil, Double(w) == nil {
                let (name, inline): (String, String?) = {
                    guard w.hasPrefix("--"), let eq = w.firstIndex(of: "=") else { return (w, nil) }
                    return (String(w[..<eq]), String(w[w.index(after: eq)...]))
                }()
                guard let p = flagged.first(where: { "--" + $0.name == name || ($0.short.map { "-" + $0 } == name) }) else {
                    return .failure(usage(tool, "unknown option \(name)"))
                }
                switch p.kind {
                case .boolean:
                    args[p.name] = .bool(inline.map { $0 != "false" && $0 != "0" } ?? true)
                case .stringList:
                    return .failure(usage(tool, "\(name) is not an option"))
                case .integer, .string:
                    guard let v = inline ?? (i + 1 < words.count ? words[i + 1] : nil) else { return .failure(usage(tool, "\(name) needs a value")) }
                    if inline == nil { i += 1 }
                    if p.kind == .integer {
                        guard let n = Int(v) else { return .failure(usage(tool, "\(name) takes a number, not \(v)")) }
                        args[p.name] = .int(n)
                    } else {
                        args[p.name] = .string(v)
                    }
                }
            } else {
                positionals.append(w)
            }
            i += 1
        }
        var rest = positionals[...]
        for p in tool.params where p.positional {
            if p.rest {
                if !rest.isEmpty {
                    args[p.name] = p.kind == .stringList ? .array(rest.map(JSONValue.string)) : .string(rest.joined(separator: " "))
                }
                rest = []
            } else if let w = rest.first {
                args[p.name] = .string(w)
                rest = rest.dropFirst()
            }
        }
        if !rest.isEmpty { return .failure(usage(tool, "unexpected \(rest.joined(separator: " "))")) }
        return validated(HandsRequest(verb: tool.verb, args: args, session: session), tool)
    }

    /// An MCP tool call: `arguments` by name.
    public static func call(name: String, arguments: [String: JSONValue], session: String? = nil) -> Result<HandsRequest, HandsError> {
        if HandsTools.userOnly.contains(name) { return .failure(askedForLend(arguments["app"]?.string)) }
        guard let tool = HandsTools.tool(verb: name) else {
            return .failure(HandsError(.badArguments, "unknown tool \(name)", suggestion: "Call tools/list for the tools."))
        }
        var args: [String: JSONValue] = [:]
        for (k, v) in arguments {
            guard let p = tool.params.first(where: { $0.name == k }) else { return .failure(usage(tool, "unknown argument \(k)")) }
            switch p.kind {
            case .string: args[k] = v.string.map(JSONValue.string) ?? .string(v.text)
            case .stringList:
                guard let a = v.array, a.allSatisfy({ $0.string != nil }) else { return .failure(usage(tool, "\(k) takes a list of strings")) }
                args[k] = v
            case .integer:
                guard let n = v.int else { return .failure(usage(tool, "\(k) takes a number")) }
                args[k] = .int(n)
            case .boolean:
                guard let b = v.bool else { return .failure(usage(tool, "\(k) takes true or false")) }
                args[k] = .bool(b)
            }
        }
        return validated(HandsRequest(verb: tool.verb, args: args, session: session), tool)
    }

    private static func validated(_ r: HandsRequest, _ tool: HandsTool) -> Result<HandsRequest, HandsError> {
        for p in tool.params where p.required && r.args[p.name] == nil {
            return .failure(usage(tool, "\(p.name) is missing"))
        }
        if tool.verb == "snapshot" || tool.verb == "find", r.args["app"] == nil, r.args["window"] == nil {
            return .failure(usage(tool, "say which window: app or window"))
        }
        return .success(r)
    }

    public static func usageLine(_ tool: HandsTool) -> String {
        var parts = ["baneyspaces agent", tool.verb]
        for p in tool.params {
            if p.positional { parts.append(p.required ? "<\(p.name)>" : "[\(p.name)\(p.rest ? "…" : "")]") }
            else {
                let flag = "--" + p.name + (p.kind == .boolean ? "" : " <\(p.name)>")
                parts.append(p.required ? flag : "[\(flag)]")
            }
        }
        return parts.joined(separator: " ")
    }

    static func usage(_ tool: HandsTool, _ why: String) -> HandsError {
        HandsError(.badArguments, why, suggestion: "usage: " + usageLine(tool), retry: .safe)
    }
}
