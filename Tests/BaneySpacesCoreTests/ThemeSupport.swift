import Foundation
import XCTest
@testable import BaneySpacesCore

/// Where the repository's files are, for tests that read spec/ or the view sources.
enum Repo {
    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    static func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
    /// Code only: line comments dropped.
    static func code(_ path: String) throws -> String {
        try text(path).split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
    }
}

/// Runs `body` in a theme and puts the BaneySpaces theme back.
func inTheme<T>(_ id: ThemeID, _ body: () throws -> T) rethrows -> T {
    ThemeCenter.use(id)
    defer { ThemeCenter.use(.baneyspaces) }
    return try body()
}
