import CoreGraphics
import Foundation

/// What BaneySpaces has put out of sight: where each parked window stood, and which apps it
/// hid. Written to disk on every switch, so if BaneySpaces crashes, the next launch can put
/// everything back.
public struct SavedFrames: Codable, Equatable {
    public var frames: [WindowID: CGRect] = [:]
    /// Process IDs of apps hidden because none of their windows are on the current workspace.
    public var hiddenApps: Set<Int32> = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frames = try c.decodeIfPresent([WindowID: CGRect].self, forKey: .frames) ?? [:]
        hiddenApps = try c.decodeIfPresent(Set<Int32>.self, forKey: .hiddenApps) ?? []
    }

    public static func load(from url: URL) -> SavedFrames {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(SavedFrames.self, from: data) else { return SavedFrames() }
        return saved
    }

    public func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
