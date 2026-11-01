import AppKit
import BaneySpacesCore
import SQLite3

/// The phone's apps, as iPhone Mirroring keeps them in its own container. Donovan, 2026-11-01: "Let
/// BaneySpaces ask macOS." The first read makes macOS ask whether BaneySpaces may access data from other
/// apps; if that is denied, or nothing in the container looks like an app list, the launcher keeps only
/// its "Search iPhone for …" row. Nothing is written to the container, the format is discovered at run
/// time (`IPhoneAppParse` accepts property lists, JSON and SQLite of unknown shape), and only counts and
/// structure are logged, never names, values or paths of anything personal.
final class IPhoneAppCache: IPhoneAppProvider, @unchecked Sendable {
    static let shared = IPhoneAppCache()

    enum Status: Equatable {
        case notRead
        case reading
        /// macOS refused the read (the "access data from other apps" answer was No, or never given).
        case denied
        case missing
        /// Read, but nothing in it looked like a list of apps.
        case unknownShape
        case ready(Int)
    }

    static let containerData = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.apple.ScreenContinuity/Data")

    private let lock = NSLock()
    private var list: [IPhoneApp] = []
    private var state = Status.notRead
    private var stamp = ""
    private var readAt = Date.distantPast
    private static let recheck: TimeInterval = 300

    /// Where BaneySpaces keeps what it learned: names, bundle ids and icons, in its own folder.
    private static var folder: URL { Spaces.folder.appendingPathComponent("iphone-apps") }

    private init() { loadCache() }

    var status: Status { lock.lock(); defer { lock.unlock() }; return state }
    func apps() -> [IPhoneApp] { lock.lock(); defer { lock.unlock() }; return list }

    /// For Settings › Launcher.
    var statusLine: String {
        switch status {
        case .notRead: return "Not read yet. It happens the first time you open the launcher."
        case .reading: return "Reading iPhone Mirroring's list of apps…"
        case .denied: return "macOS didn't let BaneySpaces read iPhone Mirroring's data. Allow it in System Settings › Privacy & Security › App Management or Full Disk Access; until then the launcher can search your iPhone but can't list its apps."
        case .missing: return "iPhone Mirroring has no data on this Mac yet."
        case .unknownShape: return "Read iPhone Mirroring's data but found no list of apps in it. Run BaneySpaces --dump-iphone-apps-shape to see its structure."
        case .ready(let n): return "\(n) iPhone apps found."
        }
    }

    // MARK: Refreshing

    /// Reads the container in the background if it hasn't been lately and its files changed. The first read
    /// is what makes macOS ask.
    func refreshIfNeeded() {
        guard IPhoneMirroring.installed else { return }
        lock.lock()
        let due = state != .reading && Date().timeIntervalSince(readAt) > Self.recheck
        if due { state = .reading; readAt = Date() }
        lock.unlock()
        guard due else { return }
        DispatchQueue.global(qos: .utility).async { [self] in read() }
    }

    private func read() {
        let scan = Self.scan(Self.containerData)
        switch scan.access {
        case .denied: return finish(.denied, [], "denied")
        case .missing: return finish(.missing, [], "missing")
        case .ok: break
        }
        // Unchanged since the last read: keep what is cached.
        let newStamp = scan.files.filter(\.candidate).map { "\($0.relative):\($0.size):\($0.modified)" }.sorted().joined(separator: "|")
        lock.lock(); let same = newStamp == stamp && !list.isEmpty; lock.unlock()
        if same { return finish(.ready(apps().count), nil, "unchanged") }

        var found: [IPhoneApp] = []
        var parsed = 0
        for f in scan.files.filter(\.candidate).prefix(60) {
            let apps = Self.apps(inFile: f.url)
            if !apps.isEmpty { parsed += 1 }
            found += apps
        }
        // Icons the container keeps as files named for the app's bundle id.
        let images = scan.files.filter { ["png", "jpg", "jpeg", "heic", "tiff", "webp"].contains($0.ext) }
        var seen = Set<String>()
        let apps = found.filter { seen.insert(($0.bundleID ?? $0.name).lowercased()).inserted }.map { a -> IPhoneApp in
            guard a.icon == nil, let id = a.bundleID?.lowercased(),
                  let file = images.first(where: { $0.url.lastPathComponent.lowercased().contains(id) }),
                  let data = try? Data(contentsOf: file.url) else { return a }
            return IPhoneApp(name: a.name, bundleID: a.bundleID, icon: data)
        }
        let kinds = Dictionary(grouping: scan.files, by: \.ext).mapValues(\.count)
        // Counts only.
        Trace.log("iphone apps: files=\(scan.files.count) candidates=\(scan.files.filter(\.candidate).count) "
                  + "plist=\(kinds["plist", default: 0]) json=\(kinds["json", default: 0]) "
                  + "db=\(kinds["db", default: 0] + kinds["sqlite", default: 0] + kinds["sqlite3", default: 0]) parsed=\(parsed) apps=\(apps.count)")
        lock.lock(); stamp = newStamp; lock.unlock()
        finish(apps.isEmpty ? .unknownShape : .ready(apps.count), apps, nil)
        if !apps.isEmpty { save() }
    }

