import Foundation

/// The optional extra-apps file moved from `~/.config/baneyspaces/deck.json` to `session.json`
/// when the Deck name was cut. The first read copies an old file over, so custom apps and
/// exclusions survive the update. The old file stays, in case of a downgrade.
public enum ConfigMigration {
    public static let legacyName = "deck.json"

    public static func url(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".config/baneyspaces/session.json")
    }

    /// Copies `deck.json` to `session.json` when only the old one exists. True when it copied.
    @discardableResult
    public static func migrate(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let fm = FileManager.default
        let new = url(home: home)
        let old = new.deletingLastPathComponent().appendingPathComponent(legacyName)
        guard !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path) else { return false }
        return (try? fm.copyItem(at: old, to: new)) != nil
    }
}
