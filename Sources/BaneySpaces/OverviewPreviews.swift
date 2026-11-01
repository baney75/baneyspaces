import AppKit
import BaneySpacesCore
import ScreenCaptureKit

/// Live previews for the overview's cards: a picture of each window, by its window id, taken with
/// ScreenCaptureKit when Screen Recording is already granted. It never asks: `CGPreflightScreenCaptureAccess`
/// only reads the answer. What was taken is kept, so the next time the overview opens its first
/// frame already has previews, and live ones replace them as they arrive.
/// Used from the main thread only.
final class OverviewPreviews {
    static let shared = OverviewPreviews()

    private(set) var cache: [WindowID: NSImage] = [:]
    private var inFlight = false
    /// The widest a preview is taken, in pixels: cards are never bigger than a few hundred points.
    static let width = 720
    /// Previews kept at most; windows that have closed are dropped first.
    static let limit = 160

    /// Screen Recording is granted. Only reads the answer; never shows the prompt.
    static var allowed: Bool { CGPreflightScreenCaptureAccess() }

    /// What is known now, for the windows asked about.
    func known(_ ids: [WindowID]) -> [WindowID: NSImage] {
        var out: [WindowID: NSImage] = [:]
        for id in ids { if let image = cache[id] { out[id] = image } }
        return out
    }

    /// Takes a fresh picture of each window and hands each over as it arrives. Does nothing without
    /// permission, or while an earlier round is still running.
    func refresh(_ ids: [WindowID], each: @escaping (WindowID, NSImage) -> Void) {
        guard Self.allowed, !inFlight, !ids.isEmpty, #available(macOS 14, *) else { return }
        inFlight = true
        prune(keeping: Set(ids))
        let wanted = ids
        Task.detached(priority: .userInitiated) { [weak self] in
            await Self.capture(wanted) { id, image in
                DispatchQueue.main.async {
                    self?.cache[id] = image
                    each(id, image)
                }
            }
            DispatchQueue.main.async { self?.inFlight = false }
        }
    }

    private func prune(keeping ids: Set<WindowID>) {
        if cache.count > Self.limit { cache = cache.filter { ids.contains($0.key) } }
        if cache.count > Self.limit { cache = Dictionary(uniqueKeysWithValues: cache.prefix(Self.limit).map { ($0.key, $0.value) }) }
    }

    @available(macOS 14, *)
    private static func capture(_ ids: [WindowID], deliver: @escaping @Sendable (WindowID, NSImage) -> Void) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        // A few at a time: each is a trip to the window server.
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for id in ids {
                guard let w = byID[id], w.frame.width > 1, w.frame.height > 1 else { continue }
                if running >= 4 { await group.next(); running -= 1 }
                running += 1
                group.addTask {
                    let cfg = SCStreamConfiguration()
                    let scale = min(1, CGFloat(width) / (w.frame.width * 2))
                    cfg.width = max(2, Int(w.frame.width * 2 * scale))
                    cfg.height = max(2, Int(w.frame.height * 2 * scale))
                    cfg.showsCursor = false
                    guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg),
                          Self.isNotBlank(image) else { return }
                    deliver(id, NSImage(cgImage: image, size: NSSize(width: w.frame.width, height: w.frame.height)))
                }
            }
        }
    }

    /// A window the window server can't draw (a hidden app's) comes back fully transparent: that is no picture.
    private static func isNotBlank(_ image: CGImage) -> Bool {
        guard image.width > 1, image.height > 1 else { return false }
        // Sample a few pixels' alpha through a 1x1 context.
        var sample: [UInt8] = [0, 0, 0, 0]
        guard let ctx = CGContext(data: &sample, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return sample[3] > 0
    }
}
