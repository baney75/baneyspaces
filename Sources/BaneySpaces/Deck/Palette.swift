import AppKit
import BaneySpacesCore
import SwiftUI

/// The switcher (⌃⌘K): type a few letters of anything wrapped, Return to go there. Terminals,
/// splits, browser tabs and agent windows are in one list, plus a few commands.
final class PaletteModel: ObservableObject {
    struct Entry: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let bundleID: String?
        let symbol: String?
        let badge: String
        let run: () -> Void
    }

    @Published var query = "" { didSet { selection = 0 } }
    @Published var selection = 0
    var source: () -> [Entry] = { [] }

    var results: [Entry] {
        Array(DeckRank.rank(query, source()) { [$0.title, $0.subtitle] }.prefix(40))
    }
}

struct PaletteView: View {
    @ObservedObject var model: PaletteModel
    var onPick: (PaletteModel.Entry) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let results = model.results
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Go to a terminal, tab, agent or command", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 16)).focused($focused)
                    .onSubmit { if results.indices.contains(model.selection) { onPick(results[model.selection]) } }
                    .accessibilityIdentifier("deck.palette.query")
            }
            .padding(.horizontal, 14).frame(height: 46)
            Divider().opacity(0.4)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { i, e in
                            row(e, selected: i == model.selection)
                                .id(i)
                                .onTapGesture { onPick(e) }
                        }
                        if results.isEmpty {
                            Text("Nothing matches").font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selection) { proxy.scrollTo($0, anchor: nil) }
            }
        }
        .frame(width: 560, height: 380)
        .onAppear { focused = true }
    }

    func row(_ e: PaletteModel.Entry, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if let b = e.bundleID { Image(nsImage: Icons.app(b)).resizable() }
                else { Image(systemName: e.symbol ?? "command").font(.system(size: 13)).foregroundStyle(.secondary) }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title).font(.system(size: 13)).lineLimit(1)
                if !e.subtitle.isEmpty { Text(e.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if !e.badge.isEmpty { Text(e.badge).font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange) }
        }
        .padding(.horizontal, 10).frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.3) : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("deck.palette.\(e.id)")
    }
}

/// A floating panel that can take keystrokes without activating BaneySpaces, so the app you were in
/// stays the front app and gets focus back the moment the switcher closes.
final class PalettePanel: NSPanel {
    let model = PaletteModel()
    private var monitor: Any?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .modalPanel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        title = "BaneySpaces Switcher"
        setAccessibilityIdentifier("deck.palette")
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = PaletteView(model: model) { [weak self] e in self?.pick(e) }
        contentView = SidebarPanel.chrome(NSHostingView(rootView: view), radius: 14)
    }

    override var canBecomeKey: Bool { true }
    override func resignKey() { super.resignKey(); dismiss() }

    var isOpen: Bool { isVisible }

    func show(on screen: NSScreen) {
        model.query = ""
        let v = screen.visibleFrame
        setFrame(NSRect(x: v.midX - 280, y: v.maxY - v.height * 0.22 - 380, width: 560, height: 380), display: true)
        makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.isKeyWindow else { return e }
            let count = self.model.results.count
            switch Int(e.keyCode) {
            case 125: self.model.selection = min(self.model.selection + 1, max(count - 1, 0)); return nil
            case 126: self.model.selection = max(self.model.selection - 1, 0); return nil
            case 53: self.dismiss(); return nil
            default:
                // ⌃N / ⌃P like every other switcher.
                if e.modifierFlags.contains(.control), e.charactersIgnoringModifiers == "n" {
                    self.model.selection = min(self.model.selection + 1, max(count - 1, 0)); return nil
                }
                if e.modifierFlags.contains(.control), e.charactersIgnoringModifiers == "p" {
                    self.model.selection = max(self.model.selection - 1, 0); return nil
                }
                return e
            }
        }
    }

    func dismiss() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        orderOut(nil)
    }

    private func pick(_ e: PaletteModel.Entry) {
        dismiss()
        e.run()
    }
}
