import XCTest
@testable import BaneySpacesCore

/// The trackpads being watched, against a framework that frees a listing's devices when the
/// listing goes: a device used after that is a failure, as it would be a crash for real.
final class TrackpadRegistryTests: XCTestCase {
    final class Device: Hashable {
        let id: UInt64, builtIn: Bool, width: Int, height: Int
        var freed = false
        init(id: UInt64, builtIn: Bool = true, width: Int = 12480, height: Int = 7680) {
            self.id = id; self.builtIn = builtIn; self.width = width; self.height = height
        }
        static func == (a: Device, b: Device) -> Bool { a === b }
        func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
    }

    /// One listing. Its devices are alive exactly as long as it is.
    final class Listing {
        let devices: [Device]
        init(_ devices: [Device]) { self.devices = devices }
        deinit { devices.forEach { $0.freed = true } }
    }

    final class Framework: TouchFramework {
        var hardware: [(id: UInt64, builtIn: Bool, width: Int, height: Int)] = [(1, true, 12480, 7680)]
        var failures: [String] = []
        var registered = 0, unregistered = 0, listings = 0
        var live = Set<UInt64>()

        func listDevices() -> Listing? {
            listings += 1
            return Listing(hardware.map { Device(id: $0.id, builtIn: $0.builtIn, width: $0.width, height: $0.height) })
        }
        func devices(in list: Listing) -> [Device] { list.devices }
        func deviceID(_ d: Device) -> UInt64? { use(d, "id"); return d.id }
        func isBuiltIn(_ d: Device) -> Bool { use(d, "isBuiltIn"); return d.builtIn }
        func surface(_ d: Device) -> (width: Int, height: Int) { use(d, "surface"); return (d.width, d.height) }
        func register(_ d: Device) { use(d, "register"); registered += 1; live.insert(d.id) }
        func unregister(_ d: Device) { use(d, "unregister"); unregistered += 1; live.remove(d.id) }
        private func use(_ d: Device, _ what: String) {
            if d.freed { failures.append("\(what) on device \(d.id) after its listing was freed") }
        }
    }

    private func make() -> (Framework, TrackpadRegistry<Framework>) {
        let f = Framework()
        return (f, TrackpadRegistry(framework: f, fingerCounts: { _ in [3, 4] }))
    }

    func testListingAgainDoesNotWatchTheSameTrackpadTwice() {
        let (f, r) = make()
        XCTAssertEqual(r.refresh().added, 1)
        for _ in 0..<5 { XCTAssertEqual(r.refresh(), TrackpadRegistry<Framework>.Change()) }
        XCTAssertEqual(f.registered, 1, "every listing makes new device objects, but the id is the same")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(f.failures, [])
    }

    func testLettingGoNeverTouchesADeviceAfterItsListing() {
        let (f, r) = make()
        r.refresh()
        r.refresh()
        r.detach()
        XCTAssertEqual(f.unregistered, 1)
        XCTAssertEqual(f.failures, [], "unregistering uses devices their listing still holds")
        XCTAssertEqual(r.count, 0)
    }

    func testSleepAndWakeStartTheTrackpadsAgainCleanly() {
        let (f, r) = make()
        r.refresh()
        r.detach()
        r.refresh()
        XCTAssertEqual(f.registered, 2)
        XCTAssertEqual(f.unregistered, 1)
        r.detach()
        XCTAssertEqual(f.unregistered, 2)
        XCTAssertEqual(f.failures, [])
    }

    func testATrackpadThatGoesIsLetGoWhileItsListingHoldsIt() {
        let (f, r) = make()
        f.hardware.append((2, false, 16000, 11500))
        XCTAssertEqual(r.refresh().added, 2)
        f.hardware.removeAll { $0.id == 2 }
        let change = r.refresh()
        XCTAssertEqual(change.removed, 1)
        XCTAssertEqual(f.failures, [])
        XCTAssertEqual(f.live, [1])
        XCTAssertEqual(r.count, 1)
    }

    func testATrackpadThatComesIsWatchedWithoutDisturbingTheOthers() {
        let (f, r) = make()
        r.refresh()
        f.hardware.append((2, false, 16000, 11500))
        XCTAssertEqual(r.refresh().added, 1)
        XCTAssertEqual(f.registered, 2)
        XCTAssertEqual(f.unregistered, 0)
        XCTAssertEqual(f.failures, [])
    }

    func testAMagicMouseIsNeverRegistered() {
        let (f, r) = make()
        f.hardware.append((9, false, 3200, 10600))
        let change = r.refresh()
        XCTAssertEqual(change.added, 1)
        XCTAssertEqual(change.skipped, 1)
        XCTAssertEqual(r.refresh().skipped, 0, "decided once")
        XCTAssertEqual(f.live, [1])
    }

    func testFramesOfADeviceNotWatchedAreIgnored() {
        let (_, r) = make()
        XCTAssertNil(r.frame(Device(id: 77), data: nil, count: 0, available: 0))
    }

    func testTheLayoutCheckIsReportedOnceItMoves() {
        let (f, r) = make()
        r.refresh()
        _ = f
        let device = r.registeredDeviceForTests!
        var bytes = [UInt8](repeating: 0xFF, count: 96)
        let outcome = bytes.withUnsafeMutableBytes { raw -> TrackpadRegistry<Framework>.Outcome? in
            r.frame(device, data: raw.baseAddress, count: 1, available: 96)
        }
        XCTAssertEqual(outcome?.layout, .rejected)
        XCTAssertTrue(r.layoutRejected)
    }
}
