import Foundation

/// The stdio MCP server behind `baneyspaces mcp`: JSON-RPC 2.0, one message per line. It owns no
/// logic of its own; every tool call becomes a `HandsRequest` and goes to `perform`, which asks the
/// BaneySpaces app, so Claude Code, Codex and a shell all get the same checks and the same answers.
public struct HandsMCP {
    public static let serverName = "baneyspaces"
    public static let defaultProtocol = "2025-06-18"
    public static let instructions = """
    BaneySpaces' hands: read and act on apps on the user's Mac without touching their screen. \
    Work in a loop: `open` an app (it lands on the agent workspace), `windows` for its window id, \
    `snapshot` that window (interactive) to get refs, act on a ref (`click`, `type`, `set_value`, `press`, \
    `scroll`, `select`, `toggle`), then read the evidence in the result and `get` or snapshot again to check. \
    Refs go stale when the UI changes: on a stale_ref error take a new snapshot. Only windows on the agent \
    workspace or of apps you `lend` are allowed; anything else returns outside_agent_workspace. \
    Never ask the user to switch away from what they are doing.
    """

    public var version: String
    public var session: String
    public var perform: (HandsRequest) -> HandsEnvelope
    /// Reads a screenshot file for the `shot` tool's image block.
    public var readImage: (String) -> Data?

    public init(version: String, session: String, perform: @escaping (HandsRequest) -> HandsEnvelope, readImage: @escaping (String) -> Data? = { _ in nil }) {
        self.version = version; self.session = session; self.perform = perform; self.readImage = readImage
    }

    /// The tools, as `tools/list` returns them.
    public static func toolList() -> JSONValue {
        .array(HandsTools.all.map { t in
            var props: [String: JSONValue] = [:]
            for p in t.params {
                props[p.name] = .object(["type": .string(p.kind.rawValue), "description": .string(p.help)])
            }
            var schema: [String: JSONValue] = ["type": "object", "properties": .object(props), "additionalProperties": false]
            let req = t.params.filter(\.required).map { JSONValue.string($0.name) }
            if !req.isEmpty { schema["required"] = .array(req) }
            return .object([
                "name": .string(t.mcpName),
                "description": .string(t.summary),
                "inputSchema": .object(schema),
                "annotations": .object(["readOnlyHint": .bool(!t.acts), "openWorldHint": false]),
            ])
        })
    }

    /// The reply to one line, or nil when none is owed (a notification).
    public func handle(_ line: String) -> String? {
        guard let msg = JSONValue.parse(line), case .object = msg else {
            return reply(id: .null, error: (-32700, "parse error"))
        }
        let id = msg["id"]
        guard let method = msg["method"]?.string else {
            // A response to something we sent; we send nothing.
            return nil
        }
        guard let id else { return nil } // notification
        switch method {
        case "initialize":
            let asked = msg["params"]?["protocolVersion"]?.string ?? Self.defaultProtocol
            return reply(id: id, result: .object([
                "protocolVersion": .string(asked),
                "capabilities": .object(["tools": .object(["listChanged": false])]),
                "serverInfo": .object(["name": .string(Self.serverName), "version": .string(version)]),
                "instructions": .string(Self.instructions),
            ]))
        case "ping":
            return reply(id: id, result: .object([:]))
        case "tools/list":
            return reply(id: id, result: .object(["tools": Self.toolList()]))
        case "tools/call":
            guard let name = msg["params"]?["name"]?.string else { return reply(id: id, error: (-32602, "tools/call needs a name")) }
            let arguments = msg["params"]?["arguments"]?.object ?? [:]
            let envelope: HandsEnvelope
            switch HandsParse.call(name: name, arguments: arguments, session: session) {
            case .failure(let e): envelope = .failure(e)
            case .success(let r): envelope = perform(r)
            }
            var content: [JSONValue] = [.object(["type": "text", "text": .string(envelope.line)])]
            if envelope.ok, HandsTools.tool(verb: name)?.verb == "shot", let path = envelope.data?["path"]?.string,
               let png = readImage(path) {
                content.append(.object(["type": "image", "data": .string(png.base64EncodedString()), "mimeType": "image/png"]))
            }
            return reply(id: id, result: .object(["content": .array(content), "isError": .bool(!envelope.ok)]))
        default:
            return reply(id: id, error: (-32601, "method not found: \(method)"))
        }
    }

    private func reply(id: JSONValue, result: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).text
    }

    private func reply(id: JSONValue, error: (Int, String)) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "error": .object(["code": .int(error.0), "message": .string(error.1)])]).text
    }
}