    private func finish(_ s: Status, _ apps: [IPhoneApp]?, _ note: String?) {
        lock.lock()
        state = s
        if let apps, !apps.isEmpty { list = apps }
        lock.unlock()
        if let note { Trace.log("iphone apps: \(note)") }
    }

    // MARK: Reading the container

    struct FileInfo {
        let url: URL
        let relative: String
        let ext: String
        let size: Int
        let modified: Int
        var candidate: Bool { ["plist", "json", "db", "sqlite", "sqlite3"].contains(ext) && size > 0 && size < 40_000_000 }
    }
    enum Access { case ok, denied, missing }

    /// The files under the container, to a depth and a count. The first listing is the one macOS asks about.
    static func scan(_ root: URL) -> (access: Access, files: [FileInfo]) {
        let fm = FileManager.default
        do { _ = try fm.contentsOfDirectory(atPath: root.path) } catch let e as NSError {
            let code = (e.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? e.code
            if e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError || code == Int(ENOENT) { return (.missing, []) }
            return (.denied, [])
        }
        var out: [FileInfo] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
                                     errorHandler: { _, _ in true }) else { return (.ok, []) }
        for case let url as URL in en {
            if en.level > 8 { en.skipDescendants(); continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let rel = String(url.path.dropFirst(root.path.count + 1))
            out.append(FileInfo(url: url, relative: rel, ext: url.pathExtension.lowercased(), size: v.fileSize ?? 0,
                                modified: Int(v.contentModificationDate?.timeIntervalSince1970 ?? 0)))
            if out.count >= 4000 { break }
        }
        return (.ok, out)
    }

    /// Apps in one file, whatever it is: a property list (a keyed archive is opened), JSON, or SQLite.
    static func apps(inFile url: URL) -> [IPhoneApp] {
        guard let object = object(inFile: url) else { return sqliteApps(url) }
        return IPhoneAppParse.apps(in: object)
    }

    static func object(inFile url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 40_000_000 else { return nil }
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            if let d = plist as? [String: Any], d["$archiver"] != nil {
                let classes: [AnyClass] = [NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSData.self, NSDate.self, NSURL.self, NSSet.self]
                if let o = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) { return o }
            }
            return plist
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    // MARK: SQLite (a copy, read-only: the app may hold the original)

    static func withDatabase<T>(_ url: URL, _ body: (OpaquePointer) -> T?) -> T? {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("iphone-apps-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: copy) }
        guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        return body(db)
    }

    static func rows(_ db: OpaquePointer, _ sql: String, columns: Int) -> [[String]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW, out.count < 5000 {
            out.append((0..<columns).map { i in sqlite3_column_text(stmt, Int32(i)).map { String(cString: $0) } ?? "" })
        }
        return out
    }

    static func tables(_ db: OpaquePointer) -> [(name: String, columns: [String])] {
        rows(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'", columns: 1).map { $0[0] }.map { t in
            (t, rows(db, "PRAGMA table_info(\"\(t.replacingOccurrences(of: "\"", with: ""))\")", columns: 2).map { $0[1] })
        }
    }

