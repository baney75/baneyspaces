import AppKit
import BaneySpacesCore

/// Moves wrapped windows through Accessibility. It never closes, minimizes or recreates one, and it
/// leaves alone windows that are off screen (BaneySpaces parks other workspaces' windows there),
/// minimized, or full screen.
enum DeckLayout {
    /// The screen showing the front app's focused window, else the one with the menu bar in use.
    static func activeScreen() -> NSScreen {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            let ax = AX.app(pid)
            if let w: AXUIElement = ax.value(kAXFocusedWindowAttribute), let f = w.frame {
                let center = CGPoint(x: f.midX, y: f.midY)
                if let s = NSScreen.screens.first(where: { AX.flip($0.frame).contains(center) }) { return s }
            }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    /// Windows of `pids` that are on this desk and on `screen`.
    static func windowsHere(_ engine: Engine, on screen: NSScreen) -> [(pid: pid_t, w: NativeWindow)] {
        let area = AX.flip(screen.frame)
        var out: [(pid_t, NativeWindow)] = []
        for (pid, t) in engine.tracked where !t.app.isHidden {
            for w in NativeWindow.list(pid: pid) where w.onScreen && !w.fullScreen {
                if area.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) { out.append((pid, w)) }
            }
        }
        return out.map { (pid: $0.0, w: $0.1) }
    }

    static func content(on screen: NSScreen, reserve: CGFloat) -> CGRect {
        Deck.content(visible: AX.flip(screen.visibleFrame), sidebar: reserve)
    }

    static func move(_ pid: pid_t, _ w: NativeWindow, to f: CGRect) {
        guard w.frame.integral != f.integral else { return }
        AX.withoutAnimation(AX.app(pid, timeout: 0.5)) { w.ax.set(frame: f) }
    }

    /// Stack: every wrapped window on this screen fills the frame beside the sidebar.
    static func stack(_ engine: Engine, reserve: CGFloat) {
        guard AX.isTrusted else { AX.askForTrust(); return }
        let screen = activeScreen()
        let f = content(on: screen, reserve: reserve)
        for (pid, w) in windowsHere(engine, on: screen) { move(pid, w, to: f) }
    }

    /// Split: `right` on the right half, `left` on the left.
    static func split(_ engine: Engine, left: Item?, right: Item, reserve: CGFloat) {
        guard AX.isTrusted else { AX.askForTrust(); return }
        let (l, r) = Deck.halves(content(on: activeScreen(), reserve: reserve))
        if let w = engine.nativeWindow(for: right), let pid = engine.trackedApp(for: right)?.app.processIdentifier { move(pid, w, to: r) }
        if let left, left.windowNumber != right.windowNumber,
           let w = engine.nativeWindow(for: left), let pid = engine.trackedApp(for: left)?.app.processIdentifier { move(pid, w, to: l) }
    }

    /// Puts one window into the deck frame, used when a window appears or is picked while stacked.
    static func place(_ engine: Engine, item: Item, reserve: CGFloat) {
        guard AX.isTrusted, let w = engine.nativeWindow(for: item), w.onScreen, !w.fullScreen,
              let pid = engine.trackedApp(for: item)?.app.processIdentifier else { return }
        move(pid, w, to: content(on: activeScreen(), reserve: reserve))
    }

    /// Every wrapped window on this screen in a grid, the front app's focused window top left.
    static func tile(_ engine: Engine, reserve: CGFloat) {
        guard AX.isTrusted else { AX.askForTrust(); return }
        let screen = activeScreen()
        var wins = windowsHere(engine, on: screen)
        guard !wins.isEmpty else { return }
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let focused: AXUIElement = AX.app(front).value(kAXFocusedWindowAttribute),
           let i = wins.firstIndex(where: { CFEqual($0.w.ax, focused) }) {
            wins.insert(wins.remove(at: i), at: 0)
        }
        var area = AX.flip(screen.visibleFrame).insetBy(dx: 6, dy: 6)
        if reserve > 0 { area.origin.x += reserve; area.size.width -= reserve }
        for ((pid, w), f) in zip(wins, Grid.frames(count: wins.count, in: area, gap: 6)) { move(pid, w, to: f) }
        for (_, w) in wins.reversed() { w.ax.raise() }
    }

    /// Moves windows out from under the pinned sidebar: narrowed to start just right of it, or slid
    /// right whole when narrowing would leave less than 480 points.
    static func clearStrip(_ engine: Engine, width: CGFloat) {
        guard AX.isTrusted else { return }
        let screen = activeScreen()
        let area = AX.flip(screen.visibleFrame)
        let edge = area.minX + width + 6
        for (pid, w) in windowsHere(engine, on: screen) {
            let f = w.frame
            guard f.minX < edge else { continue }
            let target = f.maxX - edge >= 480
                ? CGRect(x: edge, y: f.minY, width: f.maxX - edge, height: f.height)
                : CGRect(x: min(edge, area.maxX - f.width), y: f.minY, width: f.width, height: f.height)
            move(pid, w, to: target)
        }
    }
}
