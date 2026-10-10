import CoreGraphics

public typealias WindowID = UInt32

/// What a workspace switch has to do to real windows.
public struct SwitchPlan: Equatable {
    public var hide: [WindowID]
    public var show: [WindowID]
    /// The window to focus after the switch, or nil when the workspace is empty.
    public var focus: WindowID?
}

/// Nine workspaces and which window lives on each. Windows are identified by their
/// WindowServer number, which stays the same for the life of the window.
public struct Workspaces: Codable, Equatable {
    public static let range = 1...9

    public private(set) var current = 1
    public private(set) var home: [WindowID: Int] = [:]
    /// The last window focused on each workspace, so coming back lands where you left off.
    public private(set) var lastFocused: [Int: WindowID] = [:]

    public init() {}

    /// Updates the model. `seen` is what Accessibility listed just now; `alive` is every window the
    /// WindowServer still has. A window that is alive but went unlisted (a busy app, another macOS
    /// desktop) keeps its place. A window seen for the first time joins the current workspace,
    /// since that is where it appeared. Returns the newcomers.
    @discardableResult
    public mutating func sync(seen: [WindowID], alive: Set<WindowID>) -> [WindowID] {
        home = home.filter { alive.contains($0.key) }
        lastFocused = lastFocused.filter { alive.contains($0.value) && home[$0.value] == $0.key }
        var added: [WindowID] = []
        for id in seen where home[id] == nil && alive.contains(id) {
            home[id] = current
            added.append(id)
        }
        return added
    }

    public func workspace(of id: WindowID) -> Int? { home[id] }

    public func windows(on n: Int) -> [WindowID] {
        home.filter { $0.value == n }.map(\.key).sorted()
    }

    public mutating func noteFocus(_ id: WindowID) {
        guard let n = home[id] else { return }
        lastFocused[n] = id
    }

    public mutating func assign(_ id: WindowID, to n: Int) {
        guard Self.range.contains(n), home[id] != nil else { return }
        if let old = home[id], lastFocused[old] == id { lastFocused[old] = nil }
        home[id] = n
        lastFocused[n] = id
    }

    /// Makes `n` current and says which windows to hide and show. Switching to the workspace
    /// you are on still returns a full plan, which repairs anything an app moved on its own.
    public mutating func switchTo(_ n: Int) -> SwitchPlan {
        precondition(Self.range.contains(n), "workspace \(n) is out of range")
        current = n
        let show = windows(on: n)
        let hide = home.filter { $0.value != n }.map(\.key).sorted()
        let focus = lastFocused[n].flatMap { show.contains($0) ? $0 : nil } ?? show.first
        return SwitchPlan(hide: hide, show: show, focus: focus)
    }
}
