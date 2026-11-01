import CoreGraphics
import Foundation

// The overview's layout (spec/overview.md), with no AppKit: where every tile, card and strip slot
// goes on one display. The view draws these rectangles and nothing else, and the tests hold them
// to the spec: nothing clipped, no two cards overlapping, every window shown (or counted in a
// "+N" card), every workspace reachable.

/// `behavior.overview.layout`: adaptive gives the room to the workspaces that have windows; grid
/// keeps nine equal tiles.
public enum OverviewLayoutMode: String, CaseIterable, Sendable { case adaptive, grid }

/// `behavior.overview.empty`: empty workspaces become a strip of numbered slots, get full tiles, or
/// are left out except while a window is dragged.
public enum OverviewEmptyMode: String, CaseIterable, Sendable { case compact, full, hidden }

/// `behavior.overview.previews`: live previews where the platform allows, or app icons only.
public enum OverviewPreviewMode: String, CaseIterable, Sendable { case live, icons }

/// The three overview keys of `behavior.overview` (spec/config.md). Until the config file lands on
/// macOS they are the defaults here; the layout takes them as they are.
public struct OverviewSettings: Equatable, Sendable {
    public var layout: OverviewLayoutMode
    public var empty: OverviewEmptyMode
    public var previews: OverviewPreviewMode
    public init(layout: OverviewLayoutMode = .adaptive, empty: OverviewEmptyMode = .compact, previews: OverviewPreviewMode = .live) {
        self.layout = layout; self.empty = empty; self.previews = previews
    }
}

/// Sizes the overview takes from the theme's `space` and `font` tokens, so each theme keeps its own
/// density: Omarchy's gaps are 5, the BaneySpaces theme's 8.
public struct OverviewMetrics: Equatable, Sendable {
    /// The screen's edge to the content.
    public var outer: CGFloat
    public var tileGap: CGFloat
    public var tilePadding: CGFloat
    /// A tile's header: the number and the window count.
    public var header: CGFloat
    public var cardGap: CGFloat
    /// A strip slot: the size of a dock tile.
    public var slot: CGFloat
    public var stripGap: CGFloat
    /// The help line.
    public var help: CGFloat
    /// The smallest card the layout aims for before it gives a tile more room.
    public var minCardHeight: CGFloat
    /// More windows than this in one tile collapse into a "+N" card.
    public var cap: Int

    public init(outer: CGFloat, tileGap: CGFloat, tilePadding: CGFloat, header: CGFloat, cardGap: CGFloat, slot: CGFloat,
                stripGap: CGFloat, help: CGFloat, minCardHeight: CGFloat, cap: Int = 24) {
        self.outer = outer; self.tileGap = tileGap; self.tilePadding = tilePadding; self.header = header
        self.cardGap = cardGap; self.slot = slot; self.stripGap = stripGap; self.help = help
        self.minCardHeight = minCardHeight; self.cap = cap
    }

    public static func make(spec: ThemeSpec) -> OverviewMetrics {
        let unit = CGFloat(spec.space.gap / 8)
        let type = CGFloat(spec.font.size / 12)
        return OverviewMetrics(
            outer: 48 * unit, tileGap: 20 * unit, tilePadding: CGFloat(spec.space.padding) * 1.4,
            header: 30 * type, cardGap: CGFloat(spec.space.gap), slot: CGFloat(spec.space.tile),
            stripGap: CGFloat(spec.space.gap), help: 28 * type, minCardHeight: 72 * type)
    }
}

/// One window as the layout sees it.
public struct OverviewWindow: Equatable, Sendable {
    public var id: WindowID
    public var workspace: Int
    /// Its real frame, in the same coordinates as `OverviewInput.screen`; nil when it isn't known.
    public var frame: CGRect?
    public init(id: WindowID, workspace: Int, frame: CGRect? = nil) {
        self.id = id; self.workspace = workspace; self.frame = frame
    }
}

