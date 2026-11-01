import AppKit
import BaneySpacesCore
import BaneySpacesCursor
import CryptoKit
import ScreenCaptureKit

/// A picture of one window, taken by its window id: it works while the window is parked out of
/// view, because ScreenCaptureKit captures the window itself, not the screen where it would be.
/// The file goes only into BaneySpaces' own shots folder (0700), written atomically (0600).
enum WindowShot {
    struct Result {
        var path: String
        var width: Int
        var height: Int
        var sha256: String
        /// Whether the agent cursor was drawn in (`--cursor`).
        var cursorDrawn = false
    }

    static var folder: URL { HandsEngine.home.appendingPathComponent("shots", isDirectory: true) }
    static let budget: TimeInterval = 10

    /// Holds the outcome for the waiting thread and the capture task, under a lock.
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Swift.Result<Result, HandsError>?
        private var cancelled = false
        func set(_ v: Swift.Result<Result, HandsError>) { lock.lock(); if value == nil { value = v }; lock.unlock() }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func get() -> Swift.Result<Result, HandsError>? { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func capture(window id: UInt32, named name: String?, cursor: CursorMark? = nil, check: @escaping () -> HandsError?) -> Swift.Result<Result, HandsError> {
        if let name, !HandoffPath.isPlainFileName(name) {
            return .failure(HandsError(.badArguments, "out must be a file name, not a path", suggestion: "Pass just a name like `page.png`; shots are written in \(folder.path).", retry: .safe))
        }
        guard CGPreflightScreenCaptureAccess() else {
            return .failure(HandsError(.permissionDenied, "BaneySpaces doesn't have Screen Recording access",
                                       suggestion: "Allow BaneySpaces in System Settings > Privacy & Security > Screen & System Audio Recording, then run the command again.", retry: .safe))
        }
        guard #available(macOS 14, *) else {
            return .failure(HandsError(.notSupported, "window captures need macOS 14 or later", suggestion: "Use `baneyspaces agent snapshot` to read the window instead.", retry: .never))
        }
        return captureWithKit(id, name, cursor, check)
    }

    @available(macOS 14, *)
    private static func captureWithKit(_ id: UInt32, _ name: String?, _ cursor: CursorMark?, _ check: @escaping () -> HandsError?) -> Swift.Result<Result, HandsError> {
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let w = content.windows.first(where: { $0.windowID == id }) else {
                    return outcome.set(.failure(HandsError(.windowNotFound, "window \(id) isn't there", suggestion: "Run `baneyspaces agent windows` for the current ids.", retry: .safe)))
                }
                // Enumerating took time: the window is still in scope, and the caller still waiting, or nothing is captured.
                if outcome.isCancelled { return }
                if let e = check() { return outcome.set(.failure(e)) }
                let cfg = SCStreamConfiguration()
                cfg.width = Int(w.frame.width * 2)
                cfg.height = Int(w.frame.height * 2)
                cfg.showsCursor = false
                if outcome.isCancelled { return }
                if let e = check() { return outcome.set(.failure(e)) }
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg)
                if outcome.isCancelled { return }
                if let e = check() { return outcome.set(.failure(e)) }   // before the bytes are published
                // `--cursor`: the capture is of the window alone, so the overlay is never in it; the arrow is drawn in on request.
                var picture = image, drawn = false
                if let cursor, let frame = cursor.windowFrame,
                   let with = ShotComposite.draw(cursor, onto: image, windowFrame: frame, scale: CGFloat(image.width) / max(1, w.frame.width)) {
                    picture = with; drawn = true
                }
                let rep = NSBitmapImageRep(cgImage: picture)
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    return outcome.set(.failure(HandsError(.engineError, "the capture couldn't be encoded", suggestion: "Try again.", retry: .safe)))
                }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let file = folder.appendingPathComponent(name ?? "window-\(id)-\(Int(Date().timeIntervalSince1970)).png")
                // Atomic: a reader never sees half a file; the mode is set before the name appears.
                let tmp = folder.appendingPathComponent(".\(UUID().uuidString).part")
                guard FileManager.default.createFile(atPath: tmp.path, contents: png, attributes: [.posixPermissions: 0o600]) else {
                    return outcome.set(.failure(HandsError(.engineError, "couldn't write the capture", suggestion: "Check disk space.", retry: .safe)))
                }
                _ = try? FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: tmp, to: file)
                let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
                outcome.set(.success(Result(path: file.path, width: picture.width, height: picture.height, sha256: hash, cursorDrawn: drawn)))
            } catch {
                outcome.set(.failure(HandsError(.engineError, "the capture failed: \(error.localizedDescription)", suggestion: "Check Screen Recording access for BaneySpaces.", retry: .safe)))
            }
        }
        if done.wait(timeout: .now() + budget) == .timedOut {
            outcome.cancel()
            outcome.set(.failure(HandsError(.timeout, "the capture didn't finish in \(Int(budget)) s", suggestion: "Try again.", retry: .safe)))
        }
        return outcome.get() ?? .failure(HandsError(.timeout, "the capture didn't finish", suggestion: "Try again.", retry: .safe))
    }
}
