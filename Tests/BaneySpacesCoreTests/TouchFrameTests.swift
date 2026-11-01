import XCTest
@testable import BaneySpacesCore

/// Reading the private touch frames safely, and the whole path from frames to a swipe: the
/// release frame ends a gesture, and an unrecognised layout is never trusted.
final class TouchFrameTests: XCTestCase {
    /// A frame as MultitouchSupport lays it out: 96 bytes a touch (`stride` for another size).
    private func frame(_ fingers: [(x: Float, y: Float)], stride: Int = 96, state: Int32 = 4) -> [UInt8] {
        var bytes = [UInt8](repeating: 0xFF, count: max(fingers.count * stride, 1))
        bytes.withUnsafeMutableBytes { raw in
            for (i, f) in fingers.enumerated() {
                let base = i * stride
                raw.storeBytes(of: Int32(i + 1), toByteOffset: base + 16, as: Int32.self)
                raw.storeBytes(of: state, toByteOffset: base + 20, as: Int32.self)
                raw.storeBytes(of: f.x, toByteOffset: base + 32, as: Float.self)
                raw.storeBytes(of: f.y, toByteOffset: base + 36, as: Float.self)
            }
        }
        return bytes
    }

    private func read(_ r: inout TouchFrameReader, _ fingers: [(x: Float, y: Float)], stride: Int = 96) -> [FingerSwipe.Touch]? {
        let bytes = frame(fingers, stride: stride)
        return bytes.withUnsafeBytes { r.touches(in: $0.baseAddress, count: fingers.count, available: bytes.count) }
    }

    private func three(at y: Float) -> [(x: Float, y: Float)] { [(0.4, y), (0.5, y), (0.6, y)] }

    /// A reader that has seen enough single and multi-finger frames.
    private func trustedReader() -> TouchFrameReader {
        var r = TouchFrameReader()
        for _ in 0..<TouchFrameReader.framesNeeded { _ = read(&r, three(at: 0.3)) }
        return r
    }

    func testTheLayoutIsCheckedBeforeItIsTrusted() {
        var r = TouchFrameReader()
        for _ in 0..<(TouchFrameReader.framesNeeded - 1) { XCTAssertNil(read(&r, three(at: 0.3))) }
        XCTAssertEqual(r.layout, .checking)
        XCTAssertNil(read(&r, three(at: 0.3)), "the frame that proves it is still not used")
        XCTAssertEqual(r.layout, .trusted)
        XCTAssertEqual(read(&r, three(at: 0.3))?.count, 3)
    }

    func testOnlySingleFingerFramesNeverProveTheSize() {
        var r = TouchFrameReader()
        for _ in 0..<20 { _ = read(&r, [(0.5, 0.5)]) }
        XCTAssertEqual(r.layout, .checking, "a second touch is what shows each one is 96 bytes")
    }

    func testAnotherTouchSizeIsRejectedNotTrusted() {
        var r = TouchFrameReader()
        // The same fields in 80-byte touches: the second touch reads from the wrong place.
        _ = read(&r, [(0.4, 0.3), (0.5, 0.3), (0.6, 0.3)], stride: 80)
        XCTAssertEqual(r.layout, .rejected)
        XCTAssertNil(read(&r, three(at: 0.3)), "rejected for good")
    }

    func testNonsensePositionsAreRejected() {
        var r = TouchFrameReader()
        _ = read(&r, [(7.5, 0.3), (0.5, 0.3)])
        XCTAssertEqual(r.layout, .rejected)
        var nan = TouchFrameReader()
        _ = read(&nan, [(Float.nan, 0.3)])
        XCTAssertEqual(nan.layout, .rejected)
    }

    func testOnlyFingersTouchingAreCounted() {
        var r = trustedReader()
        let bytes = frame([(0.4, 0.3), (0.5, 0.3), (0.6, 0.3)], state: 2)   // hovering
        XCTAssertEqual(bytes.withUnsafeBytes { r.touches(in: $0.baseAddress, count: 3, available: bytes.count) }, [])
    }

    func testAFrameOfNoTouchesNeedsNoData() {
        var r = TouchFrameReader()
        XCTAssertEqual(r.touches(in: nil, count: 0, available: 0), [], "every finger up")
        var rejected = TouchFrameReader()
        _ = read(&rejected, [(9, 9)])
        XCTAssertNil(rejected.touches(in: nil, count: 0, available: 0))
        XCTAssertNil(r.touches(in: nil, count: 3, available: 0), "touches announced with no data aren't read")
    }

    func testTrustIsWithdrawnAfterNonsenseInARow() {
        var r = trustedReader()
        for _ in 0..<(TouchFrameReader.oddLimit - 1) { XCTAssertNil(read(&r, [(5, 5), (0.5, 0.5)])) }
        XCTAssertEqual(r.layout, .trusted, "one bad frame or two isn't enough")
        XCTAssertNotNil(read(&r, three(at: 0.3)))
        for _ in 0..<TouchFrameReader.oddLimit { _ = read(&r, [(5, 5), (0.5, 0.5)]) }
        XCTAssertEqual(r.layout, .rejected)
    }

    // MARK: Never past the buffer

    /// `length` bytes that end exactly where memory stops: reading one byte more is a crash.
    private func withBufferAtTheEdge(_ length: Int, _ body: (UnsafeRawPointer) -> Void) {
        let page = Int(getpagesize())
        let base = mmap(nil, page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)!
        XCTAssertEqual(mprotect(base + page, page, PROT_NONE), 0)
        defer { munmap(base, page * 2) }
        let start = base + page - length
        memset(start, 0, length)
        body(UnsafeRawPointer(start))
    }

