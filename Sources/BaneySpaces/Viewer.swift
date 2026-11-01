import AppKit
import BaneySpacesCore
import SwiftUI
import UniformTypeIdentifiers

/// The overview (spec/overview.md): all nine workspaces at once, in place of Mission Control. The
/// layout (`OverviewLayout`) says where every tile, card and strip slot goes and never clips; this
/// file draws it, takes the keys, the mouse and the drag, and finds windows by typing.
final class ViewerModel: ObservableObject {
    /// A window card being dragged: what it is, where it came from, where the cursor is.
    struct Drag {
        let entry: Spaces.Entry
        let from: Int
        var location: CGPoint
    }

    @Published var current = 1
    @Published var tiles: [Int: [Spaces.Entry]] = [:]
    /// What was typed to find a window.
    @Published var query = ""
    /// What the arrow keys picked. Kept apart from `hovered`: only the pointer entering something takes over from it.
    @Published var keyed: OverviewTarget?
    @Published var hovered: OverviewTarget?
    @Published var drag: Drag?
    /// The drag is a real window carried up from the desktop by its title bar, not a card
    /// picked up here; the pointer belongs to that drag, so the viewer only watches it.
    @Published var carrying = false
    /// Live previews by window id.
    @Published var previews: [WindowID: NSImage] = [:]
    /// Tiles whose "+N" card was opened.
    @Published var expanded: Set<Int> = []
    /// The strip slot the pointer (or a drag) is over, open to a full tile.
    @Published var openSlot: Int?
    @Published var help = OverviewHelp()
    /// While the snapshot layers carry the cards in or out, the cards themselves wait.
    @Published var cardsHidden = false
    var settings = OverviewSettings()
    /// Icons supplied directly, for rendered product images with sample windows.
    var icons: [WindowID: NSImage] = [:]
    /// The agent on each window, for its badge.
    var agents: [WindowID: DockAgent] = [:]
    /// This display's name, and the workspaces other displays are showing with those displays' names.
    var displayName: String?
    var otherDisplays: [Int: String] = [:]
    var safeTop: CGFloat = 0
    var onPick: (Int) -> Void = { _ in }
    var onPickWindow: (WindowID, Int) -> Void = { _, _ in }
    /// A window moved to a workspace; true when Option was held, to follow it.
    var onMove: (WindowID, Int, Bool) -> Void = { _, _, _ in }
    var onClose: () -> Void = {}
    var onCloseWindow: (WindowID, Int) -> Void = { _, _ in }
    /// A strip slot clicked, or "+" pressed on a selected tile: open something on that workspace (the launcher's open-here).
    var onOpenHere: (Int, String?) -> Void = { _, _ in }

    // MARK: Layout

    private var cache: (input: OverviewInput, layout: OverviewLayout)?
    /// The layout drawn last: what hit tests and drops are answered from.
    private(set) var lastLayout: OverviewLayout?

    var windows: [OverviewWindow] {
        Workspaces.range.flatMap { n in (tiles[n] ?? []).map { OverviewWindow(id: $0.id, workspace: n, frame: $0.frame) } }
    }

    func layout(for size: CGSize) -> OverviewLayout {
        let input = OverviewInput(size: size, safeTop: safeTop, screen: CGRect(origin: .zero, size: size), windows: windows, current: current,
                                  settings: settings, metrics: OverviewMetrics.make(spec: Chrome.spec), dragging: drag != nil || carrying,
                                  expanded: expanded, help: help.visible, openSlot: nil)
        let base: OverviewLayout
        if let c = cache, c.input == input { base = c.layout } else { base = OverviewLayout.make(input); cache = (input, base) }
        let l = base.opening(slot: openSlot, safeTop: safeTop)
        lastLayout = l
        return l
    }

    func entry(_ id: WindowID) -> Spaces.Entry? {
        for list in tiles.values { if let e = list.first(where: { $0.id == id }) { return e } }
        return nil
    }

