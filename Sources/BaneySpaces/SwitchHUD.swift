import AppKit
import SwiftUI

/// A brief, quiet confirmation on every keyboard switch: the 3×3 grid with the new workspace
/// lit, the way the volume overlay confirms a key. It never takes focus or clicks.
final class SwitchHUD {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "showSwitchHUD") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showSwitchHUD") }
    }

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private let model = HUDModel()

    /// `occupied` lights the workspaces that have windows; `icons` are the apps on `n`.
    func show(_ n: Int, occupied: Set<Int> = [], icons: [NSImage] = []) {
        guard SwitchHUD.enabled else { return }
        model.current = n
        model.occupied = occupied
        model.icons = icons
        let p = panel ?? makePanel()
        panel = p
        if let host = p.contentView { host.layoutSubtreeIfNeeded(); p.setContentSize(host.fittingSize) }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let size = p.frame.size
            p.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + screen.frame.height * 0.16))
        }
        hideWork?.cancel()
        p.alphaValue = 1
        p.orderFrontRegardless()
        let work = DispatchWorkItem { [weak p] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                p?.animator().alphaValue = 0
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingView(rootView: HUDView(model: model))
        let size = host.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = host
        return p
    }
}

final class HUDModel: ObservableObject {
    @Published var current = 1
    @Published var occupied: Set<Int> = []
    @Published var icons: [NSImage] = []
}

/// The 3×3 grid as the number keys lay it out: the workspace you went to filled in its own
/// color with its number, workspaces with windows lit, empty ones faint. Below, its name and apps.
struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 5) {
                        ForEach(1...3, id: \.self) { col in cell(row * 3 + col) }
                    }
                }
            }
            HStack(spacing: 6) {
                Text("Workspace \(model.current)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                if model.icons.isEmpty {
                    Text("Empty").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                } else {
                    HStack(spacing: -3) {
                        ForEach(Array(model.icons.enumerated()), id: \.offset) { _, icon in
                            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        }
                    }
                }
            }
            .frame(height: 18)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .background(Chrome.panel(cornerRadius: 22))
        .padding(28)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workspace \(model.current)")
    }

    private func cell(_ n: Int) -> some View {
        let on = n == model.current
        let used = model.occupied.contains(n)
        return RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(on ? Chrome.workspace(n) : Color.white.opacity(used ? 0.2 : 0.07))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(on ? Color.white.opacity(0.35) : Color.white.opacity(used ? 0.12 : 0.05), lineWidth: 1))
            .overlay(Text("\(n)").font(.system(size: on ? 17 : 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(on ? 1 : used ? 0.6 : 0.25)))
            .frame(width: 40, height: 30)
            .shadow(color: on ? Chrome.workspace(n).opacity(0.6) : .clear, radius: 8)
    }
}
