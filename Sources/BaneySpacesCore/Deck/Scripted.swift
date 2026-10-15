import Foundation

/// Parsed output of the AppleScript reads for browsers, Terminal and iTerm. Each record is split by
/// ASCII record separators and its fields by unit separators, so titles holding tabs or new lines
/// can't break a row. A record's first field says what it is: W window, T tab, S session.
public struct ScriptedSnapshot: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public var id: String
        public var title: String
        /// 1-based index of the tab showing; 0 when the app didn't say.
        public var activeTab: Int
        /// An incognito or private window. Its tabs aren't read.
        public var isPrivate: Bool
    }

    public struct Tab: Equatable, Sendable {
        public var windowID: String
        public var id: String
        public var index: Int
        public var title: String
        /// A URL for browsers, a tty for terminals.
        public var url: String
        public var tty: String
        public var selected: Bool
    }

    public var windows: [Window] = []
    public var tabs: [Tab] = []

    public init(windows: [Window] = [], tabs: [Tab] = []) { self.windows = windows; self.tabs = tabs }

    public static func parse(_ raw: String) -> ScriptedSnapshot {
        var s = ScriptedSnapshot()
        var browserTabs: [Int] = []
        for r in raw.split(separator: Snapshot.recordSeparator) {
            let f = r.split(separator: Snapshot.fieldSeparator, omittingEmptySubsequences: false).map(String.init)
            guard let kind = f.first else { continue }
            switch kind {
            case "W" where f.count >= 3:
                s.windows.append(Window(id: f[1], title: f[2], activeTab: f.count > 3 ? Int(f[3]) ?? 0 : 0,
                                        isPrivate: f.count > 4 && f[4] == "incognito"))
            case "T" where f.count >= 6:
                // Browser tab: W id, tab id, index, title, URL.
                browserTabs.append(s.tabs.count)
                s.tabs.append(Tab(windowID: f[1], id: f[2], index: Int(f[3]) ?? 0, title: f[4], url: f[5], tty: "", selected: false))
            case "S" where f.count >= 7:
                // Terminal tab or iTerm session: W id, session id, tab index, title, tty, selected.
                s.tabs.append(Tab(windowID: f[1], id: f[2], index: Int(f[3]) ?? 0, title: f[4], url: "", tty: f[5], selected: f[6] == "true"))
            default: continue
            }
        }
        // A browser reports which tab shows per window, not per tab.
        for i in browserTabs {
            if let w = s.windows.first(where: { $0.id == s.tabs[i].windowID }) { s.tabs[i].selected = s.tabs[i].index == w.activeTab }
        }
        return s
    }
}
