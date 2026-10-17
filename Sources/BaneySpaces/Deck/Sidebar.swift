import AppKit
import BaneySpacesCore
import SwiftUI

/// What the sidebar and switcher show. The app delegate keeps it current.
final class DeckModel: ObservableObject {
    @Published var items: [Item] = []
    @Published var unseen: [String] = []
    @Published var trusted = AX.isTrusted
    @Published var pinned = false
    @Published var layout: Deck.Layout = .stack
    @Published var collapsed: Set<String> = []
    @Published var hooksInstalled = true

    var onFocus: (Item) -> Void = { _ in }
    var onClose: (Item, Engine.CloseWhat) -> Void = { _, _ in }
    var onNewHere: (Item) -> Void = { _ in }
    var onTile: () -> Void = {}
    var onNewClaude: () -> Void = {}
    var onNewTerminal: () -> Void = {}
    var onPin: (Bool) -> Void = { _ in }
    var onLayout: (Deck.Layout) -> Void = { _ in }
    var onAllow: () -> Void = {}
    var onSearch: () -> Void = {}
    var onInstallHooks: () -> Void = {}
    enum PhoneAction { case mirror, shell, screenshot }
    var onPhone: (Item, PhoneAction) -> Void = { _, _ in }

    var working: Int { items.filter { $0.activity == .working }.count }
    var here: [Item] { items.filter { $0.workspace == 0 } }
    var elsewhere: [Item] { items.filter { $0.workspace != 0 } }

    /// Rows grouped by role, then by window, in the engine's order.
    func sections(_ list: [Item]) -> [(role: Role, groups: [(id: String, items: [Item])])] {
        Role.allCases.compactMap { role in
            let rows = list.filter { $0.role == role }
            guard !rows.isEmpty else { return nil }
            var order: [String] = []
            var by: [String: [Item]] = [:]
            for r in rows {
                if by[r.group] == nil { order.append(r.group) }
                by[r.group, default: []].append(r)
            }
            return (role, order.map { ($0, by[$0]!) })
        }
    }
}

enum Icons {
    private static var cache: [String: NSImage] = [:]
    static func app(_ bundleID: String) -> NSImage {
        if let i = cache[bundleID] { return i }
        let img: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            img = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            img = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        }
        img.size = NSSize(width: 32, height: 32)
        cache[bundleID] = img
        return img
    }
}

struct SidebarView: View {
    @ObservedObject var model: DeckModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            search
            if model.pinned { layoutPicker }
            Divider().opacity(0.35)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.items.isEmpty {
                        Text("Nothing wrapped is open. Open a terminal, your browser, Claude, ChatGPT or T3 Code.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 6)
                    }
                    ForEach(model.sections(model.here), id: \.role) { s in
                        RoleSection(role: s.role, groups: s.groups, model: model)
                    }
                    if !model.elsewhere.isEmpty { ElsewhereSection(items: model.elsewhere, model: model) }
                }
                .padding(.horizontal, 8).padding(.vertical, 8)
            }
            notices
            toolbar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.stack.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text("Deck").font(.system(size: 13, weight: .semibold))
            if model.working > 0 { Pill(text: "\(model.working) working", color: .blue) }
            if !model.unseen.isEmpty { Pill(text: "\(model.unseen.count) done", color: .orange) }
            Spacer()
            IconButton(symbol: model.pinned ? "pin.fill" : "pin",
                       help: model.pinned ? "Unpin: hide when the pointer leaves" : "Pin: dock the sidebar and stack windows beside it",
                       id: "deck.pin") { model.onPin(!model.pinned) }
                .foregroundStyle(model.pinned ? Color.accentColor : .secondary)
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.top, 10).padding(.bottom, 6)
    }

    var search: some View {
        Button(action: model.onSearch) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
                Text("Go to anything").font(.system(size: 12))
                Spacer()
                Text("⌃⌘K").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain).padding(.horizontal, 8).padding(.bottom, 8)
        .accessibilityIdentifier("deck.search").accessibilityLabel("Go to anything")
    }

    var layoutPicker: some View {
        Picker("", selection: Binding(get: { model.layout }, set: { model.onLayout($0) })) {
            Text("Stack").tag(Deck.Layout.stack)
            Text("Split").tag(Deck.Layout.split)
            Text("Free").tag(Deck.Layout.free)
        }
        .pickerStyle(.segmented).labelsHidden().controlSize(.small)
        .padding(.horizontal, 8).padding(.bottom, 8)
        .help("Stack: every window fills the space beside the sidebar. Split: the one you pick and the one before it, side by side. Free: windows stay put.")
        .accessibilityIdentifier("deck.layout")
    }

    @ViewBuilder var notices: some View {
        if !model.trusted {
            Banner(symbol: "lock.open", text: "Allow Accessibility so the Deck sees every window", id: "deck.allow", action: model.onAllow)
        } else if !model.hooksInstalled {
            Banner(symbol: "bolt", text: "Install Claude Code hooks for exact agent status", id: "deck.hooks", action: model.onInstallHooks)
        }
    }

    var toolbar: some View {
        HStack(spacing: 4) {
            ToolButton(symbol: "square.grid.2x2", help: "Tile every window on this screen (⌘⇧C in a terminal)", id: "deck.tile", action: model.onTile)
            ToolButton(symbol: "sparkle", help: "New Claude Code session", id: "deck.new-claude", action: model.onNewClaude)
            ToolButton(symbol: "plus", help: "New terminal in this folder", id: "deck.new-terminal", action: model.onNewTerminal)
        }
        .padding(8)
    }
}

