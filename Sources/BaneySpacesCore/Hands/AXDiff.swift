import Foundation

/// What changed in a window's accessibility tree between two snapshots: the evidence a click or a
/// toggle returns. Refs and positions are ignored (a new snapshot renumbers every ref, and a
/// window that moved isn't a change in what it shows).
public struct AXDiff: Equatable, Sendable {
    public var before: Int
    public var after: Int
    public var added: [String]
    public var removed: [String]

    public var changed: Bool { !added.isEmpty || !removed.isEmpty }

    /// One short line per element: role, name, value, states.
    public static func signatures(of tree: JSONValue) -> [String] {
        var out: [String] = []
        func walk(_ n: JSONValue) {
            guard case .object(let o) = n else { return }
            let role = o["role"]?.string ?? ""
            let name = o["name"]?.string ?? o["title"]?.string ?? ""
            let value = o["value"]?.string ?? ""
            let states = (o["states"]?.array ?? []).compactMap(\.string).sorted().joined(separator: ",")
            if !(role.isEmpty && name.isEmpty && value.isEmpty) {
                out.append([role, name, value, states].joined(separator: "|"))
            }
            for c in o["children"]?.array ?? [] { walk(c) }
        }
        walk(tree)
        return out
    }

    public static func between(_ before: JSONValue, _ after: JSONValue) -> AXDiff {
        let a = signatures(of: before), b = signatures(of: after)
        var counts: [String: Int] = [:]
        for s in a { counts[s, default: 0] += 1 }
        var added: [String] = []
        for s in b {
            if let n = counts[s], n > 0 { counts[s] = n - 1 } else { added.append(s) }
        }
        let removed = counts.flatMap { Array(repeating: $0.key, count: $0.value) }.sorted()
        return AXDiff(before: a.count, after: b.count, added: added, removed: removed)
    }

    /// A short summary for the envelope: counts and the first few changed elements.
    public func json(limit: Int = 5) -> JSONValue {
        .object([
            "kind": "ax_diff",
            "changed": .bool(changed),
            "elements_before": .int(before),
            "elements_after": .int(after),
            "added": .array(added.prefix(limit).map(JSONValue.string)),
            "removed": .array(removed.prefix(limit).map(JSONValue.string)),
            "added_count": .int(added.count),
            "removed_count": .int(removed.count),
        ])
    }
}
