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

    func show(_ n: Int) {
        guard SwitchHUD.enabled else { return }
        model.current = n
        let p = panel ?? makePanel()
        panel = p
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

private final class HUDModel: ObservableObject {
    @Published var current = 1
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel
    private let red = Color(red: 0.91, green: 0.26, blue: 0.29)

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 5) {
                        ForEach(1...3, id: \.self) { col in
                            let n = row * 3 + col
                            RoundedRectangle(cornerRadius: 4)
                                .fill(n == model.current ? red : Color.white.opacity(0.16))
                                .frame(width: 22, height: 16)
                        }
                    }
                }
            }
            Text("\(model.current)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.black.opacity(0.62)))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.white.opacity(0.1)))
        .accessibilityLabel("Workspace \(model.current)")
    }
}
