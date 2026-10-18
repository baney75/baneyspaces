import CoreGraphics
import Foundation

/// A drag that started in another app (a file from Finder, a link or image from a browser):
/// the system's drag pasteboard changes while the mouse button is down. A drag inside the dock,
/// or a window being moved by its title bar, never touches that pasteboard.
public struct OutsideDrag: Sendable {
    /// The pasteboard's change count on the last tick the buttons were up, so a late write (a
    /// drop finishing, a cancelled drag sliding back) isn't taken for the next drag. A press
    /// compares with it, however fast that press starts a drag.
    private var upCount: Int?
    public private(set) var active = false

    public init() {}

    /// Call on every tick; true while such a drag is under way. The count is read on each tick
    /// until a drag shows: 0.8 µs a read on an M-series Mac (measured 2026-10-17), about 24 µs a
    /// second at the dock's 30 Hz.
    @discardableResult
    public mutating func update(buttonsDown: Bool, changeCount: () -> Int) -> Bool {
        guard buttonsDown else {
            upCount = changeCount()
            active = false
            return false
        }
        guard !active else { return true }
        let count = changeCount()
        // Down on the very first tick: nothing to compare with, so this press counts as before.
        guard let upCount else { self.upCount = count; return false }
        active = count != upCount
        return active
    }
}

/// What a drag from another app rests on in the dock.
public enum DockSpringTarget: Equatable, Sendable {
    /// An app's icon on a workspace's tile: its window there comes forward.
    case app(workspace: Int, id: String)
    /// A tile, between its icons: that workspace comes up.
    case tile(Int)

    public var workspace: Int {
        switch self {
        case .app(let n, _), .tile(let n): n
        }
    }

    /// The icon under the pointer, else its tile. `apps` are keyed "workspace:app id" and
    /// `tiles` "tile:workspace", as the dock reports its frames.
    public static func at(_ p: CGPoint, frames: [String: CGRect]) -> DockSpringTarget? {
        var tile: Int?
        for (key, frame) in frames where frame.contains(p) {
            if key.hasPrefix("tile:") {
                if let n = Int(key.dropFirst(5)) { tile = n }
                continue
            }
            let parts = key.split(separator: ":", maxSplits: 1)
            if parts.count == 2, let n = Int(parts[0]) { return .app(workspace: n, id: String(parts[1])) }
        }
        return tile.map { .tile($0) }
    }
}

/// Whether an app's icon takes a drop: only when the app can open every file or link dropped,
/// as the macOS Dock lights an icon only for what its app claims. `handlers` lists the apps
/// that can open a URL (`NSWorkspace.urlsForApplications(toOpen:)`); `identify` names an app
/// bundle by its bundle identifier. Apps are matched by identifier, not path: Safari runs from a
/// Cryptex and a quarantined app from a translocated copy, so paths can differ for the same app.
public enum DockOpen {
    /// What decides which apps can open a URL: its kind of file, or its scheme for a link.
    /// The app passes the file's content type; this default uses the extension.
    public static func kind(_ url: URL) -> String {
        url.isFileURL ? "file:" + url.pathExtension.lowercased() : "url:" + (url.scheme ?? "").lowercased()
    }

    /// The bundle identifiers of the apps that can open every one of `urls`, asked once per drag
    /// and once per kind, so 500 PNGs cost one LaunchServices query.
    public static func apps(openingAll urls: [URL], kind: (URL) -> String = DockOpen.kind,
                            handlers: (URL) -> [URL], identify: (URL) -> String?) -> Set<String> {
        var seen = Set<String>()
        var common: Set<String>?
        for url in urls where seen.insert(kind(url)).inserted {
            let ids = Set(handlers(url).compactMap(identify))
            common = common.map { $0.intersection(ids) } ?? ids
            if common?.isEmpty == true { break }
        }
        return common ?? []
    }
}

/// Resting a drag on one target opens it once, after `delay`, the way the macOS Dock springs an
/// app open under a file held over its icon. Moving to another target starts the wait again.
public struct SpringLoad: Sendable {
    public static let delay: TimeInterval = 0.6
    private var target: DockSpringTarget?
    private var since = Date.distantPast
    private var fired = false

    public init() {}

    /// The target to open now, at most once per rest.
    public mutating func update(_ t: DockSpringTarget?, now: Date = Date()) -> DockSpringTarget? {
        if t != target {
            target = t
            since = now
            fired = false
            return nil
        }
        guard let t, !fired, now.timeIntervalSince(since) >= SpringLoad.delay else { return nil }
        fired = true
        return t
    }

    public mutating func reset() { self = SpringLoad() }
}
