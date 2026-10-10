// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BaneySpaces",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BaneySpaces", targets: ["BaneySpaces"]),
    ],
    targets: [
        // Which window lives where, and where hidden windows go: no AppKit, fully unit-tested.
        .target(name: "BaneySpacesCore"),
        // The menu bar app: hotkeys, Accessibility, moving real windows.
        .executableTarget(name: "BaneySpaces", dependencies: ["BaneySpacesCore"]),
        .testTarget(name: "BaneySpacesCoreTests", dependencies: ["BaneySpacesCore"]),
    ]
)