public struct OverviewInput: Equatable, Sendable {
    /// The display's size in points; the layout's origin is the display's top-left corner.
    public var size: CGSize
    /// The camera housing on a notched display: nothing is drawn above it.
    public var safeTop: CGFloat
    /// The display's real frame, for placing each card where its window is.
    public var screen: CGRect
    public var windows: [OverviewWindow]
    /// The workspace this display is showing.
    public var current: Int
    public var settings: OverviewSettings
    public var metrics: OverviewMetrics
    /// A window is being dragged: workspaces `hidden` would leave out come back to drop on.
    public var dragging: Bool
    /// Tiles whose "+N" card has been opened.
    public var expanded: Set<Int>
    /// The help line takes its row.
    public var help: Bool
    /// The strip slot the pointer is over (or a drag is over): it opens to a full tile.
    public var openSlot: Int?

    public init(size: CGSize, safeTop: CGFloat = 0, screen: CGRect? = nil, windows: [OverviewWindow], current: Int,
                settings: OverviewSettings = OverviewSettings(), metrics: OverviewMetrics, dragging: Bool = false,
                expanded: Set<Int> = [], help: Bool = true, openSlot: Int? = nil) {
        self.size = size; self.safeTop = safeTop; self.windows = windows; self.current = current
        self.screen = screen ?? CGRect(origin: .zero, size: size)
        self.settings = settings; self.metrics = metrics; self.dragging = dragging
        self.expanded = expanded; self.help = help; self.openSlot = openSlot
    }
}

/// Something in the overview a key or a drop can land on.
public enum OverviewTarget: Hashable, Sendable {
    case tile(Int)
    case card(WindowID)
    /// A tile's "+N" card.
    case more(Int)
    case slot(Int)
    /// The strip's "+": the first empty workspace.
    case plus
}

public struct OverviewLayout: Equatable, Sendable {
    public struct Card: Equatable, Sendable {
        public var id: WindowID
        public var frame: CGRect
        /// Placed where its window is on the screen, not in the tidy grid.
        public var relative: Bool
    }

    /// A tile's "+N" card: the windows that didn't get a card of their own, which opens the rest in place.
    public struct More: Equatable, Sendable {
        public var frame: CGRect
        public var count: Int
        /// Already opened: the card closes it again.
        public var expanded: Bool
    }

    public struct Tile: Equatable, Sendable {
        public var n: Int
        public var frame: CGRect
        public var header: CGRect
        public var body: CGRect
        public var cards: [Card]
        public var more: More?
        public var windowCount: Int
        public var isCurrent: Bool
        /// The windows the "+N" card stands for.
        public var collapsed: [WindowID]
    }

    public struct Slot: Equatable, Sendable {
        /// The workspace; nil for the strip's "+".
        public var n: Int?
        public var frame: CGRect
        /// The full tile it opens to under the pointer.
        public var opened: CGRect?
        public var isCurrent: Bool
    }

    public var size: CGSize
    public var tiles: [Tile]
    public var slots: [Slot]
    public var strip: CGRect?
    public var help: CGRect?
    /// The empty workspace the strip's "+" moves a window to.
    public var plusTarget: Int?
    public var settings: OverviewSettings

    // MARK: Lookups

    public func tile(_ n: Int) -> Tile? { tiles.first { $0.n == n } }
    public func slot(_ n: Int) -> Slot? { slots.first { $0.n == n } }
    public var cards: [Card] { tiles.flatMap(\.cards) }

    /// Every workspace a click or a drop reaches: a tile or a strip slot.
    public var reachable: Set<Int> { Set(tiles.map(\.n)).union(slots.compactMap(\.n)) }

    public func card(_ id: WindowID) -> (card: Card, workspace: Int)? {
        for t in tiles { if let c = t.cards.first(where: { $0.id == id }) { return (c, t.n) } }
        return nil
    }

    /// Where a target is, for the arrow keys and for motion.
    public func frame(of target: OverviewTarget) -> CGRect? {
        switch target {
        case .tile(let n): return tile(n)?.frame ?? slot(n)?.frame
        case .card(let id): return card(id)?.card.frame
        case .more(let n): return tile(n)?.more?.frame
        case .slot(let n): return slot(n)?.frame
        case .plus: return slots.first { $0.n == nil }?.frame
        }
    }

