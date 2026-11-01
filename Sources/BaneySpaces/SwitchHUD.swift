import AppKit
import BaneySpacesCore
import SwiftUI

/// A brief, quiet confirmation of a keyboard switch: the 3×3 grid with the new workspace
/// lit, the way the volume overlay confirms a key. It never takes focus or clicks. Off unless
/// `showSwitchHUD` is set (`SwitchHUDPolicy`).
final class SwitchHUD {
    static var stored: Bool? { UserDefaults.standard.object(forKey: SwitchHUDPolicy.defaultsKey) as? Bool }
    static var enabled: Bool {
        get { SwitchHUDPolicy.enabled(stored: stored) }
        set { UserDefaults.standard.set(newValue, forKey: SwitchHUDPolicy.defaultsKey) }
    }

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private let model = HUDModel()

    /// `occupied` lights the workspaces that have windows; `icons` are the apps on `n`.
    /// `display`: the display the workspace went to (with several), else the one under the pointer.
    func show(_ n: Int, occupied: Set<Int> = [], icons: [NSImage] = [], display: DisplayKey? = nil) {
        guard SwitchHUD.enabled else { return }
        model.current = n
        model.occupied = occupied
        model.icons = icons
        let p = panel ?? makePanel()
        panel = p
        if let host = p.contentView { host.layoutSubtreeIfNeeded(); p.setContentSize(host.fittingSize) }
        if let screen = display.flatMap(Windows.screen(for:)) ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let size = p.frame.size
            p.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + screen.frame.height * 0.16))
        }
        hideWork?.cancel()
        p.alphaValue = 1
        p.orderFrontRegardless()
        let work = DispatchWorkItem { [weak p] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Chrome.duration(0.18, .panelOut)
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
    /// Redraws when Settings › Appearance changes.
    @ObservedObject private var appearance = Appearance.shared

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
                Text("Workspace \(model.current)").font(Chrome.font(13, .semibold)).foregroundStyle(Chrome.wash())
                if model.icons.isEmpty {
                    Text("Empty").font(Chrome.font(12, .medium)).foregroundStyle(Chrome.wash(0.45))
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
        .background(Chrome.panelBackground(.hudPanel))
        .padding(28)
        .environment(\.colorScheme, Chrome.scheme)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workspace \(model.current)")
    }

    private func cell(_ n: Int) -> some View {
        let on = n == model.current
        let used = model.occupied.contains(n)
        return Chrome.shape(.hudCell)
            .fill(on ? Chrome.workspace(n) : Chrome.cell(used ? 0.2 : 0.07))
            .overlay(Chrome.shape(.hudCell)
                .strokeBorder(on ? Chrome.focusEdge(Chrome.wash(0.35)) : Chrome.edge(used ? 0.12 : 0.05), lineWidth: Chrome.width(.hudCell)))
            .overlay(Text("\(n)").font(Chrome.font(on ? 17 : 11, .bold, rounded: true))
                .foregroundStyle(on ? Chrome.onTint(n) : Chrome.wash(used ? 0.6 : 0.25)))
            .frame(width: 40, height: 30)
            .shadow(color: Chrome.shadow(on ? 0.6 : 0, color: Chrome.workspace(n)), radius: 8)
    }
}
