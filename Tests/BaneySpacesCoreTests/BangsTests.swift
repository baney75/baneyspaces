import XCTest
@testable import BaneySpacesCore

final class BangsTests: XCTestCase {
    func testBangAtEitherEnd() {
        XCTAssertEqual(Bangs.parse("!yt cats playing"), .init(trigger: "yt", terms: "cats playing"))
        XCTAssertEqual(Bangs.parse("cats playing !YT"), .init(trigger: "yt", terms: "cats playing"))
        XCTAssertEqual(Bangs.parse("!gh"), .init(trigger: "gh", terms: ""))
        XCTAssertNil(Bangs.parse("cats"))
        XCTAssertNil(Bangs.parse("!"))
        XCTAssertNil(Bangs.parse("wow! cats"))
        XCTAssertNil(Bangs.parse("   "))
    }

    func testWordsAreEncodedAndCannotBreakTheAddress() throws {
        let yt = try XCTUnwrap(Bangs.find("yt", in: Bangs.builtIn))
        XCTAssertEqual(yt.address(for: "tom & jerry #1")?.absoluteString,
                       "https://www.youtube.com/results?search_query=tom%20%26%20jerry%20%231")
        XCTAssertEqual(yt.address(for: "café")?.absoluteString, "https://www.youtube.com/results?search_query=caf%C3%A9")
    }

    func testNoWordsGoesToTheSite() throws {
        XCTAssertEqual(try XCTUnwrap(Bangs.find("gh", in: Bangs.builtIn)).address(for: " ")?.absoluteString, "https://github.com/")
        XCTAssertEqual(try XCTUnwrap(Bangs.find("maps", in: Bangs.builtIn)).address(for: "")?.absoluteString, "https://www.google.com/maps")
    }

    func testUnknownBangsGoToDuckDuckGo() {
        XCTAssertNil(Bangs.find("zzz", in: Bangs.builtIn))
        XCTAssertEqual(Bangs.fallbackAddress(trigger: "imdb2", terms: "dune")?.absoluteString,
                       "https://duckduckgo.com/?q=%21imdb2%20dune")
    }

    func testCustomBangsReplaceBuiltInsAndUnsafeOnesAreDropped() {
        let custom = [Bang(trigger: "G", name: "My Google", url: "https://example.com/?q={q}"),
                      Bang(trigger: "evil", name: "Evil", url: "file:///etc/passwd?{q}"),
                      Bang(trigger: "js", name: "Script", url: "javascript:alert({q})")]
        let all = Bangs.all(custom: custom)
        XCTAssertEqual(Bangs.find("g", in: all)?.name, "My Google")
        XCTAssertNil(Bangs.find("evil", in: all))
        XCTAssertNil(Bangs.find("js", in: all))
        XCTAssertEqual(all.filter { $0.trigger == "g" }.count, 1)
    }

    func testAgentsGetTheQuestionInANewChat() throws {
        let claude = try XCTUnwrap(Bangs.find("claude", in: Bangs.builtIn))
        XCTAssertTrue(claude.isAgent)
        XCTAssertEqual(claude.address(for: "why is the sky blue?")?.absoluteString,
                       "https://claude.ai/new?q=why%20is%20the%20sky%20blue%3F")
        XCTAssertEqual(claude.address(for: "")?.absoluteString, "https://claude.ai/new")
        XCTAssertFalse(try XCTUnwrap(Bangs.find("yt", in: Bangs.builtIn)).isAgent)
        XCTAssertEqual(Set(Bangs.builtIn.map(\.trigger)).count, Bangs.builtIn.count, "every trigger is unique")
    }

    func testSuggestionsByTriggerThenName() {
        let s = Bangs.suggest("y", in: Bangs.builtIn).map(\.trigger)
        XCTAssertEqual(s.first, "yt")
        XCTAssertTrue(Bangs.suggest("wiki", in: Bangs.builtIn).map(\.trigger).contains("w"))
        XCTAssertEqual(Bangs.suggest("", in: Bangs.builtIn, limit: 3).count, 3)
    }

    func testAddingValidatesAndReplaces() {
        XCTAssertNotNil(Bangs.problem(trigger: "", name: "X", url: "https://x.com/{q}"))
        XCTAssertNotNil(Bangs.problem(trigger: "two words", name: "X", url: "https://x.com/{q}"))
        XCTAssertNotNil(Bangs.problem(trigger: "x", name: "", url: "https://x.com/{q}"))
        XCTAssertNotNil(Bangs.problem(trigger: "x", name: "X", url: "https://x.com/"))
        XCTAssertNotNil(Bangs.problem(trigger: "x", name: "X", url: "javascript:{q}"))
        XCTAssertNil(Bangs.problem(trigger: "!Jira", name: "Jira", url: "https://acme.atlassian.net/browse/{q}"))
        let one = Bangs.adding(Bang(trigger: "!Jira", name: " Jira ", url: "https://a/{q}"), to: [])
        XCTAssertEqual(one?.map(\.trigger), ["jira"])
        XCTAssertEqual(one?.first?.name, "Jira")
        let two = Bangs.adding(Bang(trigger: "jira", name: "Jira 2", url: "https://b/{q}"), to: one ?? [])
        XCTAssertEqual(two?.map(\.name), ["Jira 2"])
        XCTAssertNil(Bangs.adding(Bang(trigger: "x", name: "X", url: "file:///{q}"), to: []))
    }

    func testCustomFileSurvivesBadEntriesAndDuplicates() {
        let json = """
        [{"trigger": "a1", "name": "A", "url": "https://a.example/{q}"},
         {"trigger": "b1", "url": "https://b.example/{q}"},
         {"trigger": "Jira", "name": "Jira", "url": "https://j.example/{q}"},
         {"trigger": "jira", "name": "Jira 2", "url": "https://j2.example/{q}"},
         {"trigger": "!x", "name": "X", "url": "https://x.example/{q}"}]
        """
        let r = Bangs.decodeCustom(Data(json.utf8))
        XCTAssertTrue(r.readable)
        XCTAssertEqual(r.bangs.map(\.trigger), ["a1", "jira", "x"])
        XCTAssertEqual(r.bangs.first { $0.trigger == "jira" }?.name, "Jira")
        XCTAssertEqual(r.problems.count, 2)
        XCTAssertFalse(Bangs.decodeCustom(Data("[{“trigger”: 1}]".utf8)).readable)
        XCTAssertEqual(Bangs.all(custom: [Bang(trigger: "Jira", name: "J", url: "https://j/{q}"), Bang(trigger: "jira", name: "K", url: "https://k/{q}")])
            .filter { $0.trigger == "jira" }.count, 1)
    }

    func testSiteKeepsItsPort() {
        let b = Bang(trigger: "dev", name: "Dev", url: "http://localhost:3000/search?q={q}")
        XCTAssertEqual(b.address(for: "")?.absoluteString, "http://localhost:3000/")
        XCTAssertEqual(Bang(trigger: "a", name: "A", url: "https://acme.example:8443/x/{q}").address(for: "")?.absoluteString, "https://acme.example:8443/")
    }
}
