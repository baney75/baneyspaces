import Foundation

/// Turns what each adapter read into Deck rows. Pure, so the rules are unit-tested.
public enum Build {
    /// Ghostty: one row per terminal, splits nested under their tab's first terminal.
    public static func ghostty(_ spec: AppSpec, _ snap: Snapshot, numbers: [String: UInt32], front: Bool) -> [Item] {
        let focused = front ? snap.focusedID : nil
        var seenTabs = Set<String>()
        return snap.terminals.map { t in
            let firstInTab = seenTabs.insert(t.tabID).inserted
            return Item(id: "ghostty:" + t.id, bundleID: spec.bundleID, appName: spec.name, role: spec.role, kind: .terminal,
                        windowNumber: numbers[t.windowID] ?? 0, group: "ghostty:" + t.windowID, title: t.title,
                        detail: Snapshot.shortPath(t.directory), directory: t.directory,
                        activity: t.activity, focused: t.id == focused, nested: !firstInTab)
        }
    }

    /// Browsers: a row per tab. Terminal and iTerm: a row per tab or session, with its tty.
    public static func scripted(_ spec: AppSpec, _ snap: ScriptedSnapshot, numbers: [String: UInt32], front: Bool,
                                frontWindowNumber: UInt32) -> [Item] {
        var out: [Item] = []
        for w in snap.windows {
            let number = numbers[w.id] ?? 0
            let group = "\(spec.bundleID):\(w.id)"
            if w.isPrivate {
                out.append(Item(id: "win:\(spec.bundleID):\(w.id)", bundleID: spec.bundleID, appName: spec.name, role: spec.role,
                                kind: .window, windowNumber: number, group: group, title: "Private window",
                                focused: front && number != 0 && number == frontWindowNumber))
                continue
            }
            for t in snap.tabs where t.windowID == w.id {
                let isFront = front && t.selected && number != 0 && number == frontWindowNumber
                let isTerminal = spec.role == .terminal
                out.append(Item(id: "tab:\(spec.bundleID):\(w.id):\(t.id)", bundleID: spec.bundleID, appName: spec.name,
                                role: spec.role, kind: isTerminal ? .terminal : .tab, windowNumber: number, group: group,
                                title: t.title, detail: isTerminal ? t.tty.replacingOccurrences(of: "/dev/", with: "") : URLDisplay.short(t.url),
                                tty: t.tty, activity: isTerminal ? Activity.of(title: t.title) : .shell, focused: isFront))
            }
        }
        return out
    }

    /// Any other app: a row per window.
    public static func windows(_ spec: AppSpec, _ wins: [(number: UInt32, title: String)], front: Bool, frontWindowNumber: UInt32) -> [Item] {
        wins.map { w in
            Item(id: "win:\(w.number)", bundleID: spec.bundleID, appName: spec.name, role: spec.role, kind: .window,
                 windowNumber: w.number, group: "win:\(w.number)", title: w.title.isEmpty ? spec.name : w.title,
                 activity: spec.role == .terminal ? Activity.of(title: w.title) : .shell,
                 focused: front && w.number == frontWindowNumber)
        }
    }
}
