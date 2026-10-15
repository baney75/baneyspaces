import CoreGraphics
import XCTest
@testable import BaneySpacesCore

final class GridTests: XCTestCase {
    let laptop = CGRect(x: 0, y: 33, width: 1512, height: 909)

    func testColumnsPerCount() {
        XCTAssertEqual(Grid.columns(for: 1, in: laptop.size), 1)
        XCTAssertEqual(Grid.columns(for: 2, in: laptop.size), 2)
        XCTAssertEqual(Grid.columns(for: 3, in: laptop.size), 2)
        XCTAssertEqual(Grid.columns(for: 4, in: laptop.size), 2)
        XCTAssertEqual(Grid.columns(for: 6, in: laptop.size), 3)
        XCTAssertEqual(Grid.columns(for: 9, in: laptop.size), 3)
    }

    func testFramesFillTheAreaWithoutOverlap() {
        for n in 1...9 {
            let frames = Grid.frames(count: n, in: laptop, gap: 6)
            XCTAssertEqual(frames.count, n)
            for f in frames { XCTAssertTrue(laptop.insetBy(dx: -1, dy: -1).contains(f), "\(n): \(f) leaves the area") }
            for i in frames.indices { for j in frames.indices where i < j {
                XCTAssertTrue(frames[i].insetBy(dx: 1, dy: 1).intersection(frames[j].insetBy(dx: 1, dy: 1)).isNull, "\(n): \(i) overlaps \(j)")
            } }
            // Every row reaches the right edge: no hole left behind.
            let rights = Dictionary(grouping: frames, by: \.minY).values.map { $0.map(\.maxX).max()! }
            for r in rights { XCTAssertEqual(r, laptop.maxX, accuracy: 2) }
        }
    }

    func testThreeWindowsLastOneSpansTheBottom() {
        let f = Grid.frames(count: 3, in: laptop, gap: 6)
        XCTAssertEqual(f[0].minY, f[1].minY)
        XCTAssertEqual(f[2].width, laptop.width, accuracy: 1)
        XCTAssertGreaterThan(f[2].minY, f[0].maxY)
    }
}

final class ActivityTests: XCTestCase {
    func testClaudeTitles() {
        XCTAssertEqual(Activity.of(title: "✳ Baney spaces opening many windows"), .waiting)
        XCTAssertEqual(Activity.of(title: "◐ Ghostty multi-window tiling manager"), .working)
        XCTAssertEqual(Activity.of(title: "⠂ Claude Code"), .working)
        XCTAssertEqual(Activity.of(title: "baney@mac ~/Projects"), .shell)
        XCTAssertEqual(Activity.of(title: ""), .shell)
        XCTAssertEqual(Activity.label(of: "◑ Myelinate v2.3.1 release"), "Myelinate v2.3.1 release")
        XCTAssertEqual(Activity.label(of: "vim notes.md"), "vim notes.md")
    }
}

final class SnapshotTests: XCTestCase {
    static func raw(_ front: String, _ rows: [[String]]) -> String {
        ([front] + rows.map { $0.joined(separator: String(Snapshot.fieldSeparator)) })
            .joined(separator: String(Snapshot.recordSeparator))
    }

    func testParseAndFocus() {
        let s = Snapshot.parse(Self.raw("w2", [
            ["w1", "t1", "1", "true", "true", "a", "✳ one", "/Users/x"],
            ["w2", "t2", "1", "false", "true", "b", "◐ two\twith tab", ""],
            ["w2", "t3", "2", "true", "false", "c", "zsh", "/tmp"],
            ["w2", "t3", "2", "true", "true", "d", "line\nbreak", "/tmp"],
        ]) + "\n")
        XCTAssertEqual(s.frontWindowID, "w2")
        XCTAssertEqual(s.terminals.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(s.terminals[1].title, "◐ two\twith tab")
        XCTAssertEqual(s.terminals[3].title, "line\nbreak")
        XCTAssertEqual(s.focusedID, "d")
        XCTAssertEqual(s.windows.map(\.id), ["w1", "w2"])
        XCTAssertEqual(s.windows[1].terminals.count, 3)
    }

    func testEmptyAndMalformed() {
        XCTAssertEqual(Snapshot.parse("").terminals, [])
        XCTAssertEqual(Snapshot.parse(Self.raw("", [["too", "few"]])).terminals, [])
    }

    func testShortPath() {
        XCTAssertEqual(Snapshot.shortPath("/Users/x/Projects/a", home: "/Users/x"), "~/Projects/a")
        XCTAssertEqual(Snapshot.shortPath("/Users/x", home: "/Users/x"), "~")
        XCTAssertEqual(Snapshot.shortPath("/Users/xy", home: "/Users/x"), "/Users/xy")
    }
}

final class AttentionTests: XCTestCase {
    func snap(_ terms: [(String, String)]) -> Snapshot {
        Snapshot(frontWindowID: "w", terminals: terms.map {
            Terminal(windowID: "w", tabID: "t", tabIndex: 1, tabSelected: true, focusedInTab: false,
                     id: $0.0, title: $0.1, directory: "")
        })
    }

    func testFinishedElsewhereIsUnseenUntilLookedAt() {
        var a = Attention()
        a.update(snap([("a", "◐ x"), ("b", "◐ y")]), focused: nil)
        XCTAssertEqual(a.unseen, [])
        a.update(snap([("a", "✳ x"), ("b", "◐ y")]), focused: nil)
        XCTAssertEqual(a.unseen, ["a"])
        a.update(snap([("a", "✳ x"), ("b", "✳ y")]), focused: nil)
        XCTAssertEqual(a.unseen, ["b", "a"], "newest first")
        a.update(snap([("a", "✳ x"), ("b", "✳ y")]), focused: "b")
        XCTAssertEqual(a.unseen, ["a"])
    }

    func testFinishingInFrontOfYouIsNotUnseen() {
        var a = Attention()
        a.update(snap([("a", "◐ x")]), focused: "a")
        a.update(snap([("a", "✳ x")]), focused: "a")
        XCTAssertEqual(a.unseen, [])
    }

    func testIdleAtLaunchIsNotUnseen() {
        var a = Attention()
        a.update(snap([("a", "✳ x")]), focused: nil)
        XCTAssertEqual(a.unseen, [])
    }

    func testWorkingAgainOrClosedClears() {
        var a = Attention()
        a.update(snap([("a", "◐ x"), ("b", "◐ y")]), focused: nil)
        a.update(snap([("a", "✳ x"), ("b", "✳ y")]), focused: nil)
        a.update(snap([("a", "◑ x")]), focused: nil)
        XCTAssertEqual(a.unseen, [])
    }
}
