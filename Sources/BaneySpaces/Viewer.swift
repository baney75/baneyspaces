import AppKit
import BaneySpacesCore
import SwiftUI
import UniformTypeIdentifiers

/// The overview: all nine workspaces at once, laid out like the number keys' 3×3 grid.
/// Opens from the Mission Control key or ⌃↑ in place of Mission Control.
final class ViewerModel: ObservableObject {
    /// A window card being dragged: what it is, where it came from, where the cursor is.
    struct Drag {
        let entry: Spaces.Entry
        let from: Int
        var location: CGPoint
    }

    @Published var current = 1
    @Published var tiles: [Int: [Spaces.Entry]] = [:]
    @Published var hovered: Int?
    /// The tile the arrow keys picked. Kept apart from `hovered`: SwiftUI can report the pointer
    /// leaving a tile as it redraws it lit, which would drop the keyboard's pick. Only the
    /// pointer entering a tile takes over from it.
    @Published var keyed: Int?
    /// The lit tile, and the one Return goes to.
    var highlighted: Int? { keyed ?? hovered }
    @Published var drag: Drag?
    /// The drag is a real window carried up from the desktop by its title bar, not a card
    /// picked up here; the pointer belongs to that drag, so the viewer only watches it.
    @Published var carrying = false
    /// Icons supplied directly, for rendered product images with sample windows.
    var icons: [WindowID: NSImage] = [:]
    /// Each tile's frame in the viewer, to find the tile under a dragged card.
    var tileFrames: [Int: CGRect] = [:]
    var onPick: (Int) -> Void = { _ in }
    var onPickWindow: (WindowID, Int) -> Void = { _, _ in }
    var onMove: (WindowID, Int) -> Void = { _, _ in }
    var onClose: () -> Void = {}

    func load(from spaces: Spaces) {
        spaces.refresh()
        // A drag in progress keeps its cards where they are; a reload would cancel the gesture.
        guard drag == nil else { return }
        current = spaces.model.current
        tiles = Dictionary(uniqueKeysWithValues: Workspaces.range.map { ($0, spaces.entries(on: $0)) })
    }

    /// The tile a dragged card would land on, if it isn't the one it came from.
    var dropTarget: Int? {
        guard let drag else { return nil }
        return tileFrames.first { $0.value.contains(drag.location) && $0.key != drag.from }?.key
    }

    /// Forget anything left from the last time the viewer was open.
    func reset() {
        drag = nil
        carrying = false
        hovered = nil
        keyed = nil
    }

    func hover(_ n: Int, _ inside: Bool) {
        if inside { hovered = n; keyed = nil } else if hovered == n { hovered = nil }
    }

    func endDrag() {
        guard let drag else { return }
        if let to = dropTarget {
            // Show the result right away; the real move follows a moment later.
            tiles[drag.from]?.removeAll { $0.id == drag.entry.id }
            tiles[to, default: []].append(drag.entry)
            onMove(drag.entry.id, to)
        }
        withAnimation(.easeOut(duration: 0.15)) { self.drag = nil }
    }
}

private struct TileFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct ViewerView: View {
    @ObservedObject var model: ViewerModel
    /// Redraws when Settings › Appearance changes.
    @ObservedObject private var appearance = Appearance.shared
    /// Rendered images can't capture a live blur, so they draw a still backdrop instead.
    var stillBackdrop = false
    private var accent: Color { Chrome.accent }

    // The body is split into small pieces so every Swift compiler type-checks it quickly.
    var body: some View {
        ZStack {
            backdrop
            // Clicking the backdrop closes the viewer, like clicking the desktop in Mission Control.
            Color.black.opacity(appearance.settings.overviewDim).ignoresSafeArea().onTapGesture { model.onClose() }
            if appearance.settings.panelStyle == .tinted {
                Chrome.accent.opacity(AppearanceSettings.tintWash).ignoresSafeArea().allowsHitTesting(false)
            }
            GeometryReader { g in grid(in: g.size) }
            liftedCard
        }
        .coordinateSpace(name: "viewer")
        .onPreferenceChange(TileFrames.self) { model.tileFrames = $0 }
    }