    /// Everything the arrow keys can stop on, in reading order.
    public var targets: [(target: OverviewTarget, frame: CGRect)] {
        var out: [(OverviewTarget, CGRect)] = []
        for t in tiles {
            out.append((.tile(t.n), t.header))
            for c in t.cards { out.append((.card(c.id), c.frame)) }
            if let m = t.more { out.append((.more(t.n), m.frame)) }
        }
        for s in slots { out.append((s.n.map { .slot($0) } ?? .plus, s.frame)) }
        return out
    }

    /// The workspace a window dropped at `p` goes to: the tile or strip slot under it (a slot
    /// opened under the pointer counts as the whole tile it opened to), the "+" meaning the first
    /// empty workspace. Nil over nothing, and over the workspace it came from.
    public func dropTarget(at p: CGPoint, from: Int?) -> Int? {
        let hit = workspace(at: p)
        return hit == from ? nil : hit
    }

    /// The workspace whose tile or slot is under `p`.
    public func workspace(at p: CGPoint) -> Int? {
        for s in slots {
            let area = s.opened ?? s.frame
            if area.contains(p) { return s.n ?? plusTarget }
        }
        return tiles.first { $0.frame.contains(p) }?.n
    }

    /// The strip slot under `p` (never the "+"), which opens to a full tile.
    public func slotNumber(at p: CGPoint) -> Int? {
        for s in slots { if let n = s.n, (s.opened ?? s.frame).contains(p) { return n } }
        return nil
    }

    // MARK: The checks the tests hold every layout to

    /// Why this layout breaks the spec, if it does: a clipped or overlapping card, a tile off the
    /// screen, a window with no card and no "+N", a workspace nobody can reach.
    public func violations(windows: [OverviewWindow]) -> [String] {
        var out: [String] = []
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -0.01, dy: -0.01)
        func inside(_ r: CGRect, _ of: CGRect, _ what: String) {
            if r.minX < of.minX - 0.01 || r.minY < of.minY - 0.01 || r.maxX > of.maxX + 0.01 || r.maxY > of.maxY + 0.01 {
                out.append("\(what) \(r) is outside \(of)")
            }
            if !(r.width > 0 && r.height > 0) { out.append("\(what) \(r) has no size") }
        }
        for t in tiles {
            inside(t.frame, bounds, "tile \(t.n)")
            for c in t.cards { inside(c.frame, t.body, "card \(c.id) of tile \(t.n)") }
            if let m = t.more { inside(m.frame, t.body, "+N of tile \(t.n)") }
            let items = t.cards.map(\.frame) + (t.more.map { [$0.frame] } ?? [])
            for (a, b) in items.enumerated() { for c in items[(a + 1)...] where b.intersects(c.insetBy(dx: 0.01, dy: 0.01)) {
                out.append("tile \(t.n): cards \(b) and \(c) overlap")
            } }
        }
        for (a, x) in tiles.enumerated() { for y in tiles[(a + 1)...] where x.frame.intersects(y.frame.insetBy(dx: 0.01, dy: 0.01)) {
            out.append("tiles \(x.n) and \(y.n) overlap")
        } }
        for s in slots { inside(s.frame, bounds, "slot \(s.n.map(String.init) ?? "+")"); if let o = s.opened { inside(o, bounds, "opened slot") } }
        for s in slots { for t in tiles where s.frame.intersects(t.frame.insetBy(dx: 0.01, dy: 0.01)) { out.append("slot \(s.n ?? 0) overlaps tile \(t.n)") } }
        if let h = help { inside(h, bounds, "help"); for t in tiles where h.intersects(t.frame) { out.append("help overlaps tile \(t.n)") } }
        // Every window is a card or stands behind a "+N".
        let shown = Set(tiles.flatMap { $0.cards.map(\.id) + $0.collapsed })
        for w in windows where Workspaces.range.contains(w.workspace) && !shown.contains(w.id) { out.append("window \(w.id) isn't shown") }
        for t in tiles {
            let mine = windows.filter { $0.workspace == t.n }.count
            if t.cards.count + t.collapsed.count != mine { out.append("tile \(t.n) shows \(t.cards.count + t.collapsed.count) of \(mine) windows") }
        }
        return out
    }
}

// MARK: - Building a layout

extension OverviewLayout {
    /// The most a card's height may be, as a share of the display: a lone window isn't blown up to the screen.
    static let tallestCard: CGFloat = 0.62
    static let moreAspect: CGFloat = 1.5

