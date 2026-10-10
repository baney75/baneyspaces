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
    @Published var drag: Drag?
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
        hovered = nil
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
    private let accent = Color(red: 0.91, green: 0.26, blue: 0.29)

    var body: some View {
        ZStack {
            // Clicking the backdrop closes the viewer, like clicking the desktop in Mission Control.
            Backdrop().ignoresSafeArea()
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { model.onClose() }
            GeometryReader { g in
                // Three rows share the screen's height, so a tile grows with the display.
                let tileHeight = max(160, (g.size.height - 2 * 48 - 40 - 2 * 20) / 3)
                VStack(spacing: 18) {
                    VStack(spacing: 20) {
                        ForEach(0..<3, id: \.self) { row in
                            HStack(spacing: 20) {
                                ForEach(1...3, id: \.self) { col in tile(row * 3 + col, height: tileHeight) }
                            }
                        }
                    }
                    footer
                }
                .padding(48)
                .frame(maxWidth: 1600)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // The lifted card follows the cursor.
            if let drag = model.drag {
                card(drag.entry, lifted: true)
                    .frame(width: 300)
                    .position(drag.location)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "viewer")
        .onPreferenceChange(TileFrames.self) { model.tileFrames = $0 }
    }

    private var footer: some View {
        Text(model.drag == nil
                     ? "Click a workspace or press its number  ·  Drag a window to another workspace  ·  Esc to close"
                     : "Drop on a workspace to move the window there")
            .font(.callout)
            .foregroundStyle(.white.opacity(0.7))
            .frame(height: 40)
    }

    private func tile(_ n: Int, height: CGFloat) -> some View {
        let entries = model.tiles[n] ?? []
        let isCurrent = n == model.current
        let isTarget = model.dropTarget == n
        let isHovered = model.drag == nil && model.hovered == n
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(n)").font(.system(size: 22, weight: .bold, design: .rounded))
                if !entries.isEmpty {
                    Text(entries.count == 1 ? "1 window" : "\(entries.count) windows")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isCurrent { Text("You're here").font(.caption.weight(.semibold)).foregroundStyle(accent) }
            }
            if entries.isEmpty {
                Spacer()
                Text(isTarget ? "Move here" : "Empty").font(.callout)
                    .foregroundStyle(isTarget ? AnyShapeStyle(accent) : AnyShapeStyle(.tertiary))
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                // Every window is listed; a full tile scrolls instead of hiding any.
                ScrollView(.vertical) {
                    VStack(spacing: 6) {
                        ForEach(entries) { e in draggableCard(e, from: n) }
                    }
                }
                .scrollIndicators(.automatic)
                if isTarget {
                    Text("Move here").font(.caption.weight(.semibold)).foregroundStyle(accent)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(isTarget ? Color(white: 0.19) : Color(white: 0.13)))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isTarget ? accent : isCurrent ? accent.opacity(0.85)
                              : isHovered ? Color.white.opacity(0.6) : Color.white.opacity(0.08),
                              style: StrokeStyle(lineWidth: isTarget || isCurrent || isHovered ? 3 : 1,
                                                 dash: isTarget ? [8, 5] : []))
        )
        .scaleEffect(isTarget ? 1.02 : 1)
        .animation(.easeOut(duration: 0.12), value: isTarget)
        .background(GeometryReader { g in
            Color.clear.preference(key: TileFrames.self, value: [n: g.frame(in: .named("viewer"))])
        })
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { model.onPick(n) }
        .onHover { inside in model.hovered = inside ? n : (model.hovered == n ? nil : model.hovered) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workspace \(n)\(isCurrent ? ", current" : ""), \(entries.isEmpty ? "empty" : entries.map(\.app).joined(separator: ", "))")
        .accessibilityAddTraits(.isButton)
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
            Image(nsImage: NSRunningApplication(processIdentifier: e.pid)?.icon ?? NSImage())
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
    private(set) var isOpen = false
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
        spaces.rememberFocus()
        model.load(from: spaces)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        let p = panel ?? makePanel()
        panel = p
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
            if event.keyCode == 36 { self.model.onPick(self.model.hovered ?? self.model.current); return nil }  // Return
            return event
        }
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