    // MARK: Type to find

    var filter: OverviewFilter {
        OverviewFilter(Workspaces.range.flatMap { n in (tiles[n] ?? []).map { OverviewFilter.Item(id: $0.id, workspace: n, app: $0.app, title: $0.title) } })
    }

    private var filterCache: (stamp: [WindowID], filter: OverviewFilter)?
    /// The windows `query` matches; nil with no query.
    var found: OverviewFilter.Result? {
        guard !query.isEmpty else { return nil }
        let stamp = windows.map(\.id)
        let f: OverviewFilter
        if let c = filterCache, c.stamp == stamp { f = c.filter } else { f = filter; filterCache = (stamp, f) }
        return f.match(query, prefer: current)
    }

    /// Where Return goes: the best match while typing, else what the keys or the pointer picked.
    var highlighted: OverviewTarget? {
        if let best = found?.best { return .card(best) }
        return keyed ?? hovered
    }

    // MARK: Actions

    /// Forget anything left from the last time the viewer was open.
    func reset() {
        drag = nil
        carrying = false
        hovered = nil
        keyed = nil
        query = ""
        expanded = []
        openSlot = nil
        cardsHidden = false
    }

    func hover(_ target: OverviewTarget?, _ inside: Bool) {
        if inside { hovered = target; keyed = nil } else if hovered == target { hovered = nil }
        if drag == nil {
            if inside, case .slot(let n)? = target { openSlot = n }
            else if !inside, case .slot(let n)? = target, openSlot == n { openSlot = nil }
        }
    }

    /// Return, or a click on what's selected: where it goes.
    func activate(_ target: OverviewTarget) {
        switch target {
        case .tile(let n), .slot(let n): onPick(n)
        case .card(let id): if let n = workspace(of: id) { onPickWindow(id, n) }
        case .more(let n): expanded.formSymmetricDifference([n])
        case .plus: if let n = lastLayout?.plusTarget { onPick(n) }
        }
    }

    func workspace(of id: WindowID) -> Int? { Workspaces.range.first { n in (tiles[n] ?? []).contains { $0.id == id } } }

    /// The window under `p`, for a middle click.
    func card(at p: CGPoint) -> (id: WindowID, workspace: Int)? {
        guard let l = lastLayout else { return nil }
        for t in l.tiles { if let c = t.cards.first(where: { $0.frame.contains(p) }) { return (c.id, t.n) } }
        return nil
    }

    /// The pointer moved over a drag: the slot under it opens to a full tile.
    func dragMoved() {
        guard let d = drag, let l = lastLayout else { return }
        let slot = l.slotNumber(at: d.location)
        if slot != openSlot { openSlot = slot }
    }

    /// The workspace a dragged card would land on, if it isn't the one it came from.
    var dropTarget: Int? {
        guard let drag, let l = lastLayout else { return nil }
        return l.dropTarget(at: drag.location, from: drag.from)
    }

    func endDrag(follow: Bool = false) {
        guard let drag else { return }
        if let to = dropTarget {
            // Show the result right away; the real move follows a moment later.
            tiles[drag.from]?.removeAll { $0.id == drag.entry.id }
            tiles[to, default: []].append(drag.entry)
            onMove(drag.entry.id, to, follow)
        }
        withAnimation(Chrome.ease(0.15, .panelOut)) { self.drag = nil }
        openSlot = nil
    }

    /// Sets what each window's card draws (a preview, if there is one).
    func image(for e: Spaces.Entry) -> NSImage? { icons[e.id] ?? NSRunningApplication(processIdentifier: e.pid)?.icon }
}

struct ViewerView: View {
    @ObservedObject var model: ViewerModel
    /// Redraws when Settings › Appearance changes.
    @ObservedObject private var appearance = Appearance.shared
    /// Rendered images can't capture a live blur, so they draw a still backdrop instead.
    var stillBackdrop = false
    private var accent: Color { Chrome.themeAccent }
    /// Panel style and opacity are the BaneySpaces theme's; a theme with one fill ignores them.
    private var adjustable: Bool { Chrome.spec.fill.adjustable }