    public static func make(_ i: OverviewInput) -> OverviewLayout {
        let m = i.metrics
        let range = Workspaces.range
        let current = range.contains(i.current) ? i.current : 1
        var byWorkspace: [Int: [OverviewWindow]] = [:]
        for w in i.windows where range.contains(w.workspace) { byWorkspace[w.workspace, default: []].append(w) }
        let count = { (n: Int) in byWorkspace[n]?.count ?? 0 }
        let occupied = range.filter { count($0) > 0 }
        let firstEmpty = range.first { count($0) == 0 }

        // Which workspaces get a tile and which a slot in the strip.
        var tileNumbers: [Int]
        var slotNumbers: [Int]
        let allTiles = i.settings.layout == .grid || i.settings.empty == .full
        if allTiles {
            tileNumbers = Array(range); slotNumbers = []
        } else {
            tileNumbers = occupied.isEmpty ? [current] : occupied
            slotNumbers = range.filter { !tileNumbers.contains($0) }
            if i.settings.empty == .hidden && !i.dragging { slotNumbers = [] }
        }
        let hasPlus = !slotNumbers.isEmpty && firstEmpty != nil

        // The rows the screen is split into: the tiles, the strip, the help line.
        let size = CGSize(width: max(1, i.size.width), height: max(1, i.size.height))
        var area = CGRect(x: m.outer, y: i.safeTop + m.outer, width: max(1, size.width - 2 * m.outer),
                          height: max(1, size.height - i.safeTop - 2 * m.outer))
        var helpRect: CGRect?
        if i.help {
            let h = min(m.help, area.height / 6)
            helpRect = CGRect(x: area.minX, y: area.maxY - h, width: area.width, height: h)
            area.size.height = max(1, area.height - h - m.stripGap)
        }
        var slots: [Slot] = []
        var stripRect: CGRect?
        if !slotNumbers.isEmpty {
            let items = slotNumbers.count + (hasPlus ? 1 : 0)
            let side = max(8, min(m.slot, (area.width - CGFloat(items - 1) * m.stripGap) / CGFloat(items), area.height / 6))
            let total = CGFloat(items) * side + CGFloat(items - 1) * m.stripGap
            let y = area.maxY - side
            var x = area.midX - total / 2
            for n in slotNumbers + (hasPlus ? [0] : []) {
                slots.append(Slot(n: n == 0 ? nil : n, frame: CGRect(x: x, y: y, width: side, height: side), opened: nil, isCurrent: n == current))
                x += side + m.stripGap
            }
            stripRect = CGRect(x: area.midX - total / 2, y: y, width: total, height: side)
            area.size.height = max(1, y - m.tileGap - area.minY)
        }

        // The tiles.
        let tileFrames = arrange(tileNumbers: tileNumbers, count: count, byWorkspace: byWorkspace, area: area, input: i)
        var tiles: [Tile] = []
        for n in tileNumbers {
            guard let frame = tileFrames[n] else { continue }
            tiles.append(fill(tile: n, frame: frame, windows: byWorkspace[n] ?? [], input: i, isCurrent: n == current))
        }

        let made = OverviewLayout(size: size, tiles: tiles, slots: slots, strip: stripRect, help: helpRect,
                                  plusTarget: hasPlus ? firstEmpty : nil, settings: i.settings)
        return made.opening(slot: i.openSlot, safeTop: i.safeTop)
    }

    /// This layout with strip slot `n` (and no other) opened to a full tile above the strip: what the
    /// pointer or a dragged window does to a slot. Nothing else moves.
    public func opening(slot n: Int?, safeTop: CGFloat = 0) -> OverviewLayout {
        var out = self
        for k in out.slots.indices { out.slots[k].opened = nil }
        guard let n, let k = out.slots.firstIndex(where: { $0.n == n }) else { return out }
        let s = out.slots[k].frame
        let w = min(max(s.width * 3.2, 1), size.width), h = min(max(s.height * 2.4, 1), size.height)
        let x = min(max(s.midX - w / 2, 0), size.width - w)
        let top = max(safeTop, s.maxY - h)
        out.slots[k].opened = CGRect(x: x, y: top, width: w, height: max(1, s.maxY - top))
        return out
    }

