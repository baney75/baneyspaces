import AppKit
import BaneySpacesCore
import CryptoKit
import ScreenCaptureKit

/// A picture of one window, taken by its window id: it works while the window is parked out of
/// view, because ScreenCaptureKit captures the window itself, not the screen where it would be.
enum WindowShot {
    struct Result {
        var path: String
        var width: Int
        var height: Int
        var sha256: String
    }

    static var folder: URL { HandsEngine.home.appendingPathComponent("shots", isDirectory: true) }

    static func capture(window id: UInt32, to out: String?) -> Swift.Result<Result, HandsError> {
        guard CGPreflightScreenCaptureAccess() else {
            return .failure(HandsError(.permissionDenied, "BaneySpaces doesn't have Screen Recording access",
                                       suggestion: "Allow BaneySpaces in System Settings > Privacy & Security > Screen & System Audio Recording, then run the command again.", retry: .safe))
        }
        guard #available(macOS 14, *) else {
            return .failure(HandsError(.notSupported, "window captures need macOS 14 or later", suggestion: "Use `baneyspaces agent snapshot` to read the window instead.", retry: .never))
        }
        return captureWithKit(id, out)
    }

    @available(macOS 14, *)
    private static func captureWithKit(_ id: UInt32, _ out: String?) -> Swift.Result<Result, HandsError> {
        var outcome: Swift.Result<Result, HandsError> = .failure(HandsError(.timeout, "the capture didn't finish", suggestion: "Try again.", retry: .safe))
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let w = content.windows.first(where: { $0.windowID == id }) else {
                    outcome = .failure(HandsError(.windowNotFound, "window \(id) isn't there", suggestion: "Run `baneyspaces agent windows` for the current ids.", retry: .safe))
                    return
                }
                let filter = SCContentFilter(desktopIndependentWindow: w)
                let cfg = SCStreamConfiguration()
                cfg.width = Int(w.frame.width * 2)
                cfg.height = Int(w.frame.height * 2)
                cfg.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                let rep = NSBitmapImageRep(cgImage: image)
                guard let png = rep.representation(using: .png, properties: [:]) else { return }
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let path = out.map { ($0 as NSString).expandingTildeInPath }
                    ?? folder.appendingPathComponent("window-\(id)-\(Int(Date().timeIntervalSince1970)).png").path
                guard FileManager.default.createFile(atPath: path, contents: png, attributes: [.posixPermissions: 0o600]) else {
                    outcome = .failure(HandsError(.badArguments, "couldn't write \(path)", suggestion: "Pick a folder you can write to.", retry: .safe))
                    return
                }
                let hash = SHA256.hash(data: rep.bitmapData.map { Data(bytes: $0, count: rep.bytesPerRow * rep.pixelsHigh) } ?? png)
                outcome = .success(Result(path: path, width: image.width, height: image.height, sha256: hash.map { String(format: "%02x", $0) }.joined()))
            } catch {
                outcome = .failure(HandsError(.engineError, "the capture failed: \(error.localizedDescription)", suggestion: "Check Screen Recording access for BaneySpaces.", retry: .safe))
            }
        }
        _ = done.wait(timeout: .now() + 10)
        return outcome
    }
}
