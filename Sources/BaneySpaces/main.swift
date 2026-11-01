import AppKit

// `BaneySpaces --render <folder>` draws product images with sample windows, then exits.
if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    exit(MainActor.assumeIsolated { Render.run(into: URL(fileURLWithPath: CommandLine.arguments[i + 1])) })
}

// `BaneySpaces --bangs …` manages the launcher's custom bangs from a terminal or an agent, then exits.
if let i = CommandLine.arguments.firstIndex(of: "--bangs") {
    exit(Launcher.commandLine(Array(CommandLine.arguments[(i + 1)...])))
}

// `BaneySpaces --dump-iphone-apps-shape` prints the structure (names and types, never values) of iPhone
// Mirroring's data that BaneySpaces reads for the launcher's iPhone apps, then exits. macOS may ask first.
if CommandLine.arguments.contains("--dump-iphone-apps-shape") {
    exit(IPhoneAppCache.dumpShape())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
