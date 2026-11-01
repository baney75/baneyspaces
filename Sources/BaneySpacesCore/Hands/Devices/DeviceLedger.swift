import Foundation

/// Which simulators and emulators an agent may drive: the ones BaneySpaces booted for it, and the ones
/// Donovan lent. Everything else is his. Only the app writes this book; an agent can read nothing of it
/// but its own answers.
public struct DeviceLedger: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var agent: String
        public var bootedAt: Date
        /// The emulator process BaneySpaces started (Android), so a pid that is gone ends the entry.
        public var pid: Int32?
        /// A simulator BaneySpaces created for this agent and deletes when it shuts down.
        public var created: Bool
        public init(id: String, name: String, agent: String, bootedAt: Date, pid: Int32? = nil, created: Bool = false) {
            self.id = id; self.name = name; self.agent = agent; self.bootedAt = bootedAt; self.pid = pid; self.created = created
        }
    }
    public struct Lend: Codable, Equatable, Sendable {
        public var id: String
        public var session: String
        public var until: Date
    }
    public var entries: [Entry] = []
    public var lends: [Lend] = []
    public init() {}

    public func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }
    public func owns(_ id: String) -> Bool { entry(id) != nil }
    public func lent(_ id: String, now: Date) -> Bool { lends.contains { $0.id == id && $0.until > now } }

    public mutating func add(_ e: Entry) { entries.removeAll { $0.id == e.id }; entries.append(e) }
    public mutating func remove(_ id: String) { entries.removeAll { $0.id == id } }
    /// Donovan lends a device (the consent sheet in the app calls this, nothing else).
    public mutating func lend(_ id: String, session: String, now: Date, for seconds: TimeInterval = 1800) {
        lends.removeAll { $0.id == id }
        lends.append(Lend(id: id, session: session, until: now.addingTimeInterval(min(seconds, 1800))))
    }
    @discardableResult
    public mutating func giveBack(_ id: String) -> Bool {
        let had = lends.contains { $0.id == id }
        lends.removeAll { $0.id == id }
        return had
    }
    public mutating func expire(now: Date) { lends.removeAll { $0.until <= now } }
}

/// Where the book lives. The app keeps it in a file under BaneySpaces' own folder; tests keep it in memory.
public protocol DeviceStore: AnyObject {
    func load() -> DeviceLedger
    func save(_ ledger: DeviceLedger)
}

public final class MemoryDeviceStore: DeviceStore {
    public var ledger = DeviceLedger()
    public init() {}
    public func load() -> DeviceLedger { ledger }
    public func save(_ l: DeviceLedger) { ledger = l }
}

public final class FileDeviceStore: DeviceStore {
    let url: URL
    public init(_ url: URL) { self.url = url }
    public func load() -> DeviceLedger {
        guard let data = try? Data(contentsOf: url) else { return DeviceLedger() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode(DeviceLedger.self, from: data)) ?? DeviceLedger()
    }
    public func save(_ l: DeviceLedger) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970; enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(l) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