    func testAShortBufferIsNeverReadPast() {
        // Two touches of a 64-byte layout: 128 bytes, and the check would need 192 to read them as 96.
        withBufferAtTheEdge(128) { p in
            var r = TouchFrameReader()
            XCTAssertNil(r.touches(in: p, count: 2, available: 128))
            XCTAssertEqual(r.layout, .rejected, "too short to be this layout, and not read to find out")
        }
        // One touch, 64 bytes, claimed to be a 96-byte record.
        withBufferAtTheEdge(64) { p in
            var r = TouchFrameReader()
            XCTAssertNil(r.touches(in: p, count: 1, available: 64))
            XCTAssertEqual(r.layout, .rejected)
        }
    }

    func testATrustedLayoutIsNotReadPastAShortFrame() {
        var r = trustedReader()
        withBufferAtTheEdge(96) { p in
            // Three touches announced, one touch of data.
            XCTAssertNil(r.touches(in: p, count: 3, available: 96))
        }
        XCTAssertEqual(r.layout, .trusted, "a short frame or two doesn't withdraw trust")
        withBufferAtTheEdge(96) { p in
            for _ in 0..<TouchFrameReader.oddLimit { _ = r.touches(in: p, count: 3, available: 96) }
        }
        XCTAssertEqual(r.layout, .rejected)
    }

    func testTheLengthComesFromTheBlockOrTheMappedMemory() {
        let heap = malloc(128)!
        defer { free(heap) }
        XCTAssertGreaterThanOrEqual(SafeBuffer.length(of: heap), 128)
        XCTAssertLessThan(SafeBuffer.length(of: heap), 4096, "its own block, not the whole heap")
        withBufferAtTheEdge(128) { p in
            XCTAssertEqual(SafeBuffer.length(of: p), 128, "memory stops after it")
        }
        XCTAssertEqual(SafeBuffer.length(of: UnsafeRawPointer(bitPattern: 16)!), 0, "nothing mapped there")
    }

    // MARK: From frames to swipes

    /// What the app's callback does with each frame.
    private func run(_ r: inout TouchFrameReader, _ s: inout FingerSwipe, _ frames: [[(x: Float, y: Float)]]) -> [FingerSwipe.Direction] {
        var out: [FingerSwipe.Direction] = []
        for f in frames {
            let bytes = frame(f)
            let touches = f.isEmpty ? r.touches(in: nil, count: 0, available: 0) : bytes.withUnsafeBytes { r.touches(in: $0.baseAddress, count: f.count, available: bytes.count) }
            if let touches, let d = s.frame(touches) { out.append(d) }
        }
        return out
    }

    private func swipe(from: Float, to: Float) -> [[(x: Float, y: Float)]] {
        (0...10).map { three(at: from + (to - from) * Float($0) / 10) }
    }

    func testTheReleaseFrameEndsTheGestureSoTheNextOneFires() {
        var r = trustedReader()
        var s = FingerSwipe(fingers: [3])
        XCTAssertEqual(run(&r, &s, swipe(from: 0.3, to: 0.8)), [.up])
        XCTAssertEqual(run(&r, &s, swipe(from: 0.8, to: 0.2)), [], "fingers still down")
        XCTAssertEqual(run(&r, &s, [[]]), [], "released")
        XCTAssertEqual(run(&r, &s, swipe(from: 0.3, to: 0.8)), [.up], "second swipe, no double fire from the first")
        XCTAssertEqual(run(&r, &s, [[]] + swipe(from: 0.8, to: 0.2)), [.down])
    }

    func testAFirstSwipeBeforeTheLayoutIsCheckedDoesNothingWorse() {
        var r = TouchFrameReader()
        var s = FingerSwipe(fingers: [3])
        // Fingers land one at a time, which is how the layout gets proven.
        let landing: [[(x: Float, y: Float)]] = [[(0.4, 0.3)], [(0.4, 0.3), (0.5, 0.3)]] + (0..<6).map { _ in three(at: 0.3) }
        XCTAssertEqual(run(&r, &s, landing), [])
        XCTAssertEqual(run(&r, &s, swipe(from: 0.3, to: 0.8)), [.up])
    }

    // MARK: Devices

    func testOnlyTrackpadsAreWatched() {
        XCTAssertTrue(TrackpadDevice.isTrackpad(builtIn: true, width: 12480, height: 7680), "this Mac's own")
        XCTAssertTrue(TrackpadDevice.isTrackpad(builtIn: false, width: 16000, height: 11500), "Magic Trackpad")
        XCTAssertFalse(TrackpadDevice.isTrackpad(builtIn: false, width: 3200, height: 10600), "Magic Mouse: narrow and tall")
        XCTAssertFalse(TrackpadDevice.isTrackpad(builtIn: false, width: 0, height: 0), "unknown")
    }

    func testEachTrackpadReadsItsOwnSettings() {
        XCTAssertEqual(TrackpadDevice.preferenceDomain(builtIn: true), "com.apple.AppleMultitouchTrackpad")
        XCTAssertEqual(TrackpadDevice.preferenceDomain(builtIn: false), "com.apple.driver.AppleBluetoothMultitouch.trackpad")
        // The built-in one has four fingers off; an old Magic Trackpad's settings don't change that.
        XCTAssertEqual(FingerSwipe.fingerCounts(threeFingers: 0, fourFingers: 0, threeFingerDrag: false), [])
        XCTAssertEqual(FingerSwipe.fingerCounts(threeFingers: 0, fourFingers: 2, threeFingerDrag: false), [4])
    }
}