    /// A window's frame on display `from` as it sits on display `to`: the same share of the screen, so a
    /// window on the other monitor still lands in the right place on this one. Frames come back
    /// in `to`'s own coordinates (its top-left is 0, 0).
    public static func map(_ f: CGRect, from: CGRect, to: CGRect) -> CGRect {
        guard from.width > 0, from.height > 0 else { return f }
        let sx = to.width / from.width, sy = to.height / from.height
        return CGRect(x: (f.minX - from.minX) * sx, y: (f.minY - from.minY) * sy, width: f.width * sx, height: f.height * sy)
    }

    // MARK: Tile arrangement

    /// Splits `area` among the tiles: each takes room in proportion to its windows (equal in grid
    /// mode). Cards scale down to fit first; a tile whose cards would be smaller than they can be
    /// read grows next, and the others shrink to make the room.
    private static func arrange(tileNumbers: [Int], count: (Int) -> Int, byWorkspace: [Int: [OverviewWindow]],
                                area: CGRect, input i: OverviewInput) -> [Int: CGRect] {
        let m = i.metrics
        guard !tileNumbers.isEmpty else { return [:] }
        if i.settings.layout == .grid {
            return gridRects(tileNumbers: tileNumbers, area: area, gap: m.tileGap)
        }
        let biggest = Double(max(1, tileNumbers.map(count).max() ?? 1))
        let floorWeight = biggest * 0.25
        var base: [Int: Double] = [:]
        for n in tileNumbers { base[n] = max(Double(count(n)), floorWeight) }
        // What each tile must hold: its cards, the "+N" in place of the rest.
        func items(_ n: Int) -> [CGFloat] {
            let list = byWorkspace[n] ?? []
            let shown = visible(list, expanded: i.expanded.contains(n), cap: m.cap)
            var a = shown.cards.map { aspect(of: $0.frame) }
            if shown.hasMore { a.append(moreAspect) }
            return a
        }
        let aspects = Dictionary(uniqueKeysWithValues: tileNumbers.map { ($0, items($0)) })
        let tallest = i.screen.height * tallestCard

        var boost: [Int: Double] = [:]
        var best = bestArrangement(tileNumbers, weights: base, boost: boost, aspects: aspects, area: area, input: i, tallest: tallest)
        for _ in 0..<14 {
            // The tile most short of room, if any is below the size cards are read at.
            var worst: (n: Int, ratio: CGFloat)?
            for n in tileNumbers where !(aspects[n] ?? []).isEmpty {
                guard let r = best.rects[n], (boost[n] ?? 1) < 12, r.width * r.height < area.width * area.height * 0.8 else { continue }
                let h = commonHeight(aspects[n] ?? [], in: bodySize(of: r, metrics: m), gap: m.cardGap, tallest: tallest)
                let ratio = h / m.minCardHeight
                if ratio < 1, ratio < (worst?.ratio ?? 1) { worst = (n, ratio) }
            }
            guard let w = worst else { break }
            boost[w.n, default: 1] *= 1.3
            best = bestArrangement(tileNumbers, weights: base, boost: boost, aspects: aspects, area: area, input: i, tallest: tallest)
        }
        return best.rects
    }