    static func sqliteApps(_ url: URL) -> [IPhoneApp] {
        withDatabase(url) { db -> [IPhoneApp] in
            var apps: [IPhoneApp] = []
            for t in tables(db) {
                guard let c = IPhoneAppParse.appColumns(t.columns) else { continue }
                let q = { (s: String) in "\"" + s.replacingOccurrences(of: "\"", with: "") + "\"" }
                for r in rows(db, "SELECT \(q(c.name)), \(q(c.bundle)) FROM \(q(t.name)) LIMIT 5000", columns: 2)
                where IPhoneAppParse.looksLikeBundleID(r[1]) && !r[0].isEmpty {
                    apps.append(IPhoneApp(name: r[0], bundleID: r[1]))
                }
            }
            return apps
        } ?? []
    }

    // MARK: What was learned, kept by BaneySpaces

    private struct Saved: Codable { var stamp: String; var apps: [Entry]; struct Entry: Codable { var name: String; var bundleID: String? } }

    private func iconURL(_ id: String) -> URL { Self.folder.appendingPathComponent("icons/\(id).img") }

    private func save() {
        lock.lock(); let apps = list, stamp = stamp; lock.unlock()
        try? FileManager.default.createDirectory(at: Self.folder.appendingPathComponent("icons"), withIntermediateDirectories: true)
        for a in apps { if let id = a.bundleID, let data = a.icon { try? data.write(to: iconURL(id)) } }
        let saved = Saved(stamp: stamp, apps: apps.map { .init(name: $0.name, bundleID: $0.bundleID) })
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: Self.folder.appendingPathComponent("apps.json")) }
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.folder.appendingPathComponent("apps.json")),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        list = saved.apps.map { e in IPhoneApp(name: e.name, bundleID: e.bundleID, icon: e.bundleID.flatMap { try? Data(contentsOf: iconURL($0)) }) }
        stamp = saved.stamp
        if !list.isEmpty { state = .ready(list.count) }
    }

    // MARK: --dump-iphone-apps-shape

    /// The structure of the container, by names and types only: file names (bundle ids masked), sizes,
    /// property list and JSON key names, SQLite table and column names with row counts. No value is printed.
    static func dumpShape() -> Int32 {
        func out(_ s: String) { print(s) }
        let scan = scan(containerData)
        switch scan.access {
        case .denied:
            out("denied: macOS did not let BaneySpaces read \(containerData.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).")
            out("Allow it in System Settings › Privacy & Security (App Management, or Full Disk Access), then run this again.")
            return 1
        case .missing:
            out("missing: iPhone Mirroring has no data folder on this Mac.")
            return 1
        case .ok: break
        }
        // Names that are another app's bundle id (a file per app) are shown as <bundle-id>; Apple's stay.
        let id = try! NSRegularExpression(pattern: "[A-Za-z0-9_-]+(\\.[A-Za-z0-9_-]+){2,}")
        func mask(_ s: String) -> String {
            var result = s
            for m in id.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
                guard let r = Range(m.range, in: result), !result[r].hasPrefix("com.apple.") else { continue }
                result.replaceSubrange(r, with: "<bundle-id>")
            }
            return result
        }
        out("iPhone Mirroring container: \(scan.files.count) files")
        let kinds = Dictionary(grouping: scan.files, by: \.ext).mapValues(\.count).sorted { $0.key < $1.key }
        out("by extension: " + kinds.map { "\($0.key.isEmpty ? "(none)" : $0.key)=\($0.value)" }.joined(separator: " "))
        var total = 0
        for f in scan.files.sorted(by: { $0.relative < $1.relative }) {
            let shown = mask(f.relative)
            if f.candidate {
                out("\n\(shown)  (\(f.size) bytes)")
                if let o = object(inFile: f.url) {
                    out(IPhoneAppParse.shape(of: o, depth: 1).split(separator: "\n", omittingEmptySubsequences: false).prefix(60).joined(separator: "\n"))
                    total += IPhoneAppParse.apps(in: o).count
                } else if let report = withDatabase(f.url, { db -> String in
                    tables(db).map { t in
                        let count = rows(db, "SELECT COUNT(*) FROM \"\(t.name.replacingOccurrences(of: "\"", with: ""))\"", columns: 1).first?.first ?? "?"
                        return "  table \(t.name) (\(count) rows): " + t.columns.joined(separator: ", ")
                    }.joined(separator: "\n")
                }) {
                    out(report)
                    total += sqliteApps(f.url).count
                } else {
                    out("  (not a property list, JSON or SQLite)")
                }
            } else if f.size > 0 {
                out("\(shown)  (\(f.size) bytes)")
            }
        }
        out("\napps recognized in all files: \(total)")
        return 0
    }
}
