/// The order a workspace's apps take on its dock tile, its "+N" list and its ⌘Tab card: the one
/// you used there last comes first (2026-11-01: Grok Bot was in front, yet the "+N" list had it
/// behind Silas). Apps never used on that workspace since BaneySpaces started keep the order
/// they came in, which is their windows' order there, after every app that has been used.
public enum DockAppOrder {
    /// `activatedAt` is when each app last came forward on the workspace, larger being later.
    public static func sort(_ keys: [String], activatedAt: [String: Double]) -> [String] {
        keys.enumerated().sorted { a, b in
            switch (activatedAt[a.element], activatedAt[b.element]) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Under the pointer icons hold still: `proposed` replaces `previous` only when nobody hovers
    /// the tile, or when the set of apps changed (an app opened or quit). `replayOwed` says the
    /// held order differs from `proposed`, so a reload is due once the pointer leaves.
    public static func held(proposed: [String], previous: [String]?, hovering: Bool) -> (order: [String], replayOwed: Bool) {
        guard hovering, let previous, Set(previous) == Set(proposed), previous.count == proposed.count else { return (proposed, false) }
        return (previous, previous != proposed)
    }
}

/// When each app last came forward on each workspace. An app split across workspaces has a time
/// on each, so using it on one doesn't move it to the front of another.
public struct AppActivations: Equatable, Sendable {
    private var stamps: [Int: [String: Double]] = [:]

    public init() {}

    public mutating func note(_ key: String, on workspace: Int, at time: Double) {
        stamps[workspace, default: [:]][key] = time
    }

    public func on(_ workspace: Int) -> [String: Double] { stamps[workspace] ?? [:] }

    public var all: [Int: [String: Double]] { stamps }

    /// An app that quit: its process id may come back as another app.
    public mutating func forget(_ key: String) {
        for n in stamps.keys { stamps[n]?[key] = nil }
    }
}
