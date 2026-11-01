import Foundation

// What the overview does besides lay cards out: type to find, the help line, the motion it picks
// and how it marks the workspace you're on. All of it is plain data so each rule is a test.

/// Type to find (spec/overview.md): any letter filters every window on every workspace, by title and
/// app, with the launcher's matcher. Cards that don't match dim to 25 %; Return goes to the best.
public struct OverviewFilter: Sendable {
    public struct Item: Sendable {
        public let id: WindowID
        public let workspace: Int
        fileprivate let app: String
        fileprivate let title: String

        public init(id: WindowID, workspace: Int, app: String, title: String) {
            self.id = id; self.workspace = workspace
            // Folded once, when the overview opens: a keystroke only folds the query.
            self.app = Fuzzy.fold(app); self.title = Fuzzy.fold(title)
        }
    }

    /// How a card that doesn't match is drawn.
    public static let dimmedOpacity = 0.25
    /// A title matches only on a real hit (the text, a word or the initials), so letters scattered
    /// through a long title never light up a window. An app's name may match loosely, like the launcher's.
    public static let titleFloor = 500

    public let items: [Item]
    public init(_ items: [Item]) { self.items = items }

    public struct Result: Equatable, Sendable {
        /// Matching windows with their scores.
        public let scores: [WindowID: Int]
        /// The window Return goes to, if any matched.
        public let best: WindowID?
        public var isEmpty: Bool { scores.isEmpty }
        /// Whether a window stays lit.
        public func matches(_ id: WindowID) -> Bool { scores[id] != nil }
    }

    /// The windows `text` matches. An empty query matches everything and picks nothing.
    /// `prefer` is the workspace shown: on a tie, a window there wins, then the lower workspace.
    public func match(_ text: String, prefer: Int = 1) -> Result {
        let q = Fuzzy.fold(text)
        guard !q.isEmpty else { return Result(scores: Dictionary(uniqueKeysWithValues: items.map { ($0.id, 0) }), best: nil) }
        var scores: [WindowID: Int] = [:]
        var best: (item: Item, score: Int)?
        for item in items {
            var s = Fuzzy.score(folded: q, in: item.app)
            if let t = Fuzzy.score(folded: q, in: item.title), t >= Self.titleFloor, t > (s ?? 0) { s = t }
            guard let score = s else { continue }
            scores[item.id] = score
            if best == nil || beats(item, score, best!.item, best!.score, prefer: prefer) { best = (item, score) }
        }
        return Result(scores: scores, best: best?.item.id)
    }

    private func beats(_ a: Item, _ sa: Int, _ b: Item, _ sb: Int, prefer: Int) -> Bool {
        if sa != sb { return sa > sb }
        if (a.workspace == prefer) != (b.workspace == prefer) { return a.workspace == prefer }
        return a.workspace < b.workspace
    }
}

/// The one help line at the bottom: shown until the overview has been opened 20 times, and again
/// whenever `?` is pressed.
public struct OverviewHelp: Equatable, Sendable {
    public static let line = "1–9 go · type to find · drag to move · esc"
    public static let hideAfter = 20

    public var opens: Int
    /// `?` showed it again.
    public var forced = false

    public init(opens: Int = 0) { self.opens = opens }

    public var visible: Bool { forced || opens < Self.hideAfter }

    /// The overview opened: counts it, and `?`'s showing ends with the visit.
    public mutating func opened() { opens += 1; forced = false }

    public mutating func toggle() { forced.toggle() }
}

/// How the overview's cards come and go (spec/overview.md, Motion): the snapshot layer moves,
/// never the window.
public enum OverviewMotion: Equatable, Sendable {
    /// Each card springs from its window's real place into its tile.
    case travel
    /// Cards fade and scale from `from` (0.96).
    case scale(from: Double)
    /// Cards fade where they are: a theme that never scales or slides (Omarchy, Minimal).
    case fade
    /// Reduce Motion: they are just there.
    case none

    public static let scaleFrom = 0.96

    /// With live previews and a theme that moves, cards travel; with previews off they fade and
    /// scale; where the theme only fades, they fade; under Reduce Motion nothing moves.
    public static func plan(spec: ThemeSpec, previews: Bool, reduceMotion: Bool) -> OverviewMotion {
        if reduceMotion { return .none }
        guard spec.motion.slides else { return .fade }
        return previews ? .travel : .scale(from: scaleFrom)
    }
}

/// Spring settings for a transition's settle time and damping, as `config.md` writes them
/// (`response`, `damping`): the stiffness and damping a spring needs to settle in about `response` seconds.
public struct OverviewSpring: Equatable, Sendable {
    public var response: Double
    public var damping: Double
    public init(response: Double, damping: Double) { self.response = response; self.damping = damping }

    public var stiffness: Double { pow(2 * Double.pi / max(response, 0.001), 2) }
    public var dampingCoefficient: Double { 2 * damping * stiffness.squareRoot() }

    /// `overview.in` as the BaneySpaces preset has it: the theme's motion (`themes.json` `motion`) as a spring.
    /// `config.md` pairs a 180 ms duration with a 0.32 s response, which is the 1.8 here.
    public static func opening(spec: ThemeSpec) -> OverviewSpring { OverviewSpring(response: max(spec.motion.inMs, 120) / 1000 * 1.8, damping: 0.86) }
    public static func closing(spec: ThemeSpec) -> OverviewSpring { OverviewSpring(response: max(spec.motion.outMs, 100) / 1000 * 1.8, damping: 0.92) }
}

/// How the workspace you're on is marked (spec/overview.md): the theme's focused border in `accent`,
/// a soft glow in the BaneySpaces theme, a 2 px border in Omarchy, 1 px in Minimal. Never red,
/// which means something is wrong: `urgent` is never what marks the place you are.
public struct OverviewMark: Equatable, Sendable {
    /// The palette role of the line. Always `accent`.
    public let role: String
    public let width: Double
    /// A glow of the accent around the tile: only a theme that has a shadow has one.
    public let glow: Bool

    public static func current(_ spec: ThemeSpec, theme: ThemeID) -> OverviewMark {
        // The BaneySpaces theme keeps each surface's own widths (`Surface.shippedBorder`).
        let width = theme == .baneyspaces ? Surface.overviewTile.shippedBorder.focused : spec.border.focusedWidth
        return OverviewMark(role: "accent", width: width, glow: spec.shadow != nil)
    }
}
