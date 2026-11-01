import AppKit
import BaneySpacesCore
import SQLite3

/// Where the launcher's sites come from, on this Mac (spec/launcher.md): the default browser's bookmarks, its
/// most visited sites, and its own favicons, read from the files it keeps. Rules:
/// - read only: the bookmarks file as it is; the history and favicon databases as temporary copies (the browser
///   holds them locked), deleted at once;
/// - only the columns named below: addresses and visit counts from `urls`, and icon images for the hosts shown;
///   never cookies, saved logins, form data, search terms, downloads or visit times;
/// - kept in memory (the index) and never logged: `trace.log` gets counts only;
/// - nothing over the network.
final class SiteSources: @unchecked Sendable {
    static let shared = SiteSources()

    private let lock = NSLock()
    private var current = SiteIndex()
    private var icons: [String: Data] = [:]
    private var bookmarksStamp = ""
    private var historyAt = Date.distantPast
    private var working = false
    private static let historyEvery: TimeInterval = 30 * 60

    var index: SiteIndex { lock.lock(); defer { lock.unlock() }; return current }

    func iconData(forHost host: String) -> Data? { lock.lock(); defer { lock.unlock() }; return icons[host] }

    // MARK: The default browser

    struct Browser {
        let bundleID: String
        let profile: URL?
        let safari: Bool
    }

    /// Chromium-family browsers keep a profile folder under Application Support, by bundle identifier.
    private static let chromiumFolders: [String: String] = [
        "net.imput.helium": "net.imput.helium", "com.google.Chrome": "Google/Chrome", "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.microsoft.edgemac": "Microsoft Edge", "company.thebrowser.Browser": "Arc/User Data", "com.vivaldi.Vivaldi": "Vivaldi",
        "org.chromium.Chromium": "Chromium",
    ]

