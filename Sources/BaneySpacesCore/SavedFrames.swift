import CoreGraphics
import Foundation

/// Where each hidden window stood before it was hidden. Written to disk on every switch, so if
/// BaneySpaces crashes, the next launch can put windows back where they were.
public struct SavedFrames: Codable, Equatable {
    public var frames: [WindowID: CGRect] = [:]

    public init() {}

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
