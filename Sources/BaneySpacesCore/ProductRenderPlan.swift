import Foundation

/// The sample windows `BaneySpaces --render` draws, and which one the mid-drag shots carry.
/// Every title and path here is a fixture, never a real window.
///
/// 11-01: the render crash-looped with "index out of range" when a sample left workspace 2 empty,
/// because it took `tiles[2]![0]` as the dragged window. The drag source is looked up here, on
/// the tiles as they are when the shot is drawn, and is nil when there's nothing to drag.
public enum ProductRenderPlan {
    public struct Window: Equatable {
        public var app: String
        public var path: String
        public var title: String
        public init(_ app: String, _ path: String, _ title: String) {
            self.app = app; self.path = path; self.title = title
        }
    }

    public enum Sample: String {
        /// Seven workspaces in use, Mail first on workspace 2: the README and website shots.
        case standard
        /// Seven windows, all on workspace 1, the shape of the contact-sheet run that crashed.
        case reported
    }

    /// `BANEYSPACES_RENDER_SAMPLE`: an unknown or missing name draws the standard sample.
    public static func sample(named name: String?) -> Sample {
        name.flatMap(Sample.init(rawValue:)) ?? .standard
    }

    public static func windows(_ sample: Sample) -> [Int: [Window]] {
        switch sample {
        case .standard:
            return [
                1: [Window("Safari", "/Applications/Safari.app", "Swift documentation"),
                    Window("Notes", "/System/Applications/Notes.app", "Launch checklist"),
                    Window("Terminal", "/System/Applications/Utilities/Terminal.app", "~/Projects/baneyspaces")],
                2: [Window("Mail", "/System/Applications/Mail.app", "Inbox"),
                    Window("Calendar", "/System/Applications/Calendar.app", "October 2026")],
                3: [Window("Music", "/System/Applications/Music.app", "Deep Focus")],
                4: [Window("Messages", "/System/Applications/Messages.app", "Messages")],
                5: [Window("Photos", "/System/Applications/Photos.app", "Library"),
                    Window("Preview", "/System/Applications/Preview.app", "Field notes.pdf")],
                7: [Window("Maps", "/System/Applications/Maps.app", "Erie, Pennsylvania")],
                9: [Window("System Settings", "/System/Applications/System Settings.app", "Keyboard")],
            ]
        case .reported:
            return [
                1: [Window("Safari", "/Applications/Safari.app", "Swift documentation"),
                    Window("Terminal", "/System/Applications/Utilities/Terminal.app", "~/Projects/baneyspaces"),
                    Window("Terminal", "/System/Applications/Utilities/Terminal.app", "swift test"),
                    Window("Notes", "/System/Applications/Notes.app", "Launch checklist"),
                    Window("Mail", "/System/Applications/Mail.app", "Inbox"),
                    Window("Preview", "/System/Applications/Preview.app", "Field notes.pdf"),
                    Window("Music", "/System/Applications/Music.app", "Deep Focus")],
            ]
        }
    }

    /// Every workspace in `Workspaces.range`, empty where the plan has nothing; anything outside is dropped.
    public static func tiles<T>(from plan: [Int: [T]]) -> [Int: [T]] {
        var out: [Int: [T]] = [:]
        for n in Workspaces.range { out[n] = plan[n] ?? [] }
        return out
    }

    /// The window the mid-drag shots carry: workspace 2's first (Mail in the standard sample),
    /// else the first window on the lowest-numbered workspace that has one, else nil.
    public static func dragSource<T>(in tiles: [Int: [T]]) -> (workspace: Int, entry: T)? {
        if let first = tiles[2]?.first { return (2, first) }
        for n in tiles.keys.sorted() {
            if let first = tiles[n]?.first { return (n, first) }
        }
        return nil
    }
}