    @ViewBuilder private var backdrop: some View {
        if appearance.settings.panelStyle == .solid {
            Color(white: 0.07).ignoresSafeArea()
        } else if stillBackdrop {
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.11), Color(red: 0.11, green: 0.07, blue: 0.13)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            Backdrop().ignoresSafeArea()
        }
    }

    /// Three rows share the screen's height, so a tile grows with the display.
    private func grid(in size: CGSize) -> some View {
        let tileHeight: CGFloat = max(160, (size.height - 2 * 48 - 40 - 2 * 20) / 3)
        return VStack(spacing: 18) {
            VStack(spacing: 20) {
                ForEach(0..<3, id: \.self) { row in gridRow(row, tileHeight: tileHeight) }
            }
            footer
        }
        .padding(48)
        .frame(maxWidth: 1600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func gridRow(_ row: Int, tileHeight: CGFloat) -> some View {
        HStack(spacing: 20) {
            ForEach(1...3, id: \.self) { col in tile(row * 3 + col, height: tileHeight) }
        }
    }

    /// The lifted card follows the cursor.
    @ViewBuilder private var liftedCard: some View {
        if let drag = model.drag {
            card(drag.entry, lifted: true)
                .frame(width: 300)
                .position(drag.location)
                .allowsHitTesting(false)
        }
    }

    private var footer: some View {
        Text(model.drag == nil
                     ? "Click a workspace or press its number  ·  Arrow keys and Return work too  ·  Drag a window to another workspace  ·  Esc to close"
                     : model.carrying
                     ? "Let go over a workspace to move the window there  ·  Anywhere else leaves it here"
                     : "Drop on a workspace to move the window there")
            .font(.callout)
            .foregroundStyle(.white.opacity(0.7))
            .frame(height: 40)
    }

    private func tile(_ n: Int, height: CGFloat) -> some View {
        let entries = model.tiles[n] ?? []
        let isCurrent = n == model.current
        let isTarget = model.dropTarget == n
        let isHovered = model.drag == nil && model.highlighted == n
        let content = VStack(alignment: .leading, spacing: 8) {
            tileHeader(n, count: entries.count, isCurrent: isCurrent)
            tileBody(n, entries: entries, isTarget: isTarget)
        }
        return content
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .background(tileShape(isCurrent: isCurrent, isTarget: isTarget, isHovered: isHovered))
            .scaleEffect(isTarget ? 1.02 : 1)
            .animation(.easeOut(duration: 0.12), value: isTarget)
            .background(GeometryReader { g in
                Color.clear.preference(key: TileFrames.self, value: [n: g.frame(in: .named("viewer"))])
            })
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture { model.onPick(n) }
            .onHover { inside in model.hover(n, inside) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(tileLabel(n, entries: entries, isCurrent: isCurrent))
            .accessibilityAddTraits(.isButton)
    }

    private func tileHeader(_ n: Int, count: Int, isCurrent: Bool) -> some View {
        // On one baseline: centered, the small caption floats above the big number's foot.
        HStack(alignment: .firstTextBaseline) {
            Text("\(n)").font(.system(size: 22, weight: .bold, design: .rounded))
            if count > 0 {
                Text(count == 1 ? "1 window" : "\(count) windows").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isCurrent { Text("You're here").font(.caption.weight(.semibold)).foregroundStyle(accent) }
        }
    }

    @ViewBuilder private func tileBody(_ n: Int, entries: [Spaces.Entry], isTarget: Bool) -> some View {
        if entries.isEmpty {
            Spacer()
            emptyLabel(isTarget: isTarget)
            Spacer()
        } else {
            windowList(n, entries: entries)
            if isTarget {
                Text("Move here").font(.caption.weight(.semibold)).foregroundStyle(accent)
            }
        }
    }

    @ViewBuilder private func emptyLabel(isTarget: Bool) -> some View {
        if isTarget {
            Text("Move here").font(.callout).foregroundStyle(accent).frame(maxWidth: .infinity)
        } else {
            Text("Empty").font(.callout).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
        }
    }

    /// Every window is listed; a full tile scrolls instead of hiding any. Rendered images can't
    /// draw a scroll view, so they get the plain list.
    @ViewBuilder private func windowList(_ n: Int, entries: [Spaces.Entry]) -> some View {
        let list = VStack(spacing: 6) { ForEach(entries) { e in draggableCard(e, from: n) } }
        if stillBackdrop {
            list
        } else {
            ScrollView(.vertical) { list }.scrollIndicators(.automatic)
        }
    }

    private func tileShape(isCurrent: Bool, isTarget: Bool, isHovered: Bool) -> some View {
        let border: Color
        if isTarget { border = accent } else if isCurrent { border = accent.opacity(0.85) }
        else if isHovered { border = Color.white.opacity(0.6) } else { border = Color.white.opacity(0.08) }
        let width: CGFloat = isTarget || isCurrent || isHovered ? 3 : 1
        let dash: [CGFloat] = isTarget ? [8, 5] : []
        let fill = isTarget ? Color(white: 0.19) : Color(white: 0.13)
        return RoundedRectangle(cornerRadius: 16)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(border, style: StrokeStyle(lineWidth: width, dash: dash)))
    }

    private func tileLabel(_ n: Int, entries: [Spaces.Entry], isCurrent: Bool) -> String {
        let apps = entries.isEmpty ? "empty" : entries.map(\.app).joined(separator: ", ")
        return "Workspace \(n)\(isCurrent ? ", current" : ""), \(apps)"
    }

    /// A window card in a tile. Click it to go to that window; drag it to another workspace.
    private func draggableCard(_ e: Spaces.Entry, from n: Int) -> some View {
        let beingDragged = model.drag?.entry.id == e.id
        return card(e, lifted: false)
            .opacity(beingDragged ? 0.3 : 1)
            .onHover { inside in (inside ? NSCursor.openHand : NSCursor.arrow).set() }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named("viewer"))
                    .onChanged { v in
                        if model.drag == nil { NSCursor.closedHand.set() }
                        model.drag = ViewerModel.Drag(entry: e, from: n, location: v.location)
                    }
                    .onEnded { _ in
                        NSCursor.arrow.set()
                        model.endDrag()
                    }
            )
            .simultaneousGesture(TapGesture().onEnded { model.onPickWindow(e.id, n) })
    }

    private func card(_ e: Spaces.Entry, lifted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: model.icons[e.id] ?? NSRunningApplication(processIdentifier: e.pid)?.icon ?? NSImage())
                .resizable().frame(width: 20, height: 20)
            // One line per window: the app, then its title, trimmed in the middle if long.
            (Text(e.app).font(.callout.weight(.medium))
             + Text(e.title.isEmpty || e.title == e.app ? "" : "  \(e.title)").font(.callout).foregroundColor(.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(lifted ? Color(white: 0.26) : Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(lifted ? 0.25 : 0), lineWidth: 1))
        .shadow(color: .black.opacity(lifted ? 0.5 : 0), radius: 14, y: 6)
        .scaleEffect(lifted ? 1.04 : 1)
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

/// A borderless panel over everything, on every display's active desktop.
final class ViewerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class ViewerController {
    private let spaces: Spaces
    private let model = ViewerModel()
    private var panel: ViewerPanel?
    private var keyMonitor: Any?
    /// Open from the moment `open()` runs until `close()` starts, not until the fade ends, so a
    /// quick second press always does the right thing.
    private(set) var isOpen = false { didSet { MissionControlKeys.viewerOpen = isOpen } }
    /// Bumped on every open, so a fade-out that finishes late can't hide a viewer reopened since.
    private var openCount = 0

    init(spaces: Spaces) {
        self.spaces = spaces
        model.onPick = { [weak self] n in
            self?.close()
            self?.spaces.switchTo(n)
        }
        model.onPickWindow = { [weak self] id, n in
            self?.close()
            self?.spaces.focus(id, on: n)
        }
        model.onMove = { [weak self] id, n in
            guard let self else { return }
            self.spaces.move(id, to: n)
            // The tile already shows the move; reload once the real one has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.model.load(from: self.spaces) }
        }
        // Closing without a pick hands focus back to the workspace you were on.
        model.onClose = { [weak self] in
            guard let self else { return }
            self.close()
            self.spaces.switchTo(self.spaces.model.current)
        }
    }

    func toggle() { isOpen ? model.onClose() : open() }

    func open() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        isOpen = true
        openCount += 1
        model.reset()
        // Opened on the display under the pointer, it's about that display's workspace.
        spaces.usePointerDisplay()
        spaces.rememberFocus()
        model.load(from: spaces)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        let p = panel ?? makePanel()
        panel = p
        p.ignoresMouseEvents = false
        p.setFrame(frame, display: true)
        p.alphaValue = 0
        // The viewer takes the keyboard so 1–9, Return and Esc reach it, not the app below.
        Windows.makeFrontmost(getpid())
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 1
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.model.onClose(); return nil }   // Esc
            if let c = event.charactersIgnoringModifiers, let n = Int(c), Workspaces.range.contains(n) {
                self.model.onPick(n)
                return nil
            }
            if event.keyCode == 36 { self.model.onPick(self.model.highlighted ?? self.model.current); return nil }  // Return
            // The arrow keys move the highlight from tile to tile; Return goes there.
            let steps: [UInt16: GridStep] = [123: .left, 124: .right, 125: .down, 126: .up]
            if let step = steps[event.keyCode], self.model.drag == nil {
                self.model.keyed = step.from(self.model.highlighted ?? self.model.current)
                return nil
            }
            return event
        }
    }

    /// The top-left of the screen a carried window's overview is on, in window-server space.
    private var carryOrigin = CGPoint.zero

    /// Opens over the screen under `p` for a window being dragged to the top of the screen, in
    /// place of Mission Control. The drag stays the window server's: the viewer takes neither
    /// the pointer nor the keyboard, and only follows where it goes. False for a window that
    /// isn't on a workspace.
    func openCarrying(_ id: WindowID, at p: CGPoint) -> Bool {
        guard !isOpen, let (entry, from) = spaces.entry(for: id) else { return false }
        // Matched in window-server space, as the drag was: at a screen's very top edge an AppKit
        // point would fall just outside it.
        let cgFrames = TopDragWatcher.screens()
        guard let mainHeight = NSScreen.screens.first?.frame.maxY,
              let i = cgFrames.firstIndex(where: { $0.contains(p) }), i < NSScreen.screens.count else { return false }
        let screen = NSScreen.screens[i]
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        isOpen = true
        openCount += 1
        model.reset()
        model.load(from: spaces)
        carryOrigin = CGPoint(x: screen.frame.minX, y: mainHeight - screen.frame.maxY)
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.ignoresMouseEvents = true
        panel.setFrame(screen.frame, display: true)
        model.carrying = true
        model.drag = ViewerModel.Drag(entry: entry, from: from, location: viewerPoint(p))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        Trace.log("topDrag open window=\(id) from=\(from)")
        return true
    }

    /// The carried window's card follows the pointer.
    func carryMoved(to p: CGPoint) {
        guard isOpen, model.carrying, var d = model.drag else { return }
        d.location = viewerPoint(p)
        model.drag = d
    }

    /// The button came up: the workspace the window was let go over, if not its own. Closes.
    func endCarrying() -> Int? {
        guard isOpen, model.carrying else { return nil }
        let target = model.dropTarget
        Trace.log("topDrag release target=\(target.map(String.init) ?? "none")")
        close()
        return target
    }

    /// The pointer in the viewer's own space, which SwiftUI lays out inside the safe area: below
    /// the camera housing on a Mac with a notch, so tile frames start that far down.
    private func viewerPoint(_ p: CGPoint) -> CGPoint {
        let inset = panel?.contentView?.safeAreaInsets ?? NSEdgeInsetsZero
        return CGPoint(x: p.x - carryOrigin.x - inset.left, y: p.y - carryOrigin.y - inset.top)
    }

    func close() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        guard isOpen, let p = panel else { return }
        isOpen = false
        model.reset()
        let count = openCount
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.openCount == count, !self.isOpen else { return }
            p.orderOut(nil)
        })
    }

    private func makePanel() -> ViewerPanel {
        let p = ViewerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = NSHostingView(rootView: ViewerView(model: model).environment(\.colorScheme, .dark))
        return p
    }
}