    static func defaultBrowser() -> Browser? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!),
              let id = Bundle(url: app)?.bundleIdentifier else { return nil }
        if id == "com.apple.Safari" { return Browser(bundleID: id, profile: nil, safari: true) }
        guard let folder = chromiumFolders[id] else { return Browser(bundleID: id, profile: nil, safari: false) }
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(folder)")
        // The profile in use is named in Local State; only that one key is read.
        var name = "Default"
        if let data = try? Data(contentsOf: base.appendingPathComponent("Local State")),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let last = (json["profile"] as? [String: Any])?["last_used"] as? String, !last.isEmpty, !last.contains("/") {
            name = last
        }
        return Browser(bundleID: id, profile: base.appendingPathComponent(name), safari: false)
    }

    // MARK: Refreshing

    /// Called when the launcher opens: bookmarks again if their file changed, history and icons every half hour.
    func refreshIfNeeded() {
        lock.lock()
        guard !working else { lock.unlock(); return }
        working = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { lock.lock(); working = false; lock.unlock() }
            guard let browser = Self.defaultBrowser() else { return }
            let bookmarksFile = browser.safari
                ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/Bookmarks.plist")
                : browser.profile?.appendingPathComponent("Bookmarks")
            let stamp = bookmarksFile.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                .map { "\($0.timeIntervalSince1970)" } ?? "none"
            lock.lock()
            let bookmarksChanged = stamp != bookmarksStamp
            let historyDue = Date().timeIntervalSince(historyAt) > Self.historyEvery
            let before = current
            lock.unlock()
            guard bookmarksChanged || historyDue else { return }

            var bookmarks: [Bookmark] = []
            if let file = bookmarksFile, let data = try? Data(contentsOf: file) {
                bookmarks = browser.safari ? BookmarkParse.safari(data) : BookmarkParse.chromium(data)
            }
            var frequent: [Site] = []
            var newIcons: [String: Data]?
            if historyDue, let profile = browser.profile {
                frequent = Self.frequentSites(in: profile.appendingPathComponent("History"))
                var hosts = Set(SiteCatalog.builtIn.map(\.host)).union(frequent.map(\.host))
                hosts.formUnion(bookmarks.prefix(400).compactMap { SiteCatalog.host(of: $0.url) })
                newIcons = Self.favicons(in: profile.appendingPathComponent("Favicons"), hosts: hosts)
            }
            let index = SiteIndex(bookmarks: bookmarks, frequent: historyDue ? frequent : before.frequentSites)
            lock.lock()
            current = index
            if bookmarksChanged { bookmarksStamp = stamp }
            if historyDue { historyAt = Date() }
            if let newIcons { icons = newIcons }
            let iconCount = icons.count
            lock.unlock()
            // Counts only: no title, address or host is ever written.
            Trace.log("sites: bookmarks=\(bookmarks.count) frequent=\(frequent.count) icons=\(iconCount)")
        }
    }

    // MARK: History and favicons (temporary copies, only the columns the launcher needs)

    private static func withCopy<T>(of url: URL, _ body: (OpaquePointer) -> T?) -> T? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("baneyspaces-sites-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        defer { try? fm.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("db")
        guard (try? fm.copyItem(at: url, to: copy)) != nil else { return nil }
        // A write-ahead log holds the newest rows.
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: url.path + suffix)
            if fm.fileExists(atPath: side.path) { try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix)) }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        return body(db)
    }

    /// The addresses and visit counts of the most visited pages, summed by site (`FrequentSites`).
    static func frequentSites(in history: URL) -> [Site] {
        withCopy(of: history) { db -> [Site] in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT url, visit_count FROM urls ORDER BY visit_count DESC LIMIT 3000", -1, &stmt, nil) == SQLITE_OK,
                  let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            var rows: [(url: String, visits: Int)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let u = sqlite3_column_text(stmt, 0) else { continue }
                rows.append((String(cString: u), Int(sqlite3_column_int(stmt, 1))))
            }
            return FrequentSites.top(rows)
        } ?? []
    }

    /// The browser's own icon for each host, the largest it has. Only for hosts the launcher can show.
    static func favicons(in database: URL, hosts: Set<String>) -> [String: Data] {
        withCopy(of: database) { db -> [String: Data] in
            var out: [String: Data] = [:]
            var stmt: OpaquePointer?
            let sql = "SELECT b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON m.icon_id = b.icon_id "
                + "WHERE m.page_url LIKE ?1 OR m.page_url LIKE ?2 ORDER BY b.width DESC LIMIT 1"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [:] }
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for host in hosts {
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, "https://\(host)/%", -1, transient)
                sqlite3_bind_text(stmt, 2, "https://www.\(host)/%", -1, transient)
                if sqlite3_step(stmt) == SQLITE_ROW, let blob = sqlite3_column_blob(stmt, 0) {
                    let n = Int(sqlite3_column_bytes(stmt, 0))
                    if n > 16, n < 200_000 { out[host] = Data(bytes: blob, count: n) }
                }
            }
            return out
        } ?? [:]
    }

    // MARK: Icons

    /// The browser's icon for the site, else a tile with its first letter. No network, no bundled artwork.
    func icon(for site: Site) -> NSImage {
        if let data = iconData(forHost: site.host), let image = NSImage(data: data) { return image }
        return Self.letterTile(site.name, seed: site.host)
    }

    static func letterTile(_ name: String, seed: String) -> NSImage {
        let size = NSSize(width: 32, height: 32)
        let hue = CGFloat(abs(seed.hashValue % 360)) / 360
        return NSImage(size: size, flipped: false) { rect in
            NSColor(hue: hue, saturation: 0.45, brightness: 0.62, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            let letter = String(name.first(where: { $0.isLetter || $0.isNumber }) ?? "?").uppercased() as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white]
            let s = letter.size(withAttributes: attrs)
            letter.draw(at: NSPoint(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2), withAttributes: attrs)
            return true
        }
    }
}
