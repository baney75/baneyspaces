import CoreGraphics
import Foundation

/// A window dragged by its title bar up to the top edge of a screen, the gesture macOS answers
/// with Mission Control. BaneySpaces answers it with its own overview instead, where letting go
/// over a workspace sends the window there.
///
/// Fed from a mouse press on another app's window and then a tick every frame while the button
/// stays down. Every point and frame is in the window server's space: top-left origin, y down.
public struct TopDrag: Sendable {
    /// How close to the top of the screen the pointer must be. The menu bar stops the window
    /// itself, so only the pointer reaches the very edge.
    public static let band: CGFloat = 3
    /// How long the pointer rests there before the overview opens, so a drag that only passes
    /// the top on its way to another screen doesn't open it.
    public static let dwell: TimeInterval = 0.25

    /// How far below a window's top edge a press can be and still be on its title bar or
    /// toolbar, the parts a window is dragged by. The first few points are the edge that
    /// resizes it.
    public static let titleBand: ClosedRange<CGFloat> = 5...52

    /// The window under the press, its frame before the drag moved it, and where the press was.
    public struct Grab: Equatable, Sendable {
        public let window: WindowID
        public let frame: CGRect
        public let press: CGPoint
        public init(window: WindowID, frame: CGRect, press: CGPoint? = nil) {
            self.window = window
            self.frame = frame
            self.press = press ?? CGPoint(x: frame.midX, y: frame.minY + 12)
        }
    }

    public private(set) var grab: Grab?
    /// The window has followed the pointer: between two ticks its origin changed and its size
    /// didn't. A resize or a text selection never sets it. Compared tick to tick, because macOS
    /// gives a tiled window its old size back as the drag starts.
    public private(set) var moving = false
    /// The window can't follow because it's already against the top of the screen: the press
    /// was on its title bar, it hasn't moved, and the pointer went on up above it.
    public private(set) var pinned = false
    /// The overview opened for this drag; nothing more happens until the button comes up.
    public private(set) var fired = false
    private var topSince: TimeInterval?
    private var last: CGRect?
    /// The window's frame since its size last changed: the press, or the size macOS gave a
    /// tiled window back. A pinned window is one that hasn't moved from it.
    private var baseline: CGRect?

    public init() {}

    /// The button went down on `grab`'s window (nil: not on a window that can move).
    public mutating func press(_ grab: Grab?) {
        self = TopDrag()
        self.grab = grab
        last = grab?.frame
        baseline = grab?.frame
    }

    /// The button came up.
    public mutating func release() { self = TopDrag() }

    /// One tick with the button down: the pointer, the window's frame now (nil once it's gone),
    /// and every screen's frame. Returns the grab once, when the overview should open for it.
    public mutating func tick(cursor: CGPoint, frame: CGRect?, screens: [CGRect], now: TimeInterval) -> Grab? {
        guard let grab, !fired else { return nil }
        guard let frame else { self = TopDrag(); return nil }
        if let last, !moving {
            let sameSize = abs(frame.width - last.width) < 1 && abs(frame.height - last.height) < 1
            let shifted = hypot(frame.minX - last.minX, frame.minY - last.minY) > 0.5
            moving = sameSize && shifted
            if !sameSize { baseline = frame }
        }
        last = frame
        if !moving, let base = baseline {
            let unmoved = hypot(frame.minX - base.minX, frame.minY - base.minY) < 1 && frame.size == base.size
            let onTitleBar = TopDrag.titleBand.contains(grab.press.y - grab.frame.minY)
            let screenTop = screens.first { $0.contains(grab.press) }?.minY
            let atScreenTop = screenTop.map { base.minY - $0 <= 50 } ?? false
            // Above the window, or, for one whose top is the screen's own edge (the menu bar
            // hidden), at that edge: the pointer can't get any higher.
            let pushedUp = cursor.y < base.minY - 2
                || (screenTop.map { base.minY - $0 <= TopDrag.band + 2 } ?? false) && TopDrag.atTop(cursor, screens: screens)
            pinned = unmoved && onTitleBar && atScreenTop && pushedUp
        }
        guard moving || pinned, TopDrag.atTop(cursor, screens: screens) else { topSince = nil; return nil }
        let since = topSince ?? now
        topSince = since
        guard now - since >= TopDrag.dwell else { return nil }
        fired = true
        return grab
    }

    /// The overview couldn't open just now (a switch was under way): the next tick still at the
    /// top tries again.
    public mutating func rearm() { fired = false }

    /// True when `p` is on a screen's top edge, and that edge doesn't lead onto a screen above.
    public static func atTop(_ p: CGPoint, screens: [CGRect]) -> Bool {
        guard let s = screens.first(where: { $0.contains(p) }), p.y < s.minY + band else { return false }
        let above = CGPoint(x: p.x, y: s.minY - 1)
        return !screens.contains { $0.contains(above) }
    }
}

/// macOS's "Drag windows to menu bar to fill screen", which builds before 2026-10-28 turned off
/// along with Mission Control when the overview took the drag to the top. BaneySpaces now leaves
/// it to macOS, and gives it back once where an older build took it.
public enum FillTheScreen {
    /// Whether to turn it back on. `taken`: an older build's record of the settings it took
    /// exists. `saved`: the value it recorded for fill-the-screen (nil when it wasn't set, the
    /// macOS default, which is on). `now`: the value now (nil: not set). An explicit off saved
    /// from before BaneySpaces was the person's own choice and stays.
    public static func turnBackOn(taken: Bool, saved: Bool?, now: Bool?) -> Bool {
        taken && saved != false && now == false
    }

    /// Attempts before giving up on a setting something else keeps off (a profile, say).
    public static let maxTries = 3

    /// What to do once the write to turn it back on has been tried.
    public enum Decision: Equatable {
        /// Nothing more owed (it's on, or wasn't ours to turn on): drop the record, the pending
        /// flag and the count, and remember it was given back.
        case settled
        /// Still off: store this many tries and keep the pending flag so a later launch (or the
        /// uninstaller) tries again.
        case retry(tries: Int)
        /// Still off after `maxTries`: drop the record, the pending flag and the count, and
        /// remember giving up apart from giving back, so the uninstaller still tries once more.
        case giveUp
    }

    /// The decision after a write. `record`: the older build's saved settings exist. `pending`:
    /// an earlier try didn't read back, which `restore()` doesn't clear with the record. `saved`
    /// and `now` as in `turnBackOn`. `tries`: the count stored so far. `triedThisLaunch`: a try
    /// was already counted since BaneySpaces started, so a brief hiccup plus toggling the
    /// switch can't spend every try in one session. `readBack`: the setting reads back on.
    public static func decide(record: Bool, pending: Bool, saved: Bool?, now: Bool?,
                              tries: Int, triedThisLaunch: Bool, readBack: Bool) -> Decision {
        guard turnBackOn(taken: record || pending, saved: saved, now: now), !readBack else { return .settled }
        guard !triedThisLaunch else { return .retry(tries: tries) }
        return tries + 1 >= maxTries ? .giveUp : .retry(tries: tries + 1)
    }
}