struct RoleSection: View {
    let role: Role
    let groups: [(id: String, items: [Item])]
    @ObservedObject var model: DeckModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(role.title.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary).padding(.leading, 6)
            ForEach(groups, id: \.id) { g in
                if g.items.allSatisfy({ $0.kind == .device }) {
                    ForEach(g.items) { ItemRow(item: $0, model: model, showIcon: false) }
                } else if g.items.count == 1 && g.items[0].kind == .window {
                    ItemRow(item: g.items[0], model: model, showIcon: true)
                } else {
                    GroupBlock(groupID: g.id, items: g.items, model: model)
                }
            }
        }
    }
}

struct GroupBlock: View {
    let groupID: String
    let items: [Item]
    @ObservedObject var model: DeckModel
    @State private var hover = false

    var collapsed: Bool { model.collapsed.contains(groupID) }
    /// Browser windows with many tabs start folded to the showing tab and anything that needs you.
    var visible: [Item] {
        guard !collapsed else { return items.filter { model.unseen.contains($0.id) } }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Image(nsImage: Icons.app(items[0].bundleID)).resizable().frame(width: 13, height: 13)
                Text(title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                if collapsed, let s = summary { Text(s).font(.system(size: 10)) }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90)).opacity(hover ? 1 : 0.5)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).frame(height: 20)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.12)) {
                    if collapsed { model.collapsed.remove(groupID) } else { model.collapsed.insert(groupID) }
                }
            }
            .onHover { hover = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title), \(collapsed ? "folded" : "open")")
            .accessibilityAddTraits(.isButton)
            ForEach(visible) { ItemRow(item: $0, model: model, showIcon: false) }
        }
    }

    var title: String {
        let app = items[0].appName
        if items[0].kind == .terminal {
            let tabs = Set(items.filter { !$0.nested }.map(\.id)).count
            return tabs > 1 ? "\(app) · \(tabs) tabs" : app
        }
        return items.count > 1 ? "\(app) · \(items.count) tabs" : app
    }

    var summary: String? {
        let done = items.filter { model.unseen.contains($0.id) }.count
        let working = items.filter { $0.activity == .working }.count
        if done > 0 { return "· \(done) done" }
        return working > 0 ? "· \(working) working" : nil
    }
}

struct ElsewhereSection: View {
    let items: [Item]
    @ObservedObject var model: DeckModel
    var collapsed: Bool { !model.collapsed.contains("elsewhere-open") }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("OTHER WORKSPACES").font(.system(size: 9, weight: .bold))
                Text("\(items.count)").font(.system(size: 9))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(collapsed ? 0 : 90))
            }
            .foregroundStyle(.tertiary).padding(.horizontal, 6).frame(height: 18)
            .contentShape(Rectangle())
            .onTapGesture {
                if collapsed { model.collapsed.insert("elsewhere-open") } else { model.collapsed.remove("elsewhere-open") }
            }
            .accessibilityLabel("Other workspaces, \(items.count)").accessibilityAddTraits(.isButton)
            if !collapsed { ForEach(items) { ItemRow(item: $0, model: model, showIcon: true).opacity(0.7) } }
        }
    }
}

