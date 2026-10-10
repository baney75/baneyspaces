import Foundation

/// Which workspace each window was on, saved on every change so a restart (an update, a
/// crash, logging back in) keeps the layout. Window numbers are reused after a logout, so each
/// entry also records the window's process: a saved entry applies only to the same running app.
public struct SavedLayout: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        public var window: WindowID
        public var pid: Int32
        public var workspace: Int
        public init(window: WindowID, pid: Int32, workspace: Int) {
            self.window = window; self.pid = pid; self.workspace = workspace
        }
    }

    public var current = 1
    public var entries: [Entry] = []
    public var lastFocused: [Int: WindowID] = [:]

    public init(current: Int = 1, entries: [Entry] = [], lastFocused: [Int: WindowID] = [:]) {
        self.current = current; self.entries = entries; self.lastFocused = lastFocused
    }

    /// The saved workspace for each window that still belongs to the same process.
    public func homes(livePids: [WindowID: Int32]) -> [WindowID: Int] {
        var out: [WindowID: Int] = [:]
        for e in entries where livePids[e.window] == e.pid { out[e.window] = e.workspace }
        return out
    }

    public static func load(from url: URL) -> SavedLayout? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedLayout.self, from: data)
    }

    public func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
