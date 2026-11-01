import AppKit

// `BaneySpaces --render <folder>` draws product images with sample windows, then exits.
if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    CrashLoop.checkRender()
    let code = MainActor.assumeIsolated { Render.run(into: URL(fileURLWithPath: CommandLine.arguments[i + 1])) }
    CrashLoop.renderEnded()
    exit(code)
}

// `BaneySpaces --bangs …` manages the launcher's custom bangs from a terminal or an agent, then exits.
if let i = CommandLine.arguments.firstIndex(of: "--bangs") {
    exit(Launcher.commandLine(Array(CommandLine.arguments[(i + 1)...])))
}

// A plain launch (the one-shot `--` commands the delegate answers don't count) stops after
// repeated crashes instead of crashing again (`CrashLoopGuard`).
if !CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) { CrashLoop.checkLaunch() }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
