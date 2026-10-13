// Fails if any window is seen sliding during a workspace switch. It switches between two
// workspaces through BaneySpaces' URL command and samples every on-screen window's position
// every 4 ms. A window that shows up at three or more positions in one switch moved on screen:
// a slide to or from the parking corner. Run it with BaneySpaces installed and running, with an
// animating app (Helium, Ghostty) on one of the two workspaces.
//   swift scripts/motion-probe.swift 1 4        three round trips between workspaces 1 and 4
//   ROUNDS=5 swift scripts/motion-probe.swift 1 4
// It switches your screen while it runs and ends on the first workspace.
import CoreGraphics
import Foundation

let args = CommandLine.arguments.dropFirst().compactMap(Int.init)
guard args.count == 2, args.allSatisfy({ (1...9).contains($0) }) else {
    FileHandle.standardError.write("usage: swift scripts/motion-probe.swift <from 1-9> <to 1-9>\n".data(using: .utf8)!)
    exit(2)
}
let rounds = Int(ProcessInfo.processInfo.environment["ROUNDS"] ?? "") ?? 3

func snapshot() -> [Int: (app: String, origin: CGPoint)] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var out: [Int: (String, CGPoint)] = [:]
    for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
        guard let id = w[kCGWindowNumber as String] as? Int,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
        out[id] = (w[kCGWindowOwnerName as String] as? String ?? "?", CGPoint(x: b["X"] ?? 0, y: b["Y"] ?? 0))
    }
    return out
}

func switchAndWatch(to space: Int) -> [String] {
    var seen: [Int: (app: String, points: [CGPoint])] = [:]
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-g", "baneyspaces://switch/\(space)"]
    try? task.run()
    let end = Date().addingTimeInterval(0.9)
    while Date() < end {
        for (id, w) in snapshot() {
            var entry = seen[id] ?? (w.app, [])
            if entry.points.last != w.origin { entry.points.append(w.origin) }
            seen[id] = entry
        }
        usleep(4_000)
    }
    return seen.compactMap { id, w in
        Set(w.points.map { "\($0.x),\($0.y)" }).count >= 3
            ? "\(w.app) window \(id) slid through \(w.points.count) positions switching to \(space): "
                + w.points.prefix(6).map { "(\(Int($0.x)),\(Int($0.y)))" }.joined(separator: " ")
            : nil
    }
}

var slides: [String] = []
for _ in 0..<rounds {
    slides += switchAndWatch(to: args[1])
    slides += switchAndWatch(to: args[0])
}
if slides.isEmpty {
    print("no window slid over \(rounds) round trips between workspaces \(args[0]) and \(args[1])")
} else {
    slides.forEach { print($0) }
    exit(1)
}