struct ItemRow: View {
    let item: Item
    @ObservedObject var model: DeckModel
    let showIcon: Bool
    @State private var hover = false

    var unseen: Bool { model.unseen.contains(item.id) }

    var body: some View {
        HStack(spacing: 8) {
            leading.frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label).font(.system(size: 12, weight: unseen ? .semibold : .regular)).lineLimit(1)
                if !item.notice.isEmpty {
                    Text(item.notice).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
                } else if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
            if hover && item.kind != .device {
                IconButton(symbol: "xmark", help: closeHelp, id: "deck.close.\(item.id)") { model.onClose(item, defaultClose) }
            } else if unseen {
                Pill(text: "done", color: .orange)
            } else if item.workspace > 0 {
                Text("⌘\(item.workspace)").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6).padding(.leading, item.nested ? 12 : 0)
        .background(RoundedRectangle(cornerRadius: 6).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(unseen ? Color.orange.opacity(0.7) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { model.onFocus(item) }
        .onHover { hover = $0 }
        .help(item.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("deck.row.\(item.id)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.onFocus(item) }
        .contextMenu {
            Button("Go To") { model.onFocus(item) }
            Divider()
            if item.kind == .device {
                if item.appName != "iPad" {
                    Button(item.id.hasPrefix("ios:") ? "Open iPhone Mirroring" : "Mirror the Screen") { model.onPhone(item, .mirror) }
                }
                if item.id.hasPrefix("android:") {
                    Button("Open a Shell on It") { model.onPhone(item, .shell) }
                    Button("Save a Screenshot to the Desktop") { model.onPhone(item, .screenshot) }
                }
            } else if item.bundleID == "com.mitchellh.ghostty" {
                if item.nested { Button("Close Split") { model.onClose(item, .terminal) } }
                Button("Close Tab") { model.onClose(item, .tab) }
                Button("Close Window") { model.onClose(item, .window) }
                Divider()
                Button("New Window in This Folder") { model.onNewHere(item) }
            } else if item.kind == .tab && item.role == .browser {
                Button("Close Tab") { model.onClose(item, .tab) }
            } else {
                Button("Close Window") { model.onClose(item, .window) }
            }
            if !item.directory.isEmpty {
                Button("Copy Folder Path") { copy(item.directory) }
            }
            Button("Copy ID for the baneyspaces command") { copy(item.id) }
        }
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    var defaultClose: Engine.CloseWhat {
        switch item.kind {
        case .terminal: return item.nested ? .terminal : .tab
        case .tab: return .tab
        case .window, .device: return .window
        }
    }
    var closeHelp: String {
        switch defaultClose {
        case .terminal: return "Close this split"
        case .tab: return "Close this tab"
        case .window: return "Close this window"
        }
    }

    var subtitle: String {
        if item.kind == .window && showIcon { return item.appName }
        return item.detail
    }

    var accessibilityText: String {
        var parts = [item.label, item.appName]
        switch item.activity {
        case .working: parts.append("working")
        case .waiting: parts.append(unseen ? "finished, unseen" : "waiting for you")
        case .shell: break
        }
        if item.focused { parts.append("focused") }
        if item.workspace > 0 { parts.append("on workspace \(item.workspace)") }
        return parts.joined(separator: ", ")
    }

    var fill: Color {
        if item.focused { return Color.accentColor.opacity(0.28) }
        return hover ? Color.primary.opacity(0.08) : .clear
    }

    @ViewBuilder var leading: some View {
        switch item.activity {
        case .working: ProgressView().controlSize(.mini).scaleEffect(0.8)
        case .waiting: Image(systemName: "asterisk").font(.system(size: 11, weight: .bold))
            .foregroundStyle(unseen ? Color.orange : Color.secondary)
        case .shell:
            if item.kind == .device {
                Image(systemName: item.appName == "iPad" ? "ipad" : item.id.hasPrefix("ios:") ? "iphone" : "candybarphone").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if showIcon || item.kind == .window {
                Image(nsImage: Icons.app(item.bundleID)).resizable().frame(width: 15, height: 15)
            } else if item.kind == .tab {
                Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }
}

struct Banner: View {
    let symbol: String
    let text: String
    let id: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(text, systemImage: symbol).font(.system(size: 11, weight: .medium)).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain).foregroundStyle(.orange).padding(.horizontal, 12).padding(.vertical, 8)
        .accessibilityIdentifier(id)
    }
}

struct Pill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var id: String = ""
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hover ? 0.14 : 0)))
        }
        .buttonStyle(.plain).help(help).onHover { hover = $0 }
        .accessibilityLabel(help).accessibilityIdentifier(id)
    }
}

