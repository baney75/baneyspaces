import Foundation

/// When to stop starting after crashes. 11-01: `BaneySpaces --render` crashed and was started
/// again 12 times, about 13 s apart. A build that crashes at launch must not be started over and
/// over while it holds Mission Control off and the macOS Dock out of sight.
///
/// Each start writes a run into the ledger and a clean quit clears it, so a run still there at the
/// next start is a crash (or a force quit, or power lost). After `limit` of them within `window`
/// the next start stops: the app gives back what it took and tells you, and it won't run until
/// you choose Start Anyway or the oldest crash is more than `window` old.
public struct CrashLoopGuard: Equatable {
    public static let defaultLimit = 3
    public static let defaultWindow: TimeInterval = 5 * 60
    /// Settings that override the defaults: `defaults write com.baney.baneyspaces crashLoopLimit 5`.
    public static let limitKey = "crashLoopLimit"
    public static let windowKey = "crashLoopWindowMinutes"

    public enum Decision: Equatable {
        case start
        /// `crashes` within the window, at or over the limit.
        case stop(crashes: Int)
    }

    /// Crashes within `window` that stop the next start; 0 or less never stops.
    public var limit: Int
    public var window: TimeInterval

    public init(limit: Int = defaultLimit, window: TimeInterval = defaultWindow) {
        self.limit = limit
        self.window = window
    }

    /// From the settings, where a missing or nonsensical window keeps the default.
    public init(limit: Int?, windowMinutes: Double?) {
        let minutes = windowMinutes.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        self.init(limit: limit ?? Self.defaultLimit, window: minutes.map { $0 * 60 } ?? Self.defaultWindow)
    }

    /// The crashes that still count: within the window, and none dated after `now` (a clock set back).
    public func recent(_ crashes: [Date], now: Date) -> [Date] {
        crashes.filter { $0 <= now && now.timeIntervalSince($0) < window }
    }

    public func decide(_ crashes: [Date], now: Date) -> Decision {
        let count = recent(crashes, now: now).count
        return limit > 0 && count >= limit ? .stop(crashes: count) : .start
    }
}

/// What the guard keeps between runs.
public struct CrashLedger: Codable, Equatable {
    public struct Run: Codable, Equatable {
        public var pid: Int32
        public var started: Date
        public init(pid: Int32, started: Date) { self.pid = pid; self.started = started }
    }

    /// When each crash was found (at the start after it).
    public var crashes: [Date]
    /// Every start still under way. More than one is rare (a second BaneySpaces while the first
    /// lives); both are kept so a later clean quit of the second cannot erase the first's crash.
    public var running: [Run]

    public init(crashes: [Date] = [], running: [Run] = []) {
        self.crashes = crashes
        self.running = running
    }
}

/// The ledger on disk. Anything it can't read counts as an empty ledger, so a damaged file can
/// never keep the app from starting.
public struct CrashLedgerFile {
    public static let fileName = "crash-ledger.json"
    public static let renderFileName = "crash-ledger-render.json"

    public var url: URL
    public var policy: CrashLoopGuard

    public init(url: URL, policy: CrashLoopGuard) {
        self.url = url
        self.policy = policy
    }

    public func read() -> CrashLedger {
        guard let data = try? Data(contentsOf: url) else { return CrashLedger() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(CrashLedger.self, from: data)) ?? CrashLedger()
    }

    @discardableResult
    public func write(_ ledger: CrashLedger) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(ledger) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// At launch: a run left in the ledger whose process is gone is a crash. Decides, and on
    /// `.start` records this run. `isAlive` says whether a process id is still running (a second
    /// copy started beside the first isn't a crash of the first).
    public func begin(pid: Int32, now: Date, isAlive: (Int32) -> Bool) -> CrashLoopGuard.Decision {
        var ledger = read()
        var still: [CrashLedger.Run] = []
        for run in ledger.running where run.pid != pid {
            if isAlive(run.pid) {
                still.append(run)
            } else {
                ledger.crashes.append(now)
            }
        }
        // Only the crashes that can still count are kept, so the file stays small.
        ledger.crashes = policy.recent(ledger.crashes, now: now)
        let decision = policy.decide(ledger.crashes, now: now)
        if decision == .start { still.append(.init(pid: pid, started: now)) }
        ledger.running = still
        write(ledger)
        return decision
    }

    /// A clean quit: this run is over, and it didn't crash. Other live runs stay recorded. Returns
    /// whether the run was in the ledger.
    @discardableResult
    public func end(pid: Int32) -> Bool {
        var ledger = read()
        let before = ledger.running.count
        ledger.running.removeAll { $0.pid == pid }
        guard ledger.running.count != before else { return false }
        write(ledger)
        return true
    }

    /// Start Anyway: the crashes so far are forgiven. Returns how many there were.
    @discardableResult
    public func forgive() -> Int {
        var ledger = read()
        let n = ledger.crashes.count
        ledger.crashes = []
        write(ledger)
        return n
    }
}
