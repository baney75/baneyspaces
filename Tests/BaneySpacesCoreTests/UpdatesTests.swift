import XCTest
@testable import BaneySpacesCore

final class UpdatesTests: XCTestCase {
    let iso = ISO8601DateFormatter()
    func date(_ s: String) -> Date { iso.date(from: s)! }

    func release(_ tag: String, commit: String? = nil, date: String? = nil, pre: Bool = false) -> Release {
        let marker = commit.map { "\n<!-- baneyspaces commit=\($0) date=\(date!) -->" } ?? ""
        return Release(tag: tag, name: tag, notes: "Notes for \(tag).\(marker)", prerelease: pre, url: "")
    }

    func testMarkerIsReadAndHiddenFromNotes() {
        let r = release("nightly", commit: "abc1234def", date: "2026-10-12T07:00:00Z", pre: true)
        XCTAssertEqual(r.commit, "abc1234def")
        XCTAssertEqual(r.commitDate, date("2026-10-12T07:00:00Z"))
        XCTAssertEqual(r.notes, "Notes for nightly.")
    }

    func testVersionsCompareNumerically() {
        XCTAssertLessThan(Version("v0.2.9")!, Version("v0.2.10")!)
        XCTAssertLessThan(Version("0.2")!, Version("0.2.1")!)
        XCTAssertNil(Version("nightly"))
        XCTAssertNil(Version("v1.2.x"))
    }

    func testStableOffersOnlyANewerTaggedRelease() {
        let build = BuildInfo(version: "0.2.1", commit: "aaaaaaa", commitDate: date("2026-10-11T12:00:00Z"))
        let old = release("v0.2.1")
        let next = release("v0.2.2", commit: "bbbbbbb", date: "2026-10-13T12:00:00Z")
        let nightly = release("nightly", commit: "ccccccc", date: "2026-10-14T07:00:00Z", pre: true)
        XCTAssertNil(Updates.offer(from: [old], channel: .stable, build: build))
        XCTAssertEqual(Updates.offer(from: [nightly, next, old], channel: .stable, build: build)?.tag, "v0.2.2")
    }

    func testNightlyOffersTheNewestOfNightlyAndStable() {
        let build = BuildInfo(version: "0.2.1", commit: "aaaaaaa", commitDate: date("2026-10-11T12:00:00Z"))
        let stable = release("v0.2.2", commit: "bbbbbbb", date: "2026-10-13T12:00:00Z")
        let nightly = release("nightly", commit: "ccccccc", date: "2026-10-14T07:00:00Z", pre: true)
        XCTAssertEqual(Updates.offer(from: [nightly, stable], channel: .nightly, build: build)?.tag, "nightly")
        let staleNightly = release("nightly", commit: "ddddddd", date: "2026-10-12T07:00:00Z", pre: true)
        XCTAssertEqual(Updates.offer(from: [staleNightly, stable], channel: .nightly, build: build)?.tag, "v0.2.2")
    }

    func testNeverOffersTheBuildYouHaveOrAnOlderOne() {
        let build = BuildInfo(version: "0.2.1", commit: "ccccccc1234", commitDate: date("2026-10-14T07:00:00Z"))
        let same = release("nightly", commit: "ccccccc", date: "2026-10-14T07:00:00Z", pre: true)
        let older = release("v0.2.2", commit: "bbbbbbb", date: "2026-10-13T12:00:00Z")
        XCTAssertNil(Updates.offer(from: [same, older], channel: .nightly, build: build))
        // Leaving nightly for stable waits for a stable release newer than this build.
        XCTAssertNil(Updates.offer(from: [same, older], channel: .stable, build: build))
    }

    func testOnlyBaneySpacesTagsAreInstallable() {
        XCTAssertTrue(release("v0.3.0").isInstallable)
        XCTAssertTrue(release("nightly").isInstallable)
        XCTAssertFalse(release("v0.3.0; rm -rf ~").isInstallable)
        XCTAssertFalse(release("main").isInstallable)
    }

    func testGitHubListSkipsDrafts() {
        let json = #"[{"tag_name":"v0.3.0","name":"0.3.0","body":"x","prerelease":false,"draft":true,"html_url":"u"},{"tag_name":"nightly","name":"Nightly","body":"y","prerelease":true,"draft":false,"html_url":"u"}]"#
        XCTAssertEqual(Release.list(fromGitHubJSON: Data(json.utf8)).map(\.tag), ["nightly"])
    }
}
