import Foundation

// The launcher's search pipeline. 2026-11-01, `trace.log`: `files q=2ch places=31 kept=1000 shown=5
// ms=1299`, then `ms=3103` (and 4,039 and 6,892 for two and three letters earlier). A two-letter name
// search asked Spotlight, sorted by last use and capped at 6,000, for a name prefix that thousands of
// files share. Spotlight cannot start answering before it has sorted them, and a synchronous query
// cannot be stopped: each keystroke queued another query behind the one still running. Targets:
// apps shown in under 16 ms, files in under 100 ms (p90).
//
//   apps         shown at once, from a name index folded once (`AppNameIndex`), never waiting on files
//   files, warm  the same keystroke, from the files you used or changed lately (`FileWarmIndex`)
//   files, full  a short debounce later, from Spotlight, a query that is stopped the moment you type
//                again (`FileSearchFlow`); its results replace the warm ones, ranked together
//
// This file has no Spotlight, no AppKit and no clock of its own, so the order and the timing are tests.

/// Apps by name, folded once. `Fuzzy.score` folds both sides on every call, which is most of the cost of
/// matching a few hundred apps on every keystroke.
public struct AppNameIndex: Sendable {
    private let folded: [String]

    public init(names: [String]) { folded = names.map(Fuzzy.fold) }

    public var count: Int { folded.count }

    /// Indices of the apps that match `typed`, best first: a better name match, then `boost` (recent
    /// and running apps), then the earlier name. `limit` caps what is returned.
    public func rank(_ typed: String, boost: (Int) -> Int = { _ in 0 }, limit: Int) -> [Int] {
        let q = Fuzzy.fold(typed)
        guard !q.isEmpty else { return Array(folded.indices.prefix(limit)) }
        var scored: [(index: Int, score: Int)] = []
        for (i, name) in folded.enumerated() {
            guard let s = Fuzzy.score(folded: q, in: name) else { continue }
            scored.append((i, s + boost(i)))
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.prefix(limit).map(\.index)
    }
}

/// The files you used or changed lately, kept in memory so a short query is answered on the keystroke.
/// Built from Spotlight in the background (`FileWarm` in the app), most recently used first.
public struct FileWarmIndex: Sendable {
    private struct Entry: Sendable {
        let hit: FileSearch.Hit
        let words: [String]
    }
    private let entries: [Entry]
    /// How many matches are ranked: the warm list is ordered by use, so the first ones are the ones that count.
    public static let rankedCap = 400

    public static let empty = FileWarmIndex([], home: "/")

    /// `hits` most recently used first. Noise (Library, hidden and build folders) and repeats are dropped.
    public init(_ hits: [FileSearch.Hit], home: String) {
        var seen = Set<String>()
        entries = hits.compactMap { h in
            guard seen.insert(h.path).inserted, !FileSearch.isNoise(h.path, home: home) else { return nil }
            return Entry(hit: h, words: FileSearch.words(h.name))
        }
    }

    public var count: Int { entries.count }

    /// The best `limit` of the warm files that answer `typed` (the rule Spotlight's query uses).
    public func lookup(_ typed: String, home: String, now: Date = Date(), limit: Int) -> [FileSearch.Hit] {
        let q = typed.trimmingCharacters(in: .whitespaces)
        let words = q.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.contains(where: { $0.count >= FileSearch.minimumQuery }) else { return [] }
        let typedWords = words.flatMap(FileSearch.words)
        guard !typedWords.isEmpty else { return [] }
        var matched: [FileSearch.Hit] = []
        for e in entries where typedWords.allSatisfy({ t in e.words.contains { $0.hasPrefix(t) } }) {
            matched.append(e.hit)
            if matched.count == Self.rankedCap { break }
        }
        return FileSearch.rank(q, matched, home: home, now: now, limit: limit)
    }
}

/// One search a keystroke, in order: warm answer now, Spotlight's later, the older one always stopped.
public final class FileSearchFlow {
    public enum Stage: Equatable, Sendable { case warm, spotlight }
    public typealias Cancel = () -> Void

    /// Starts `work` after `delay`; the returned closure stops it if it hasn't run.
    public typealias Schedule = (TimeInterval, @escaping () -> Void) -> Cancel
    /// Runs the full query for the text. Calls back once with the hits, or with nil if it failed or was
    /// stopped; the returned closure stops it (Spotlight: `MDQueryStop`). May call back on any thread
    /// but must not call back after being stopped.
    public typealias Query = (String, @escaping ([FileSearch.Hit]?) -> Void) -> Cancel

    /// Short: the warm answer is already on screen, and the query can be stopped at no cost.
    public static let debounce: TimeInterval = 0.06

    private let schedule: Schedule
    private let query: Query
    private let warm: () -> FileWarmIndex
    private let home: String
    private let now: () -> Date
    private let lock = NSLock()
    private var generation = 0
    private var stopDebounce: Cancel?
    private var stopQuery: Cancel?

    public init(home: String, debounce: TimeInterval = FileSearchFlow.debounce, now: @escaping () -> Date = Date.init,
                warm: @escaping () -> FileWarmIndex, schedule: @escaping Schedule, query: @escaping Query) {
        self.home = home
        self.warm = warm
        self.schedule = schedule
        self.query = query
        self.now = now
        self.delay = debounce
    }
    private let delay: TimeInterval

    /// Another keystroke. `emit` is called with the warm answer before this returns (an empty list when
    /// the text is too short to search), and later with Spotlight's, unless another keystroke or `cancel`
    /// comes first. `emit` for the later answer runs wherever `Query` calls back; the caller hops to its thread.
    public func typed(_ text: String, limit: Int, emit: @escaping (Stage, [FileSearch.Hit]) -> Void) {
        let q = text.trimmingCharacters(in: .whitespaces)
        lock.lock()
        generation += 1
        let mine = generation
        let oldDebounce = stopDebounce, oldQuery = stopQuery
        stopDebounce = nil
        stopQuery = nil
        lock.unlock()
        oldDebounce?()
        oldQuery?()

        guard FileSearch.spotlightQuery(q) != nil else { return emit(.warm, []) }
        let near = warm().lookup(q, home: home, now: now(), limit: limit)
        emit(.warm, near)

        let cancelDebounce = schedule(delay) { [weak self] in
            guard let self, self.current(mine) else { return }
            let cancelQuery = self.query(q) { [weak self] hits in
                guard let self, self.current(mine), let hits else { return }
                // What Spotlight found and what was already known, ranked as one list.
                // The same file from both is one row, the first (the warm copy is the one already on screen).
                var seen = Set<String>()
                let merged = (near + hits).filter { seen.insert($0.path).inserted }
                emit(.spotlight, FileSearch.rank(q, merged, home: self.home, now: self.now(), limit: limit))
            }
            self.lock.lock()
            if self.generation == mine { self.stopQuery = cancelQuery; self.lock.unlock() } else { self.lock.unlock(); cancelQuery() }
        }
        lock.lock()
        if generation == mine { stopDebounce = cancelDebounce; lock.unlock() } else { lock.unlock(); cancelDebounce() }
    }

    /// Nothing is wanted any more (the launcher closed, or the text isn't for files).
    public func cancel() {
        lock.lock()
        generation += 1
        let oldDebounce = stopDebounce, oldQuery = stopQuery
        stopDebounce = nil
        stopQuery = nil
        lock.unlock()
        oldDebounce?()
        oldQuery?()
    }

    private func current(_ g: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == g }
}
