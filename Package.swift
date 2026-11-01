// swift-tools-version: 5.9
import Foundation
import PackageDescription

// The hands engine (agent-desktop's C library, built by scripts/build-engine.sh into engine/lib).
// An absolute path, because the linker's working directory isn't always the package's.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

// scripts/ holds many files; the cursor probe is the only one SwiftPM builds.
let scriptsExceptTheProbe = ((try? FileManager.default.contentsOfDirectory(atPath: root + "/scripts")) ?? []).filter { $0 != "cursor-probe.swift" }

let package = Package(
    name: "BaneySpaces",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BaneySpaces", targets: ["BaneySpaces"]),
        .executable(name: "baneyspaces-cli", targets: ["baneyspaces-cli"]),
    ],
    targets: [
        // Which window lives where, and where hidden windows go: no AppKit, fully unit-tested.
        .target(name: "BaneySpacesCore"),
        // agent-desktop's C header, for the hands engine in the app.
        .systemLibrary(name: "CAgentDesktop", path: "Sources/CAgentDesktop"),
        // The agent cursor's renderer: Core Animation layers in click-through overlay panels. AppKit, no SwiftUI.
        .target(name: "BaneySpacesCursor", dependencies: ["BaneySpacesCore"]),
        // The menu bar app: hotkeys, Accessibility, moving real windows, and the hands agents use.
        // The engine's library sits in Contents/Frameworks in the bundle; `engine/lib` is where a
        // `swift build` finds it.
        .executableTarget(
            name: "BaneySpaces",
            dependencies: ["BaneySpacesCore", "BaneySpacesCursor", "CAgentDesktop"],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(root)/engine/lib", "-lagent_desktop_ffi",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "\(root)/engine/lib",
                ]),
            ]),
        // `baneyspaces`, the Deck's command for hooks, agents and you. Foundation only, so it starts in milliseconds.
        .executableTarget(name: "baneyspaces-cli", dependencies: ["BaneySpacesCore"]),
        // `swift run -c release cursor-probe`: 100 glides on an offscreen overlay, frame times and the real pointer.
        .executableTarget(name: "cursor-probe", dependencies: ["BaneySpacesCore", "BaneySpacesCursor"],
                          path: "scripts", exclude: scriptsExceptTheProbe),
        .testTarget(name: "BaneySpacesCoreTests", dependencies: ["BaneySpacesCore"]),
        // Draws the real overview offscreen and reads it back (OverviewRenderTests).
        .testTarget(name: "BaneySpacesAppTests", dependencies: ["BaneySpaces", "BaneySpacesCore"]),
        // The overlay's real layers: marks attached, cursors surviving a display change, the panel never key or main.
        .testTarget(name: "BaneySpacesCursorTests", dependencies: ["BaneySpacesCore", "BaneySpacesCursor"]),
    ]
)
