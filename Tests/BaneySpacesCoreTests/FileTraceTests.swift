import XCTest
@testable import BaneySpacesCore

final class FileTraceTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("filetrace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAppendCreatesTheActiveFile() throws {
        try FileTrace.append("hello", directory: dir, maxBytes: 100, maxFiles: 3)
        let text = try String(contentsOf: dir.appendingPathComponent("trace.log"), encoding: .utf8)
        XCTAssertEqual(text, "hello\n")
    }

    func testRotateKeepsPriorContentInDotOne() throws {
        try FileTrace.append(String(repeating: "a", count: 40), directory: dir, maxBytes: 50, maxFiles: 3)
        try FileTrace.append(String(repeating: "b", count: 40), directory: dir, maxBytes: 50, maxFiles: 3)
        let active = try String(contentsOf: dir.appendingPathComponent("trace.log"), encoding: .utf8)
        let one = try String(contentsOf: dir.appendingPathComponent("trace.log.1"), encoding: .utf8)
        XCTAssertTrue(active.hasPrefix("b"))
        XCTAssertTrue(one.hasPrefix("a"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("trace.log.2").path))
    }

    func testThirdRotateDropsTheOldest() throws {
        let fm = FileManager.default
        for ch in ["a", "b", "c", "d"] {
            try FileTrace.append(String(repeating: ch, count: 40), directory: dir, maxBytes: 50, maxFiles: 3)
        }
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("trace.log"), encoding: .utf8).hasPrefix("d"))
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("trace.log.1"), encoding: .utf8).hasPrefix("c"))
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("trace.log.2"), encoding: .utf8).hasPrefix("b"))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("trace.log.3").path))
        let all = try fm.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(all, ["trace.log", "trace.log.1", "trace.log.2"])
    }

    func testMaxFilesOneDeletesInsteadOfKeepingHistory() throws {
        try FileTrace.append(String(repeating: "a", count: 40), directory: dir, maxBytes: 50, maxFiles: 1)
        try FileTrace.append(String(repeating: "b", count: 40), directory: dir, maxBytes: 50, maxFiles: 1)
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("trace.log"), encoding: .utf8).hasPrefix("b"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("trace.log.1").path))
    }

    func testConcurrentAppendsKeepEveryLine() throws {
        let group = DispatchGroup()
        let total = 200
        for i in 0..<total {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                try? FileTrace.append("line-\(i)", directory: self.dir, maxBytes: 2_000, maxFiles: 3)
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        var body = ""
        for name in ["trace.log", "trace.log.1", "trace.log.2"] {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                body += (try String(contentsOf: url, encoding: .utf8))
            }
        }
        for i in 0..<total {
            XCTAssertTrue(body.contains("line-\(i)\n"), "missing line-\(i)")
        }
    }
}
