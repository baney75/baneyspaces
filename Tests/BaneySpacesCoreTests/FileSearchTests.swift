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
        XCTAssertTrue(FileSearch.isNoise("/Users/d/Projects/silas/src-tauri/target/debug/deps/cfb.d", home: home))
        XCTAssertFalse(FileSearch.isNoise("/Users/d/Documents/target/plan.md", home: home), "a folder named target with your own files")
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

    func testTheSamePathTwiceIsOneRow() {
        let spotlight = FileSearch.Hit(name: "Documents", path: "/Users/d/Documents", lastUsed: Date())
        let listed = FileSearch.Hit(name: "Documents", path: "/Users/d/Documents")
        XCTAssertEqual(FileSearch.rank("doc", [spotlight, listed], home: home, limit: 5), [spotlight])
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

    /// One-letter words alone match most of the disk, however many there are.
    func testOneLetterWordsAloneAreTooLittle() {
        XCTAssertNil(FileSearch.spotlightQuery("a b"))
        XCTAssertNil(FileSearch.spotlightQuery("x y z"))
        XCTAssertNotNil(FileSearch.spotlightQuery("a tax"))
    }

    /// Words as Spotlight breaks them, so the check here agrees with the query.
    func testWordsBreakLikeSpotlight() {
        XCTAssertEqual(FileSearch.words("math_syllabus_page4.png"), ["math", "syllabus", "page", "4", "png"])
        XCTAssertEqual(FileSearch.words("BaneySpacesCore"), ["baney", "spaces", "core"])
        XCTAssertEqual(FileSearch.words("2025 Tax Return.pdf"), ["2025", "tax", "return", "pdf"])
        XCTAssertTrue(FileSearch.matches("tax 2025", "2025 Tax Return.pdf"))
        XCTAssertTrue(FileSearch.matches("ret tax", "2025 Tax Return.pdf"))
        XCTAssertFalse(FileSearch.matches("tax 25", "2025 Tax Return.pdf"), "25 doesn't start a word of 2025")
        XCTAssertTrue(FileSearch.matches("syllabus", "math_syllabus_page4.png"))
        XCTAssertFalse(FileSearch.matches("budgetx", "Budget.xlsx"), "an older search's file that no longer matches")
        // Typed words break the same way (Opus D round 2, high): full names, digits, punctuation.
        XCTAssertTrue(FileSearch.matches("readme.md", "README.md"))
        XCTAssertTrue(FileSearch.matches("page4", "math_syllabus_page4.png"))
        XCTAssertTrue(FileSearch.matches("q3", "Q3 Report.pdf"))
        XCTAssertTrue(FileSearch.matches("my-file", "my-file.txt"))
        XCTAssertTrue(FileSearch.matches("mp3", "song.mp3"))
        XCTAssertFalse(FileSearch.matches("a b", "a b.txt"), "too little to search for")
    }

    /// Words typed in another order than the name's still score as words, never below a name
    /// that only has the letters scattered in order.
    func testWordsInAnotherOrderRankAsWords() {
        let reversed = FileSearch.Hit(name: "2025 Tax Return.pdf", path: "/Users/d/Documents/2025 Tax Return.pdf")
        let scattered = FileSearch.Hit(name: "Tax documents for the year of 2025.pdf", path: "/Users/d/Documents/Tax documents for the year of 2025.pdf")
        XCTAssertEqual(FileSearch.rank("tax 2025", [scattered, reversed], home: home, limit: 2).first, reversed)
    }

    /// A file at the top of iCloud Drive is as near as one at the top of the home folder.
    func testCloudFilesAreNotFartherAway() {
        XCTAssertEqual(FileSearch.depth("/Users/d/Library/Mobile Documents/com~apple~CloudDocs/Plan.pdf", home: home), 0)
        XCTAssertEqual(FileSearch.depth("/Users/d/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault/a.md", home: home), 1)
        XCTAssertEqual(FileSearch.depth("/Users/d/Library/CloudStorage/OneDrive-X/Plan.pdf", home: home), 0)
        XCTAssertEqual(FileSearch.depth("/Users/d/Plan.pdf", home: home), 0)
        XCTAssertEqual(FileSearch.depth("/Users/d/Documents/Plan.pdf", home: home), 1)
    }
}
