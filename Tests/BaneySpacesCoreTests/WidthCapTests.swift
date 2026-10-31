import AppKit
import SwiftUI
import XCTest
@testable import BaneySpacesCore

/// The dock label from Donovan's 2026-10-31 recording ran far past the dock. Measured the way the
/// dock lays it out: with no width offered (the panel's fixedSize) and with the 480 pt panel's.
@MainActor
final class WidthCapTests: XCTestCase {
    private let long = "Workspace 1 · Microsoft Word, Helium, T3 Code (Nightly), Grok Bot, Claude, Obsidian, Ghostty, Silas · Claude is working on Fix internal dock layout and the label strip"

    private func label(_ text: String) -> some View {
        WidthCap(max: 420) { Text(text).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail) }
    }

    func testLongTextStopsAtTheCapOnOneLine() {
        for size in [NSHostingView(rootView: label(long).fixedSize()).fittingSize,
                     NSHostingController(rootView: label(long)).sizeThatFits(in: CGSize(width: 480, height: 100))] {
            XCTAssertLessThanOrEqual(size.width, 420)
            XCTAssertLessThan(size.height, 24, "one line")
        }
    }

    func testShortTextHugsItself() {
        for size in [NSHostingView(rootView: label("Show All Workspaces").fixedSize()).fittingSize,
                     NSHostingController(rootView: label("Show All Workspaces")).sizeThatFits(in: CGSize(width: 480, height: 100))] {
            XCTAssertGreaterThan(size.width, 40)
            XCTAssertLessThan(size.width, 200)
        }
    }
}
