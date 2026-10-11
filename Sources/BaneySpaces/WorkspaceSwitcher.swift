import AppKit
import SwiftUI

/// ⌘Tab for workspaces: hold ⌘, tap Tab to step through the workspaces that have windows
/// (most recent first), let go to go there. ⌘⇧Tab steps back; Esc cancels.
final class WorkspaceSwitcher {
    private let spaces: Spaces
    private let model = SwitcherModel()
    private var panel: NSPanel?
    private var watchdog: Timer?

    init(spaces: Spaces) {
        self.spaces = spaces
    }

    var isShowing: Bool { panel?.isVisible == true }

    func step(forward: Bool) {
        if !isShowing {
            let order = spaces.switcherOrder()
            Trace.log("cmdTab show order=\(order) current=\(spaces.model.current)")
            model.tiles = order.map { n in
                SwitcherModel.Tile(n: n, icons: icons(on: n), count: spaces.entries(on: n).count)
            }
            // The first tap lands on the previous workspace, like the app switcher.
            model.selected = order.count > 1 ? (forward ? 1 : order.count - 1) : 0
            show()
        } else if !model.tiles.isEmpty {
            let c = model.tiles.count
            model.selected = (model.selected + (forward ? 1 : c - 1)) % c
        }
    }

    func commit() {
        guard isShowing else { return }
        let target = model.tiles.indices.contains(model.selected) ? model.tiles[model.selected].n : nil
        hide()
        Trace.log("cmdTab commit target=\(target.map(String.init) ?? "none") current=\(spaces.model.current)")
        if let target, target != spaces.model.current { spaces.switchTo(target, announce: false) }
    }

    func cancel() {
        Trace.log("cmdTab cancel")
        hide()
    }

    private func icons(on n: Int) -> [NSImage] {
        var seen = Set<pid_t>()
        return spaces.entries(on: n).compactMap { e -> NSImage? in
            guard seen.insert(e.pid).inserted else { return nil }
            return NSRunningApplication(processIdentifier: e.pid)?.icon
        }
    }

    private func show() {
        let p = panel ?? makePanel()
        panel = p
        let host = p.contentView as! NSHostingView<SwitcherView>
        // Lay out the new tiles first; otherwise fittingSize still reports the last gesture's size.
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            p.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        }
        p.orderFrontRegardless()
        // If the key watcher misses ⌘ being let go (it was off for a moment), notice it here.
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.isShowing else { return }
            if !NSEvent.modifierFlags.contains(.command) {
                MissionControlKeys.inGesture = false
                self.commit()
            }
        }
    }

    private func hide() {
        watchdog?.invalidate()
        watchdog = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: SwitcherView(model: model))
        return p
    }
}

final class SwitcherModel: ObservableObject {
    struct Tile: Identifiable {
        let n: Int
        let icons: [NSImage]
        let count: Int
        var id: Int { n }
    }
    @Published var tiles: [Tile] = []
    @Published var selected = 0
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    private let red = Color(red: 0.91, green: 0.26, blue: 0.29)

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(model.tiles.enumerated()), id: \.element.id) { i, tile in
                let on = i == model.selected
                VStack(spacing: 8) {
                    Text("\(tile.n)")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    HStack(spacing: -6) {
                        ForEach(Array(tile.icons.prefix(4).enumerated()), id: \.offset) { _, icon in
                            Image(nsImage: icon).resizable().frame(width: 26, height: 26)
                        }
                    }
                    .frame(height: 26)
                    Text(tile.count == 0 ? "Empty" : tile.count == 1 ? "1 window" : "\(tile.count) windows")
                        .font(.caption).foregroundStyle(.white.opacity(0.65))
                }
                .frame(width: 108, height: 128)
                .background(RoundedRectangle(cornerRadius: 16).fill(on ? red.opacity(0.22) : Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(on ? red : Color.white.opacity(0.08), lineWidth: on ? 3 : 1))
                .accessibilityLabel("Workspace \(tile.n), \(tile.count) windows\(on ? ", selected" : "")")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color.black.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
    }
}

/// A short record of ⌘Tab gestures in trace.log, to diagnose a switcher that misbehaves. It
/// notes only the gesture (Tab, ⌘ let go, Esc) and workspace numbers, never other keys.
enum Trace {
    static func log(_ line: String) {
        let url = Spaces.folder.appendingPathComponent("trace.log")
        let text = "\(Date().timeIntervalSince1970) \(line)\n"
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 200_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            try? h.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}