    // The body is split into small pieces so every Swift compiler type-checks it quickly.
    var body: some View {
        ZStack {
            backdrop
            // Clicking the backdrop closes the viewer, like clicking the desktop in Mission Control.
            Chrome.black(adjustable ? appearance.settings.overviewDim : AppearanceSettings().overviewDim)
                .ignoresSafeArea().onTapGesture { model.onClose() }
            if adjustable && appearance.settings.panelStyle == .tinted {
                Chrome.accent.opacity(AppearanceSettings.tintWash).ignoresSafeArea().allowsHitTesting(false)
            }
            GeometryReader { g in content(model.layout(for: g.size)) }
            liftedCard
        }
        .ignoresSafeArea()
        .coordinateSpace(name: "viewer")
        .environment(\.colorScheme, Chrome.scheme)
    }

    @ViewBuilder private var backdrop: some View {
        if (adjustable && appearance.settings.panelStyle == .solid) || (!Chrome.spec.fill.blur && !stillBackdrop) {
            Chrome.panel().ignoresSafeArea()
        } else if stillBackdrop {
            Chrome.stillBackdrop
        } else {
            Backdrop().ignoresSafeArea()
        }
    }

    // MARK: The layout, drawn

    private func content(_ layout: OverviewLayout) -> some View {
        let found = model.found
        return ZStack(alignment: .topLeading) {
            ForEach(layout.tiles, id: \.n) { tile in tileView(tile) }
            ForEach(layout.tiles, id: \.n) { tile in
                ForEach(tile.cards, id: \.id) { card in cardView(card, workspace: tile.n, found: found) }
                if let more = tile.more { moreCard(more, workspace: tile.n) }
            }
            if let strip = layout.strip { stripBackdrop(strip) }
            ForEach(Array(layout.slots.enumerated()), id: \.offset) { _, slot in slotView(slot, layout: layout) }
            ForEach(Array(layout.slots.enumerated()), id: \.offset) { _, slot in openedSlotView(slot) }
            if let rect = layout.help, model.help.visible { helpLine.placed(rect) }
            findBar(found: found, layout: layout)
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }

    private func stripBackdrop(_ strip: CGRect) -> some View { Color.clear.placed(strip).allowsHitTesting(false) }

    private func tileView(_ tile: OverviewLayout.Tile) -> some View {
        let target = OverviewTarget.tile(tile.n)
        let selected = model.drag == nil && model.highlighted == target
        let isTarget = model.dropTarget == tile.n
        let other = model.otherDisplays[tile.n]
        return ZStack(alignment: .topLeading) {
            tileShape(isCurrent: tile.isCurrent, isTarget: isTarget, isSelected: selected)
                .contentShape(Chrome.shape(.overviewTile, continuous: false))
                .onTapGesture { model.onPick(tile.n) }
                .onHover { model.hover(target, $0) }
            tileHeader(tile, selected: selected || isTarget, other: other).placed(tile.header, in: tile.frame)
            if isTarget { moveHere.placed(tile.body, in: tile.frame) }
            if tile.windowCount == 0 { emptyLabel.placed(tile.body, in: tile.frame) }
        }
        .frame(width: tile.frame.width, height: tile.frame.height, alignment: .topLeading)
        .opacity(other == nil ? 1 : 0.55)
        .placed(tile.frame)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tileLabel(tile))
    }

    private func tileLabel(_ tile: OverviewLayout.Tile) -> String {
        let apps = (model.tiles[tile.n] ?? []).map(\.app)
        return "Workspace \(tile.n)\(tile.isCurrent ? ", current" : ""), \(apps.isEmpty ? "empty" : apps.joined(separator: ", "))"
    }

