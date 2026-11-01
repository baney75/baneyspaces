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

// One-shots the delegate answers and exits on don't count as a launch. `--setup` and a plain
// start do (`CrashLoopGuard`): any other `--` flag used to skip the guard and leave a crash loop
// uncounted.
let crashLoopOneShots: Set<String> = [
    "--restore-shortcuts", "--restore-dock", "--check-settings", "--unregister-login",
]
if Set(CommandLine.arguments).isDisjoint(with: crashLoopOneShots) { CrashLoop.checkLaunch() }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
