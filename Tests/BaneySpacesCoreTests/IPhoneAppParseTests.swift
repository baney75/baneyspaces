import XCTest
@testable import BaneySpacesCore

/// Fixtures are generic structures of the kinds a cache of apps takes, not Donovan's data. The real shape is
/// not known until macOS has let BaneySpaces read it once (`BaneySpaces --dump-iphone-apps-shape`), so the
/// parser accepts any of these and reports what it can't read as "no apps", never as a failure.
final class IPhoneAppParseTests: XCTestCase {
    func testAnArrayOfDictionaries() {
        let object: [String: Any] = ["apps": [
            ["displayName": "Snapchat", "bundleIdentifier": "com.example.snap"],
            ["name": "Weather", "bundleID": "com.example.weather", "iconData": Data(repeating: 1, count: 64)],
        ]]
        let apps = IPhoneAppParse.apps(in: object)
        XCTAssertEqual(apps.map(\.name), ["Snapchat", "Weather"])
        XCTAssertEqual(apps.map(\.bundleID), ["com.example.snap", "com.example.weather"])
        XCTAssertNil(apps[0].icon)
        XCTAssertEqual(apps[1].icon?.count, 64)
    }

    func testADictionaryKeyedByBundleId() {
        let object: [String: Any] = ["installed": [
            "com.example.maps": ["CFBundleDisplayName": "Maps", "version": 3],
            "com.example.notes": ["title": "Notes"],
            "lastUpdated": 12345,
        ]]
        XCTAssertEqual(Set(IPhoneAppParse.apps(in: object).map(\.name)), ["Maps", "Notes"])
    }

    func testFoundDeepAndOnlyOnce() {
        let app: [String: Any] = ["CFBundleIdentifier": "com.example.a", "CFBundleDisplayName": "A"]
        let object: [Any] = [["a": [["b": [app, app]]]], ["again": app]]
        XCTAssertEqual(IPhoneAppParse.apps(in: object).count, 1)
    }

    func testThingsThatAreNotAppsAreIgnored() {
        let object: [String: Any] = ["devices": [["name": "Donovan's iPhone", "identifier": "00008110-000A1B2C3D4E5F"]],
                                     "settings": ["name": "x", "bundleID": "not a bundle id"], "count": 3]
        XCTAssertTrue(IPhoneAppParse.apps(in: object).isEmpty, "a name beside something that isn't a bundle id is no app")
        XCTAssertTrue(IPhoneAppParse.apps(in: "just a string").isEmpty)
        XCTAssertTrue(IPhoneAppParse.apps(in: [Any]()).isEmpty)
    }

    func testWhatLooksLikeABundleId() {
        for ok in ["com.apple.mobilesafari", "com.toyopagroup.picaboo", "org.my-app.Name_1"] { XCTAssertTrue(IPhoneAppParse.looksLikeBundleID(ok), ok) }
        for no in ["Snapchat", "com.apple", "has space.a.b", "a..b", "", ".com.x.y", "x.y.z!"] { XCTAssertFalse(IPhoneAppParse.looksLikeBundleID(no), no) }
    }

    func testShapeNamesKeysAndTypesAndNeverValues() {
        let object: [String: Any] = [
            "apps": [["displayName": "Snapchat", "bundleIdentifier": "com.example.snap", "iconData": Data(count: 40), "installed": true, "size": 12]],
            "byId": ["com.example.one": ["name": "One"], "com.example.two": ["name": "Two"]],
            "owner": "Donovan Baney", "updated": Date(timeIntervalSince1970: 0),
        ]
        let shape = IPhoneAppParse.shape(of: object)
        for key in ["apps", "displayName", "bundleIdentifier", "iconData", "installed", "size", "byId", "owner", "updated", "name"] {
            XCTAssertTrue(shape.contains(key), key)
        }
        XCTAssertTrue(shape.contains("<bundle-id> × 2"))
        XCTAssertTrue(shape.contains("array(1)"))
        XCTAssertTrue(shape.contains("data"))
        XCTAssertTrue(shape.contains("bool"))
        XCTAssertTrue(shape.contains("date"))
        for value in ["Snapchat", "Donovan", "Baney", "com.example.snap", "com.example.one", "com.example.two"] {
            XCTAssertFalse(shape.contains(value), "the shape holds no value: \(value)")
        }
    }

    func testSQLiteTablesWithANameAndABundleColumn() {
        XCTAssertEqual(IPhoneAppParse.appColumns(["id", "displayName", "bundleIdentifier", "iconData"])?.name, "displayName")
        XCTAssertEqual(IPhoneAppParse.appColumns(["id", "display_name", "bundle_id"])?.bundle, "bundle_id", "snake_case matches too")
        XCTAssertEqual(IPhoneAppParse.appColumns(["Z_PK", "ZNAME", "ZBUNDLEID"])?.bundle, "ZBUNDLEID", "Core Data prefixes a Z")
        XCTAssertNil(IPhoneAppParse.appColumns(["id", "name", "created"]))
        XCTAssertNil(IPhoneAppParse.appColumns([]))
    }

    // MARK: The reader's rules (the app target can't be imported)

    func testTheReaderOnlyReadsAndLogsCountsOnly() throws {
        let code = try Repo.code("Sources/BaneySpaces/IPhoneAppCache.swift")
        XCTAssertTrue(code.contains("SQLITE_OPEN_READONLY"))
        XCTAssertFalse(code.contains(".removeItem(at: url)") || code.contains("write(to: url") || code.contains("createFile"),
                       "nothing is written to or removed from the container")
        XCTAssertTrue(code.contains("withDatabase"), "SQLite is opened on a copy")
        let traces = code.components(separatedBy: "Trace.log(").dropFirst().map { String($0.prefix(260)) }
        XCTAssertFalse(traces.isEmpty)
        for t in traces {
            XCTAssertFalse(t.contains(".name") || t.contains("bundleID") || t.contains(".path"), "a trace line names nothing: \(t)")
        }
        let main = try Repo.code("Sources/BaneySpaces/main.swift")
        XCTAssertTrue(main.contains("--dump-iphone-apps-shape"))
        let setup = try Repo.code("Sources/BaneySpaces/Setup.swift")
        XCTAssertTrue(setup.contains("access data from other apps"), "Settings › Launcher explains the prompt")
    }

    func testADeniedReadLeavesTheSearchRow() {
        // Denied, missing and unknown shapes give no apps; the row for the search is there regardless.
        let rows = IPhoneSearch.rows("snapchat", apps: NoIPhoneApps().apps(), installed: true)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].kind, .search("snapchat"))
    }
}