    private func tileShape(isCurrent: Bool, isTarget: Bool, isSelected: Bool) -> some View {
        let mark = OverviewMark.current(Chrome.spec, theme: Chrome.theme)
        let border: Color
        if isTarget { border = Chrome.focusEdge(accent) }
        else if isCurrent { border = Chrome.focusEdge(accent) }
        else if isSelected { border = Chrome.focusEdge(accent).opacity(0.7) }
        else { border = Chrome.edge(0.08) }
        let width = isCurrent || isTarget || isSelected ? CGFloat(mark.width) : Chrome.width(.overviewTile)
        let dash: [CGFloat] = isTarget ? [8, 5] : []
        let glow = isCurrent && mark.glow
        return Chrome.shape(.overviewTile, continuous: false)
            .fill(Chrome.tileFill(target: isSelected || isTarget))
            .overlay(Chrome.shape(.overviewTile, continuous: false).strokeBorder(border, style: StrokeStyle(lineWidth: width, dash: dash)))
            .shadow(color: Chrome.shadow(glow ? 0.55 : 0, color: accent), radius: glow ? 16 : 0)
    }

    private func tileHeader(_ tile: OverviewLayout.Tile, selected: Bool, other: String?) -> some View {
        // On one baseline: centered, the small caption floats above the big number's foot.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            OverviewNumber(n: tile.n, selected: selected, large: true)
            if tile.windowCount > 0 {
                Text(tile.windowCount == 1 ? "1 window" : "\(tile.windowCount) windows").font(Chrome.font(10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let other { Text(other).font(Chrome.font(10)).foregroundStyle(.secondary).lineLimit(1) }
        }
        .allowsHitTesting(false)
    }

    private var emptyLabel: some View {
        Text("Empty").font(Chrome.font(12)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
    }

    private var moveHere: some View {
        Text("Move here").font(Chrome.font(12, .semibold)).foregroundStyle(accent).frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
    }

    // MARK: Cards

    /// A window card in a tile. Click it to go to that window; drag it to another workspace.
    private func cardView(_ card: OverviewLayout.Card, workspace n: Int, found: OverviewFilter.Result?) -> some View {
        let e = model.entry(card.id)
        let target = OverviewTarget.card(card.id)
        let beingDragged = model.drag?.entry.id == card.id
        let lit = found?.matches(card.id) ?? true
        let selected = model.drag == nil && model.highlighted == target
        return Group {
            if let e {
                self.card(e, size: card.frame.size, selected: selected, lifted: false)
                    .opacity(beingDragged ? 0.3 : (lit ? 1 : OverviewFilter.dimmedOpacity))
                    .onHover { inside in
                        model.hover(target, inside)
                        (inside ? NSCursor.openHand : NSCursor.arrow).set()
                    }
                    .gesture(
                        DragGesture(minimumDistance: 4, coordinateSpace: .named("viewer"))
                            .onChanged { v in
                                if model.drag == nil { NSCursor.closedHand.set() }
                                model.drag = ViewerModel.Drag(entry: e, from: n, location: v.location)
                                model.dragMoved()
                            }
                            .onEnded { _ in
                                NSCursor.arrow.set()
                                model.endDrag(follow: NSEvent.modifierFlags.contains(.option))
                            }
                    )
                    .simultaneousGesture(TapGesture().onEnded { model.onPickWindow(e.id, n) })
                    .accessibilityLabel("\(e.app) \(e.title)")
                    .accessibilityAddTraits(.isButton)
            }
        }
        .frame(width: card.frame.width, height: card.frame.height)
        .opacity(model.cardsHidden ? 0 : 1)
        .placed(card.frame)
    }

    private enum Detail { case full, compact, icon }

    private func detail(_ size: CGSize) -> Detail {
        if size.width >= 150 && size.height >= 100 { return .full }
        if size.width >= 72 && size.height >= 44 { return .compact }
        return .icon
    }

    /// The card: a live preview at the window's shape with its icon and title, or the icon large with the title below.
    private func card(_ e: Spaces.Entry, size: CGSize, selected: Bool, lifted: Bool) -> some View {
        let shape = Chrome.shape(.overviewCard, continuous: false)
        let preview = model.previews[e.id]
        let icon = model.image(for: e)
        let agent = model.agents[e.id]
        let border: Color = selected ? Chrome.focusEdge(accent) : (agent?.state.color.opacity(0.9) ?? Chrome.edge(lifted ? 0.25 : 0.1))
        return ZStack {
            shape.fill(lifted ? Chrome.liftedFill : (selected ? Chrome.tileFill(target: true) : Chrome.cell(0.06)))
            if let preview {
                Image(nsImage: preview).resizable().aspectRatio(contentMode: .fill).frame(width: size.width, height: size.height).clipped()
                    .overlay(alignment: .bottom) { labelBar(e, icon: icon, size: size) }
            } else {
                iconCard(e, icon: icon, size: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(border, lineWidth: Chrome.width(.overviewCard, focused: selected || agent != nil)))
        .overlay(alignment: .topTrailing) {
            if let agent { AgentStatusBadge(state: agent.state, size: 16).padding(4) }
        }
        .shadow(color: Chrome.shadow(lifted ? 0.5 : 0), radius: lifted ? 14 : 0, y: lifted ? 6 : 0)
        .scaleEffect(lifted ? Chrome.grow(1.04) : 1)
    }

    /// The icon and the title over the bottom of a preview. Both ends of a long title stay readable.
    @ViewBuilder private func labelBar(_ e: Spaces.Entry, icon: NSImage?, size: CGSize) -> some View {
        if detail(size) != .icon {
            HStack(spacing: 6) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                Text(e.title.isEmpty || e.title == e.app ? e.app : e.title)
                    .font(Chrome.font(11, .medium)).foregroundStyle(Chrome.wash()).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(Chrome.shade(0.78))
        } else if let icon {
            Image(nsImage: icon).resizable().frame(width: 16, height: 16).padding(3).background(Chrome.shade(0.78))
        }
    }

    /// Without a preview: the app's icon large in the middle and the window's title below.
    private func iconCard(_ e: Spaces.Entry, icon: NSImage?, size: CGSize) -> some View {
        let d = detail(size)
        let side = min(max(min(size.width, size.height) * (d == .full ? 0.42 : 0.5), 14), 72)
        return VStack(spacing: 4) {
            Spacer(minLength: 0)
            if let icon { Image(nsImage: icon).resizable().frame(width: side, height: side) }
            if d != .icon {
                Text(e.app).font(Chrome.font(11, .medium)).foregroundStyle(Chrome.wash()).lineLimit(1).truncationMode(.middle)
                if d == .full, !e.title.isEmpty, e.title != e.app {
                    Text(e.title).font(Chrome.font(10)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(width: size.width, height: size.height)
    }

    private func moreCard(_ more: OverviewLayout.More, workspace n: Int) -> some View {
        let target = OverviewTarget.more(n)
        let selected = model.highlighted == target
        let shape = Chrome.shape(.overviewCard, continuous: false)
        return VStack(spacing: 2) {
            Text(more.expanded ? "Show fewer" : "+\(more.count)").font(Chrome.font(more.expanded ? 11 : 18, .bold)).foregroundStyle(Chrome.wash())
            if !more.expanded { Text("more").font(Chrome.font(10)).foregroundStyle(.secondary) }
        }
        .frame(width: more.frame.width, height: more.frame.height)
        .background(shape.fill(selected ? Chrome.tileFill(target: true) : Chrome.cell(0.06)))
        .overlay(shape.strokeBorder(selected ? Chrome.focusEdge(accent) : Chrome.edge(0.1), lineWidth: Chrome.width(.overviewCard, focused: selected)))
        .contentShape(shape)
        .onTapGesture { model.activate(target) }
        .onHover { model.hover(target, $0) }
        .opacity(model.cardsHidden ? 0 : 1)
        .placed(more.frame)
    }

    // MARK: The strip

    private func slotView(_ slot: OverviewLayout.Slot, layout: OverviewLayout) -> some View {
        let target: OverviewTarget = slot.n.map { .slot($0) } ?? .plus
        let selected = model.drag == nil && model.highlighted == target
        let dropOn = slot.n.map { model.dropTarget == $0 } ?? (model.dropTarget != nil && model.dropTarget == layout.plusTarget)
        let mark = OverviewMark.current(Chrome.spec, theme: Chrome.theme)
        let shape = Chrome.shape(.overviewSlot, continuous: false)
        let other = slot.n.flatMap { model.otherDisplays[$0] }
        let border: Color = slot.isCurrent || dropOn ? Chrome.focusEdge(accent) : (selected ? Chrome.focusEdge(accent).opacity(0.7) : Chrome.edge(0.1))
        let width = slot.isCurrent || dropOn || selected ? CGFloat(mark.width) : Chrome.width(.overviewSlot)
        let glow = slot.isCurrent && mark.glow
        return ZStack {
            shape.fill(Chrome.tileFill(target: selected || dropOn))
            if let n = slot.n {
                shape.fill(Chrome.workspace(n).opacity(0.22))
                OverviewNumber(n: n, selected: selected || dropOn, large: false)
            } else {
                Image(systemName: "plus").font(Chrome.font(16, .semibold)).foregroundStyle(selected || dropOn ? accent : Chrome.wash(0.7))
            }
        }
        .overlay(shape.strokeBorder(border, style: StrokeStyle(lineWidth: width, dash: dropOn ? [6, 4] : [])))
        .shadow(color: Chrome.shadow(glow ? 0.55 : 0, color: accent), radius: glow ? 12 : 0)
        .opacity(other == nil ? 1 : 0.55)
        .frame(width: slot.frame.width, height: slot.frame.height)
        .contentShape(shape)
        .onTapGesture {
            // A slot opens the launcher for that workspace; the "+" does for the first empty one.
            if let n = slot.n ?? layout.plusTarget { model.onOpenHere(n, nil) }
        }
        .onHover { model.hover(target, $0) }
        .placed(slot.frame)
        .accessibilityLabel(slot.n.map { "Workspace \($0), empty. Open an app here" } ?? "New workspace")
        .accessibilityAddTraits(.isButton)
    }

    /// A strip slot under the pointer, opened to a full tile.
    @ViewBuilder private func openedSlotView(_ slot: OverviewLayout.Slot) -> some View {
        if let n = slot.n, let rect = slot.opened {
            let dropOn = model.dropTarget == n
            let shape = Chrome.shape(.overviewTile, continuous: false)
            ZStack(alignment: .topLeading) {
                shape.fill(Chrome.tileFill(target: true))
                shape.fill(Chrome.workspace(n).opacity(0.18))
                OverviewNumber(n: n, selected: true, large: true).padding(Chrome.spec.space.padding)
                Text(dropOn || model.drag != nil ? "Move here" : "Empty · click to open an app")
                    .font(Chrome.font(11)).foregroundStyle(dropOn ? accent : Color.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(shape.strokeBorder(Chrome.focusEdge(accent), style: StrokeStyle(lineWidth: CGFloat(OverviewMark.current(Chrome.spec, theme: Chrome.theme).width), dash: dropOn ? [8, 5] : [])))
            .frame(width: rect.width, height: rect.height)
            .contentShape(shape)
            .onTapGesture { model.onOpenHere(n, nil) }
            .onHover { model.hover(.slot(n), $0) }
            .placed(rect)
        }
    }

    // MARK: Find, help, the lifted card

    private var helpLine: some View {
        Text(OverviewHelp.line).font(Chrome.font(11)).foregroundStyle(Chrome.wash(0.55)).lineLimit(1)
            .frame(maxWidth: .infinity).allowsHitTesting(false)
    }

    /// The text typed to find a window, and, when nothing matches it, the launcher's way to open it here.
    @ViewBuilder private func findBar(found: OverviewFilter.Result?, layout: OverviewLayout) -> some View {
        if !model.query.isEmpty {
            VStack(spacing: 6) {
                Text(model.query).font(Chrome.font(15, .medium)).foregroundStyle(Chrome.wash())
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Chrome.panel(0.92), in: Chrome.pill())
                    .overlay(Chrome.pill().strokeBorder(Chrome.focusEdge(accent), lineWidth: Chrome.width(.overviewChip, focused: true)))
                if found?.isEmpty == true {
                    Text("Open \u{201C}\(model.query)\u{201D} here").font(Chrome.font(12, .medium)).foregroundStyle(Chrome.wash())
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Chrome.shape(.overviewChip, continuous: false).fill(Chrome.tileFill(target: true)))
                        .overlay(Chrome.shape(.overviewChip, continuous: false).strokeBorder(Chrome.focusEdge(accent), lineWidth: Chrome.width(.overviewChip, focused: true)))
                        .contentShape(Rectangle())
                        .onTapGesture { model.onOpenHere(model.current, model.query) }
                }
            }
            .frame(width: layout.size.width)
            .offset(y: model.safeTop + Chrome.spec.space.padding)
        }
    }

    /// The lifted card follows the cursor.
    @ViewBuilder private var liftedCard: some View {
        if let drag = model.drag {
            // As big as its card, but never so big it hides the tile it is going to.
            let full = model.lastLayout?.card(drag.entry.id)?.card.frame.size ?? CGSize(width: 220, height: 140)
            let shrink = min(1, 200 / max(full.width, 1))
            let size = CGSize(width: full.width * shrink, height: full.height * shrink)
            card(drag.entry, size: size, selected: false, lifted: true)
                .position(drag.location)
                .allowsHitTesting(false)
        }
    }
}

/// A workspace's number in the theme's indicator: big and plain with a tint mark (BaneySpaces), in a
/// bordered block (Omarchy) or over a bar (Minimal). It turns accent when selected.
struct OverviewNumber: View {
    let n: Int
    let selected: Bool
    let large: Bool

    var body: some View {
        let tint = Chrome.workspace(n)
        let color = selected ? Chrome.themeAccent : Chrome.wash()
        let size: Double = large ? 22 : 15
        switch Chrome.spec.indicator {
        case .dot:
            HStack(spacing: 6) {
                Text("\(n)").font(Chrome.font(size, .bold, rounded: true)).foregroundStyle(color)
                if large { Chrome.mark().fill(tint).frame(width: 8, height: 8) }
            }
        case .numberBlock:
            Text("\(n)").font(Chrome.font(size * 0.7, .bold)).foregroundStyle(color)
                .frame(minWidth: size * 1.1, minHeight: size * 1.1)
                .overlay(Rectangle().strokeBorder(selected ? Chrome.themeAccent : tint, lineWidth: Chrome.width(.overviewSlot, focused: selected)))
        case .bar:
            VStack(spacing: 2) {
                Text("\(n)").font(Chrome.font(size * 0.8, .bold)).foregroundStyle(color)
                Rectangle().fill(tint).frame(width: size, height: Chrome.width(.overviewSlot, focused: true))
            }
        }
    }
}

private extension View {
    /// At `rect` in the overview's space, whatever the parent's alignment.
    func placed(_ rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
    }

    /// At `rect` of a parent whose own frame is `parent`.
    func placed(_ rect: CGRect, in parent: CGRect) -> some View {
        frame(width: rect.width, height: rect.height).position(x: rect.midX - parent.minX, y: rect.midY - parent.minY)
    }
}

/// Blurs whatever is behind the viewer, so the tiles read cleanly over any window.
struct Backdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .fullScreenUI
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
