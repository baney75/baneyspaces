import AppKit
import SwiftUI
import Vision
import XCTest
@testable import BaneySpaces
@testable import BaneySpacesCore

/// Draws the real overview offscreen with Donovan's load of 2026-11-01 (workspace 1 holding Word,
/// Helium, Obsidian, T3 Code, Excel, Grok Bot and Terminal; the rest empty) and reads the picture back
/// with text recognition: every window must be on screen with its name readable. On the overview
/// of 2026-11-01 the list stopped at "Grok Bot", cut in half, and Terminal was not drawn at all.
/// It uses only what the viewer has always had (`ViewerModel.tiles`, `ViewerView`), so it runs on older builds too.
@MainActor
final class OverviewRenderTests: XCTestCase {
    private let reported: [(app: String, path: String, title: String, word: String)] = [
        ("Microsoft Word", "/Applications/Microsoft Word.app", "Document1", "word"),
        ("Helium", "/Applications/Helium.app", "Quiz question 1 of 13 - Helium", "helium"),
        ("Obsidian", "/Applications/Obsidian.app", "Dashboard - Notes - Obsidian", "obsidian"),
        ("T3 Code (Nightly)", "/Applications/T3 Code (Nightly).app", "", "t3"),
        ("Microsoft Excel", "/Applications/Microsoft Excel.app", "Lab_results_B_and_C", "excel"),
        ("Grok Bot", "/Applications/Grok Bot.app", "", "grok"),
        ("Terminal", "/System/Applications/Utilities/Terminal.app", "", "terminal"),
    ]

    private func image(of view: some View, size: CGSize) -> CGImage? {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.cgImage
    }

    private func words(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").lowercased()
    }

    private func overview(theme: ThemeID) -> ViewerModel {
        Appearance.shared.useDefaultLookWithoutSaving()
        Appearance.shared.settings.theme = theme
        let model = ViewerModel()
        model.current = 1
        for n in 1...9 { model.tiles[n] = [] }
        var id: WindowID = 100
        model.tiles[1] = reported.map { app, path, title, _ in
            id += 1
            model.icons[id] = NSWorkspace.shared.icon(forFile: path)
            return Spaces.Entry(id: id, pid: 0, app: app, title: title)
        }
        return model
    }

    func testEveryOneOfDonovansSevenWindowsIsDrawnAndReadableInEveryTheme() throws {
        // Text recognition must work here at all, or this proves nothing.
        let control = image(of: Text("Quarterly report").font(.system(size: 24)).padding(20).background(Color.black), size: CGSize(width: 400, height: 90))
        try XCTSkipUnless(control.map { words(in: $0).contains("quarterly") } == true, "text recognition isn't available here")

        for theme in ThemeID.allCases {
            let model = overview(theme: theme)
            guard let picture = image(of: ViewerView(model: model, stillBackdrop: true), size: CGSize(width: 1512, height: 945)) else {
                return XCTFail("\(theme): nothing was drawn")
            }
            let seen = words(in: picture)
            for window in reported {
                XCTAssertTrue(seen.contains(window.word), "\(theme): \(window.app) is not on the screen (clipped or missing). Read: \(seen.replacingOccurrences(of: "\n", with: " | "))")
            }
        }
    }
}