    private static func gridRects(tileNumbers: [Int], area: CGRect, gap: CGFloat) -> [Int: CGRect] {
        let cols = tileNumbers.count > 6 ? 3 : tileNumbers.count > 2 ? 2 : tileNumbers.count
        let rows = (tileNumbers.count + cols - 1) / cols
        let w = (area.width - CGFloat(cols - 1) * gap) / CGFloat(cols)
        let h = (area.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
        var out: [Int: CGRect] = [:]
        for (k, n) in tileNumbers.enumerated() {
            out[n] = CGRect(x: area.minX + CGFloat(k % cols) * (w + gap), y: area.minY + CGFloat(k / cols) * (h + gap), width: w, height: h)
        }
        return out
    }

    /// The row split of the tiles (contiguous, in workspace order, up to three rows) whose
    /// hardest-pressed tile has the biggest cards.
    private static func bestArrangement(_ numbers: [Int], weights: [Int: Double], boost: [Int: Double], aspects: [Int: [CGFloat]],
                                        area: CGRect, input i: OverviewInput, tallest: CGFloat) -> (rects: [Int: CGRect], score: CGFloat) {
        let m = i.metrics
        let k = numbers.count
        let w = numbers.map { (weights[$0] ?? 1) * (boost[$0] ?? 1) }
        var best: (rects: [Int: CGRect], score: CGFloat)?
        // Every way to cut the run of tiles into at most three rows: a bit mask of the k-1 gaps.
        for mask in 0..<(1 << (k - 1)) where mask.nonzeroBitCount < 3 {
            var rows: [[Int]] = [[0]]
            for j in 1..<max(k, 1) {
                if mask & (1 << (j - 1)) != 0 { rows.append([j]) } else { rows[rows.count - 1].append(j) }
            }
            let rects = rowRects(rows, numbers: numbers, weights: w, area: area, gap: m.tileGap)
            var score = CGFloat.greatestFiniteMagnitude
            for (j, n) in numbers.enumerated() {
                guard let r = rects[j], let a = aspects[n], !a.isEmpty else { continue }
                score = min(score, commonHeight(a, in: bodySize(of: r, metrics: m), gap: m.cardGap, tallest: tallest))
            }
            // A tile that hasn't a card needs only its header.
            if score == .greatestFiniteMagnitude { score = area.height }
            if best == nil || score > best!.score + 0.5 {
                var out: [Int: CGRect] = [:]
                for (j, n) in numbers.enumerated() { out[n] = rects[j] }
                best = (out, score)
            }
        }
        return best ?? ([:], 0)
    }

    private static func rowRects(_ rows: [[Int]], numbers: [Int], weights: [Double], area: CGRect, gap: CGFloat) -> [Int: CGRect] {
        let total = rows.map { $0.map { weights[$0] }.reduce(0, +) }.reduce(0, +)
        let usableH = max(1, area.height - CGFloat(rows.count - 1) * gap)
        var out: [Int: CGRect] = [:]
        var y = area.minY
        for row in rows {
            let rowWeight = row.map { weights[$0] }.reduce(0, +)
            let h = usableH * CGFloat(rowWeight / total)
            let usableW = max(1, area.width - CGFloat(row.count - 1) * gap)
            var x = area.minX
            for j in row {
                let w = usableW * CGFloat(weights[j] / rowWeight)
                out[j] = CGRect(x: x, y: y, width: w, height: h)
                x += w + gap
            }
            y += h + gap
        }
        return out
    }

    private static func bodySize(of tile: CGRect, metrics m: OverviewMetrics) -> CGSize {
        CGSize(width: max(1, tile.width - 2 * m.tilePadding), height: max(1, tile.height - 2 * m.tilePadding - m.header))
    }

    // MARK: Cards

    /// A window's width over its height, held to what a card can sensibly be.
    static func aspect(of frame: CGRect?) -> CGFloat {
        guard let f = frame, f.width > 1, f.height > 1 else { return 1.6 }
        return min(2.4, max(0.5, f.width / f.height))
    }

    /// The windows that get a card, and whether a "+N" stands for the rest. The smallest windows are the ones collapsed.
    static func visible(_ list: [OverviewWindow], expanded: Bool, cap: Int) -> (cards: [OverviewWindow], collapsed: [OverviewWindow], hasMore: Bool) {
        guard list.count > cap else { return (list, [], false) }
        if expanded { return (list, [], true) }
        let keep = cap - 1
        let ranked = list.enumerated().sorted { a, b in
            let aa = a.element.frame.map { $0.width * $0.height } ?? 0, bb = b.element.frame.map { $0.width * $0.height } ?? 0
            return aa != bb ? aa > bb : a.offset < b.offset
        }
        let kept = Set(ranked.prefix(keep).map(\.offset))
        let cards = list.enumerated().filter { kept.contains($0.offset) }.map(\.element)
        let collapsed = list.enumerated().filter { !kept.contains($0.offset) }.map(\.element)
        return (cards, collapsed, true)
    }

    /// The biggest height every card of a tile can share in `body`, packed in rows: an estimate that
    /// is cheap enough to try many arrangements with (`pack` makes the real frames).
    static func commonHeight(_ aspects: [CGFloat], in body: CGSize, gap: CGFloat, tallest: CGFloat) -> CGFloat {
        guard !aspects.isEmpty else { return min(body.height, tallest) }
        var prefix = [CGFloat](repeating: 0, count: aspects.count + 1)
        for (k, a) in aspects.enumerated() { prefix[k + 1] = prefix[k] + a }
        var best: CGFloat = 0
        for rows in 1...min(aspects.count, 8) {
            let per = (aspects.count + rows - 1) / rows
            var widest: CGFloat = 0
            var start = 0
            while start < aspects.count {
                let end = min(start + per, aspects.count)
                widest = max(widest, prefix[end] - prefix[start])
                start = end
            }
            let byWidth = (body.width - CGFloat(per - 1) * gap) / max(widest, 0.01)
            let byHeight = (body.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
            best = max(best, min(byWidth, byHeight, tallest))
        }
        return best
    }

    /// The cards of one tile packed in justified rows at the biggest common height that fits, each at its window's aspect.
    /// The block is centered in `body`. Every card is inside `body` at any count: a height that is too much just shrinks.
    static func pack(_ aspects: [CGFloat], in body: CGRect, gap: CGFloat, tallest: CGFloat) -> [CGRect] {
        guard !aspects.isEmpty else { return [] }
        func flow(_ h: CGFloat) -> (rows: [[Int]], fits: Bool) {
            var rows: [[Int]] = [[]]
            var x: CGFloat = 0
            for (k, a) in aspects.enumerated() {
                let w = a * h
                if w > body.width + 0.001 { return ([], false) }
                if !rows[rows.count - 1].isEmpty && x + gap + w > body.width + 0.001 { rows.append([]); x = 0 }
                x += (rows[rows.count - 1].isEmpty ? 0 : gap) + w
                rows[rows.count - 1].append(k)
            }
            return (rows, CGFloat(rows.count) * h + CGFloat(rows.count - 1) * gap <= body.height + 0.001)
        }
        var lo: CGFloat = 0.5, hi = min(body.height, tallest)
        if hi < lo { hi = lo }
        if flow(hi).fits { lo = hi } else {
            for _ in 0..<28 {
                let mid = (lo + hi) / 2
                if flow(mid).fits { lo = mid } else { hi = mid }
            }
        }
        var (rows, fits) = flow(lo)
        var h = lo
        // Below half a point even one row can overflow a sliver tile; shrink until it fits, never past nothing.
        while !fits && h > 0.01 { h *= 0.9; (rows, fits) = flow(h) }
        if !fits { rows = aspects.indices.map { [$0] } }
        let totalH = CGFloat(rows.count) * h + CGFloat(rows.count - 1) * gap
        var y = body.minY + max(0, (body.height - totalH) / 2)
        var frames = [CGRect](repeating: .zero, count: aspects.count)
        for row in rows {
            let rowW = row.map { aspects[$0] * h }.reduce(0, +) + CGFloat(row.count - 1) * gap
            var x = body.minX + max(0, (body.width - rowW) / 2)
            for k in row {
                frames[k] = CGRect(x: x, y: y, width: aspects[k] * h, height: h)
                x += aspects[k] * h + gap
            }
            y += h + gap
        }
        return frames
    }

    /// Cards where their windows are on the screen, if that reads: every window's place is known,
    /// the cards neither touch nor shrink past reading, and none is far smaller than the tidy grid's.
    static func relativeFrames(_ list: [OverviewWindow], screen: CGRect, body: CGRect, gap: CGFloat, floor: CGFloat) -> [CGRect]? {
        guard list.count >= 1, screen.width > 1, screen.height > 1, body.width > 1, body.height > 1 else { return nil }
        var visible: [CGRect] = []
        for w in list {
            guard let f = w.frame, f.width > 1, f.height > 1 else { return nil }
            let v = f.intersection(screen)
            // A window mostly off its display (parked) says nothing about where it belongs.
            guard !v.isNull, v.width * v.height >= f.width * f.height * 0.5 else { return nil }
            visible.append(v)
        }
        let s = min(body.width / screen.width, body.height / screen.height)
        let ox = body.midX - screen.width * s / 2 - screen.minX * s
        let oy = body.midY - screen.height * s / 2 - screen.minY * s
        let frames = visible.map { v in
            CGRect(x: v.minX * s + ox, y: v.minY * s + oy, width: v.width * s, height: v.height * s).insetBy(dx: gap / 2, dy: gap / 2)
        }
        for (a, f) in frames.enumerated() {
            guard f.width >= floor * 0.9, f.height >= floor * 0.6, body.insetBy(dx: -0.01, dy: -0.01).contains(f) else { return nil }
            for g in frames[(a + 1)...] where f.intersects(g) { return nil }
        }
        return frames
    }

    private static func fill(tile n: Int, frame: CGRect, windows list: [OverviewWindow], input i: OverviewInput, isCurrent: Bool) -> Tile {
        let m = i.metrics
        let inner = frame.insetBy(dx: m.tilePadding, dy: m.tilePadding)
        let header = CGRect(x: inner.minX, y: inner.minY, width: max(1, inner.width), height: min(m.header, max(1, inner.height)))
        let body = CGRect(x: inner.minX, y: header.maxY, width: max(1, inner.width), height: max(1, inner.maxY - header.maxY))
        let shown = visible(list, expanded: i.expanded.contains(n), cap: m.cap)
        let tallest = i.screen.height * tallestCard

        var cards: [Card] = []
        var more: More?
        if !shown.cards.isEmpty {
            let aspects = shown.cards.map { aspect(of: $0.frame) } + (shown.hasMore ? [moreAspect] : [])
            let grid = pack(aspects, in: body, gap: m.cardGap, tallest: tallest)
            // Where the windows are on the screen, when that reads at least as well as the grid.
            var frames = Array(grid.prefix(shown.cards.count))
            var relative = false
            if !shown.hasMore, let rel = relativeFrames(shown.cards, screen: i.screen, body: body, gap: m.cardGap, floor: (grid.first?.height ?? m.minCardHeight) * 0.75) {
                frames = rel; relative = true
            }
            for (k, w) in shown.cards.enumerated() { cards.append(Card(id: w.id, frame: frames[k], relative: relative)) }
            if shown.hasMore, let last = grid.last {
                more = More(frame: last, count: shown.collapsed.count + (i.expanded.contains(n) ? list.count - m.cap + 1 : 0), expanded: i.expanded.contains(n))
            }
        }
        return Tile(n: n, frame: frame, header: header, body: body, cards: cards, more: more, windowCount: list.count,
                    isCurrent: isCurrent, collapsed: shown.collapsed.map(\.id))
    }
}

// MARK: - The arrow keys

public enum OverviewDirection: Sendable { case left, right, up, down }

public enum OverviewNav {
    /// The target one arrow press from `from`: the nearest in that direction, with a sideways
    /// miss counting against it. Stays where it is at an edge.
    public static func move(from: OverviewTarget?, _ d: OverviewDirection, in layout: OverviewLayout, current: Int) -> OverviewTarget? {
        let all = layout.targets
        guard let start = from ?? .tile(current) as OverviewTarget?,
              let here = layout.frame(of: start).map({ r -> CGRect in
                  if case .tile(let n) = start, let t = layout.tile(n) { return t.header }
                  return r
              }) ?? all.first?.frame else { return all.first?.target }
        // The nearest in the direction, preferring one in the same row (or column) over one that
        // is merely closer: a sideways miss counts against it.
        var best: (target: OverviewTarget, cost: CGFloat)?
        for (target, frame) in all where target != start {
            let dx = frame.midX - here.midX, dy = frame.midY - here.midY
            let along: CGFloat, across: CGFloat, together: Bool
            switch d {
            case .right: along = dx; across = abs(dy); together = frame.minY < here.maxY && frame.maxY > here.minY
            case .left: along = -dx; across = abs(dy); together = frame.minY < here.maxY && frame.maxY > here.minY
            case .down: along = dy; across = abs(dx); together = frame.minX < here.maxX && frame.maxX > here.minX
            case .up: along = -dy; across = abs(dx); together = frame.minX < here.maxX && frame.maxX > here.minX
            }
            guard along > 1 else { continue }
            let cost = along + across * 2.5 + (together ? 0 : 1_000_000)
            if best == nil || cost < best!.cost { best = (target, cost) }
        }
        return best?.target ?? start
    }
}
