import XCTest
@testable import BaneySpacesCore

final class FileSearchTests: XCTestCase {
    let home = "/Users/d"

    func testEveryWordMustStartAWordOfTheName() {
        XCTAssertEqual(FileSearch.spotlightQuery("tax 2025"),
                       #"(kMDItemFSName == "tax*"cdw && kMDItemFSName == "2025*"cdw) && kMDItemContentType != "com.apple.application-bundle""#)
        XCTAssertNil(FileSearch.spotlightQuery("a"), "one letter matches half the disk")
        XCTAssertNil(FileSearch.spotlightQuery("   "))
        XCTAssertNotNil(FileSearch.spotlightQuery("ab"))
    }

    /// What was typed can't break out of the quoted value or turn into a wildcard.
    func testTypedQuotesAndWildcardsAreMatchedAsThemselves() {
        XCTAssertEqual(FileSearch.escape(#"a"b"#), #"a\"b"#)
        XCTAssertEqual(FileSearch.escape(#"a\b"#), #"a\\b"#)
        XCTAssertEqual(FileSearch.escape("a*b?"), #"a\*b\?"#)
        let q = FileSearch.spotlightQuery(#"x" || kMDItemFSName == "*"#)!
        XCTAssertTrue(q.contains(#""x\"*"cdw"#), q)
        XCTAssertTrue(q.contains(#""\"\**"cdw"#), q)
    }

    func testLibraryAppInsidesHiddenAndBuildFoldersAreNoise() {
        XCTAssertTrue(FileSearch.isNoise("/Users/d/Library/Caches/x.txt", home: home))
        XCTAssertTrue(FileSearch.isNoise("/Users/d/Projects/app/node_modules/x/readme.md", home: home))
        XCTAssertTrue(FileSearch.isNoise("/Users/d/.config/x.toml", home: home))
        XCTAssertTrue(FileSearch.isNoise("/Users/d/Projects/a/.git/HEAD", home: home))
        XCTAssertTrue(FileSearch.isNoise("/Users/d/Applications/X.app/Contents/Info.plist", home: home))
        XCTAssertTrue(FileSearch.isNoise("/Users/d/Documents/.secret", home: home))
        XCTAssertFalse(FileSearch.isNoise("/Users/d/Documents/Taxes/2025 Return.pdf", home: home))
        XCTAssertFalse(FileSearch.isNoise("/Users/d/Projects", home: home))
    }

    /// iCloud Drive, apps' iCloud folders (Obsidian) and cloud drives live in Library but are yours.
    func testCloudDrivesInLibraryAreNotNoise() {
        XCTAssertFalse(FileSearch.isNoise("/Users/d/Library/Mobile Documents/com~apple~CloudDocs/Taxes/w2.pdf", home: home))
        XCTAssertFalse(FileSearch.isNoise("/Users/d/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault/Note.md", home: home))
        XCTAssertFalse(FileSearch.isNoise("/Users/d/Library/CloudStorage/GoogleDrive-d@x.com/My Drive/plan.docx", home: home))
        XCTAssertTrue(FileSearch.isNoise("/Users/d/Library/Mobile Documents", home: home), "the container itself isn't a file of yours")
        XCTAssertTrue(FileSearch.isNoise("/Users/d/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault/.obsidian/app.json", home: home))
    }

    func testABetterNameBeatsARecentOneAndRecentBreaksTies() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let exact = FileSearch.Hit(name: "Budget.xlsx", path: "/Users/d/Documents/Budget.xlsx", lastUsed: nil)
        let recentWord = FileSearch.Hit(name: "Old Budget Notes.txt", path: "/Users/d/Documents/Old Budget Notes.txt",
                                        lastUsed: now.addingTimeInterval(-3600))
        let noise = FileSearch.Hit(name: "budget.json", path: "/Users/d/Library/Caches/budget.json", lastUsed: now)
        XCTAssertEqual(FileSearch.rank("budget", [recentWord, noise, exact], home: home, now: now, limit: 5).map(\.name),
                       ["Budget.xlsx", "Old Budget Notes.txt"])
        let a = FileSearch.Hit(name: "Report.pdf", path: "/Users/d/Documents/a/Report.pdf", lastUsed: now.addingTimeInterval(-86_400 * 400))
        let b = FileSearch.Hit(name: "Report.pdf", path: "/Users/d/Documents/b/Report.pdf", lastUsed: now.addingTimeInterval(-600))
        XCTAssertEqual(FileSearch.rank("report", [a, b], home: home, now: now, limit: 1), [b])
    }

    func testAShallowerFileWinsATie() {
        let deep = FileSearch.Hit(name: "notes.md", path: "/Users/d/a/b/c/d/notes.md")
        let shallow = FileSearch.Hit(name: "notes.md", path: "/Users/d/Documents/notes.md")
        XCTAssertEqual(FileSearch.rank("notes", [deep, shallow], home: home, limit: 2), [shallow, deep])
    }

    func testFolderReadsAsPeopleSayIt() {
        XCTAssertEqual(FileSearch.folder(of: "/Users/d/notes.md", home: home), "~")
        XCTAssertEqual(FileSearch.folder(of: "/Users/d/Documents/School/a.pdf", home: home), "~/Documents/School")
        XCTAssertEqual(FileSearch.folder(of: "/Users/d/Library/Mobile Documents/com~apple~CloudDocs/Taxes/w2.pdf", home: home), "iCloud Drive/Taxes")
        XCTAssertEqual(FileSearch.folder(of: "/Users/d/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault/Notes/a.md", home: home),
                       "Obsidian/Vault/Notes")
        XCTAssertEqual(FileSearch.folder(of: "/Users/d/Library/CloudStorage/GoogleDrive-x/My Drive/plan.docx", home: home),
                       "GoogleDrive-x/My Drive")
        XCTAssertEqual(FileSearch.folder(of: "/Volumes/USB/a.txt", home: home), "/Volumes/USB")
    }
}
