// Measures the launcher's file search on this Mac's real Spotlight index: the path before the fix
// (one synchronous Spotlight query a keystroke, sorted by last use, capped at 6,000, queued behind the
// one before it) against the path after it (the warm list answers the keystroke, Spotlight's query is
// stopped by the next one). Reads your index only; touches no windows, keys or pointer.
//
//   scripts/launcher-files-timing.sh          (builds this with the Core sources it uses, then runs it)
//
// Prints one line per measure: p50 and p90 in ms over every query and round.
import Foundation
import CoreServices

@main
struct Timing {
    static let queries = ["ph", "ma", "co", "pr", "re", "in", "st", "sh", "do", "ba"]
    static let attributes = [kMDItemFSName, kMDItemLastUsedDate, kMDItemFSContentChangeDate] as [CFString]
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static func scopes() -> [String] {
        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(atPath: home)) ?? []
        let own = top.filter { name in
            var dir: ObjCBool = false
            return !name.hasPrefix(".") && name != "Library" && fm.fileExists(atPath: home + "/" + name, isDirectory: &dir) && dir.boolValue
        }.map { home + "/" + $0 }
        return own + FileSearch.cloudFolders.sorted().map { home + "/Library/" + $0 }.filter { fm.fileExists(atPath: $0) }
    }

    /// The query as it was before: synchronous, sorted by last use, 6,000 matches, 0.3 s of path reads.
    static func old(_ text: String, _ places: [String]) -> [FileSearch.Hit] {
        search(text, places, maxCount: 6_000, keep: 1_000, budget: 0.3, stop: nil)
    }

    static func search(_ text: String, _ places: [String], maxCount: Int, keep: Int, budget: TimeInterval,
                       stop: ((MDQuery) -> Void)?) -> [FileSearch.Hit] {
        guard let q = MDQueryCreate(kCFAllocatorDefault, text as CFString, attributes as CFArray, [kMDItemLastUsedDate] as CFArray) else { return [] }
        MDQuerySetSearchScope(q, places as CFArray, 0)
        MDQuerySetMaxCount(q, maxCount)
        stop?(q)
        guard MDQueryExecute(q, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var out: [FileSearch.Hit] = []
        let until = Date().addingTimeInterval(budget)
        for i in 0..<MDQueryGetResultCount(q) where out.count < keep {
            if i % 200 == 199, Date() > until { break }
            guard let raw = MDQueryGetResultAtIndex(q, i),
                  let path = MDItemCopyAttribute(Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue(), kMDItemPath) as? String,
                  !FileSearch.isNoise(path, home: home) else { continue }
            out.append(FileSearch.Hit(name: (path as NSString).lastPathComponent, path: path))
        }
        return out
    }

    static func percentile(_ v: [Double], _ p: Double) -> Double { v.sorted()[min(v.count - 1, Int(Double(v.count) * p))] }
    static func line(_ label: String, _ v: [Double]) {
        print(String(format: "%-46@ p50 %7.1f ms   p90 %7.1f ms   max %7.1f ms   (n=%d)", label as NSString, percentile(v, 0.5), percentile(v, 0.9), v.max() ?? 0, v.count))
    }
    static func ms(_ body: () -> Void) -> Double {
        let t = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
    }

    static func main() {
        let places = scopes()
        print("home \(home), \(places.count) places, \(queries.count) two-letter queries")

        // Before: each query run the way the launcher ran it.
        var before: [Double] = []
        for round in 0..<2 {
            for q in queries { before.append(ms { _ = old(FileSearch.spotlightQuery(q)!, places) }); _ = round }
        }
        line("before: two-letter query, sync sorted Spotlight", before)

        // After: the warm list is read once in the background...
        let recent = "(kMDItemLastUsedDate >= $time.today(-90) || kMDItemFSContentChangeDate >= $time.today(-30)) && kMDItemContentType != \"com.apple.application-bundle\""
        var hits: [FileSearch.Hit] = []
        let built = ms { hits = search(recent, places, maxCount: 6_000, keep: 6_000, budget: 2, stop: nil) }
        let index = FileWarmIndex(hits, home: home)
        print(String(format: "warm list: %d files, built in %.0f ms in the background (when the app starts, then every 2 minutes)", index.count, built))

        // ...and answers each keystroke from memory.
        var warm: [Double] = []
        for _ in 0..<20 { for q in queries { warm.append(ms { _ = index.lookup(q, home: home, limit: 5) }) } }
        line("after: warm answer on the keystroke", warm)

        // Spotlight's full answer still follows, and the next keystroke stops it.
        var stopped: [Double] = []
        for q in queries {
            var query: MDQuery?
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                _ = search(FileSearch.spotlightQuery(q)!, places, maxCount: 6_000, keep: 1_000, budget: 0.3, stop: { query = $0 })
                done.signal()
            }
            usleep(40_000)
            let t = DispatchTime.now().uptimeNanoseconds
            if let query { MDQueryStop(query) }
            done.wait()
            stopped.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
        }
        line("after: time for the next keystroke to stop a query", stopped)

        let ok = percentile(warm, 0.9) < 100
        print(ok ? "PASS: warm files p90 under 100 ms" : "FAIL: warm files p90 over 100 ms")
        exit(ok ? 0 : 1)
    }
}