struct ToolButton: View {
    let symbol: String
    let help: String
    let id: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.14 : 0.07)))
        }
        .buttonStyle(.plain).help(help).onHover { hover = $0 }
        .accessibilityLabel(help).accessibilityIdentifier(id)
    }
}

/// Reports the pointer entering and leaving, even while another app is active.
final class TrackingView: NSView {
    var onPointer: (Bool) -> Void = { _ in }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onPointer(true) }
    override func mouseExited(with event: NSEvent) { onPointer(false) }
}

/// The sidebar: a strip down the left edge of the active screen. It never takes focus: clicks act
/// and keystrokes keep going to the app you're in.
final class SidebarPanel: NSPanel {
    static let width: CGFloat = 264
    static let margin: CGFloat = 6
    var onPointer: (Bool) -> Void = { _ in }
    /// Meant to be on screen. Differs from isVisible while it slides out.
    private(set) var shown = false

    init(model: DeckModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 600),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        title = "BaneySpaces Deck"
        setAccessibilityIdentifier("deck.sidebar")
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = Self.chrome(NSHostingView(rootView: SidebarView(model: model)), radius: 12, onPointer: { [weak self] in self?.onPointer($0) })
    }

    /// A blurred rounded card hosting `content`.
    static func chrome(_ content: NSView, radius: CGFloat, onPointer: ((Bool) -> Void)? = nil) -> NSView {
        let root = TrackingView()
        if let onPointer { root.onPointer = onPointer }
        let blur = NSVisualEffectView()
        blur.material = .sidebar
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = radius
        blur.layer?.masksToBounds = true
        for (child, parent) in [(blur as NSView, root as NSView), (content, blur)] {
            child.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                child.topAnchor.constraint(equalTo: parent.topAnchor),
                child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            ])
        }
        return root
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func frame(on screen: NSScreen) -> NSRect {
        let v = screen.visibleFrame
        return NSRect(x: v.minX + Self.margin, y: v.minY + Self.margin, width: Self.width, height: v.height - 2 * Self.margin)
    }

    /// Shows it on `screen`, sliding in from the edge when `animated`.
    func place(on screen: NSScreen, animated: Bool) {
        let target = frame(on: screen)
        shown = true
        guard animated else {
            // Through the animator, with no duration, so it also cancels a slide-out in flight.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                animator().setFrame(target, display: true)
                animator().alphaValue = 1
            }
            orderFrontRegardless()
            return
        }
        setFrame(target.offsetBy(dx: -24, dy: 0), display: false)
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(target, display: true)
            animator().alphaValue = 1
        }
    }

    func slideOut() {
        guard shown else { return }
        shown = false
        let from = frame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().setFrame(from.offsetBy(dx: -24, dy: 0), display: true)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.shown else { return }
            self.orderOut(nil)
            self.setFrame(from, display: false)
        })
    }
}

/// A 2-point invisible strip on the left screen edge, up only while a wrapped app is in front and
/// the sidebar is hidden. Resting there opens the sidebar; passing through doesn't.
final class EdgeTrigger: NSPanel {
    var onRest: () -> Void = {}
    private var timer: Timer?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 2, height: 600),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.002)
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        let view = TrackingView()
        view.onPointer = { [weak self] inside in
            self?.timer?.invalidate()
            guard inside else { return }
            self?.timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { _ in self?.onRest() }
        }
        contentView = view
    }

    override var canBecomeKey: Bool { false }

    /// Hiding the strip sends no mouseExited, so a pending rest is dropped here.
    override func orderOut(_ sender: Any?) {
        timer?.invalidate()
        super.orderOut(sender)
    }

    func place(on screen: NSScreen) {
        let v = screen.visibleFrame
        // The middle 80% of the edge: the corners stay free for hot corners and the menu bar.
        setFrame(NSRect(x: screen.frame.minX, y: v.minY + v.height * 0.1, width: 2, height: v.height * 0.8), display: false)
    }
}
