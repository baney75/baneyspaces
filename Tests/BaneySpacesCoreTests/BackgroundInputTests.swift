import CoreGraphics
import XCTest
@testable import BaneySpacesCore

/// Phase 4: keys and a pointer for agent windows that are not in front. These prove the decisions; the probe
/// (`scripts/agent-keys-probe.swift`) proves the events land.

private func ready(_ kind: InputKind = .keys) -> BackgroundFacts {
    BackgroundFacts(kind: kind, app: "TextEdit", pid: 500, window: 77, scope: .agentWorkspace, pidIsAgentOwned: true,
                    windowOwnerPid: 500, axWindowResolved: true, siblingWindows: 0, condition: .normal, hasSheetOrPanel: false,
                    focusedWindow: 77, focusedElementWindow: 77, targetIsFront: false,
                    transports: TransportSupport(skyLight: true), block: nil, verifier: kind == .keys ? .ax : .axAndPixels)
}

private func refusal(_ f: BackgroundFacts) -> HandsError? {
    if case .failure(let e) = BackgroundPlanner.plan(f) { return e }
    return nil
}

final class KeyParseTests: XCTestCase {
    func chord(_ s: String) throws -> KeyChord { try KeyParse.chord(s).get() }

    func testPlainKeysAndChords() throws {
        XCTAssertEqual(try chord("Return").keyCode, 36)
        XCTAssertEqual(try chord("9").keyCode, 25)
        XCTAssertEqual(try chord("a").flags, 0)
        let selectAll = try chord("cmd+a")
        XCTAssertEqual(selectAll.keyCode, 0)
        XCTAssertEqual(selectAll.flags, KeyChord.command)
        XCTAssertTrue(selectAll.hasCommand)
        XCTAssertEqual(try chord("cmd+b").keyCode, 11)
        XCTAssertEqual(try chord("Cmd+Shift+Z").flags, KeyChord.command | KeyChord.shift)
        XCTAssertEqual(try chord("cmd+Down").keyCode, 125)
        XCTAssertEqual(try chord("ctrl+alt+fn+f5").flags, KeyChord.control | KeyChord.option | KeyChord.function)
    }

    func testSymbolsThatNeedShift() throws {
        let star = try chord("asterisk")
        XCTAssertEqual(star.keyCode, 28)
        XCTAssertEqual(star.flags, KeyChord.shift)
        XCTAssertEqual(try chord("*"), KeyChord(keyCode: 28, flags: KeyChord.shift, label: "*"))
        XCTAssertEqual(try chord("plus").flags, KeyChord.shift)
        XCTAssertEqual(try chord("A").flags, KeyChord.shift, "a capital is Shift and the letter")
        XCTAssertEqual(try chord("cmd++").keyCode, 24, "a trailing plus is the plus key")
        XCTAssertEqual(try chord("cmd++").flags, KeyChord.command | KeyChord.shift)
    }

    func testSequencesAreSeparatedBySpaces() throws {
        let seq = try KeyParse.sequence("h i Return cmd+a").get()
        XCTAssertEqual(seq.map(\.keyCode), [4, 34, 36, 0])
        XCTAssertEqual(seq.last?.flags, KeyChord.command)
    }

    func testBadKeysAreBadArgumentsWithAHint() {
        for bad in ["", "   ", "cmd+", "hyper+a", "nosuchkey", "cmd+shift+nosuchkey", "ab"] {
            guard case .failure(let e) = KeyParse.sequence(bad) else { return XCTFail("\(bad) should not parse") }
            XCTAssertEqual(e.code, .badArguments, bad)
            XCTAssertEqual(e.retry, .safe)
            XCTAssertFalse(e.suggestion.isEmpty)
        }
    }

    func testTooManyKeysInOneCallAreRefused() {
        let many = Array(repeating: "a", count: KeyParse.maxChords + 1).joined(separator: " ")
        guard case .failure(let e) = KeyParse.sequence(many) else { return XCTFail() }
        XCTAssertEqual(e.code, .badArguments)
        XCTAssertNotNil(try? KeyParse.sequence(Array(repeating: "a", count: KeyParse.maxChords).joined(separator: " ")).get())
    }

    func testTheBenchTasksKeysAllParse() throws {
        // calculator-keys, textedit-select-all-replace, textedit-bold-save-rtf, finder-*: every key their scripts press.
        for k in ["9", "asterisk", "8", "Return", "cmd+a", "cmd+b", "cmd+s", "cmd+shift+s", "cmd+shift+n", "cmd+shift+g", "cmd+Down"] {
            XCTAssertNotNil(try? KeyParse.chord(k).get(), k)
        }
    }
}

final class RouteSelectionTests: XCTestCase {
    func testAReadyKeyActionGetsOneKeyRouteOnSkyLight() throws {
        let p = try BackgroundPlanner.plan(ready()).get()
        XCTAssertEqual(p.route, .pidKeys)
        XCTAssertEqual(p.transport, .skyLightPid)
        XCTAssertEqual(p.pid, 500)
        XCTAssertEqual(p.window, 77)
    }

    func testAReadyPointerActionGetsTheWindowPointerRoute() throws {
        let p = try BackgroundPlanner.plan(ready(.pointer)).get()
        XCTAssertEqual(p.route, .windowPointer)
        XCTAssertEqual(p.transport, .skyLightPid)
    }

    func testAMissingSkyLightSymbolFallsBackToThePublicPerProcessCall() throws {
        var f = ready()
        f.transports = TransportSupport(skyLight: false)
        XCTAssertEqual(try BackgroundPlanner.plan(f).get().transport, .publicPid)
        XCTAssertEqual(TransportSupport(skyLight: true).pick(), .skyLightPid)
    }

    func testNoTransportAtAllIsARouteThatIsUnavailableNotACrash() {
        var f = ready()
        f.transports = TransportSupport(skyLight: false, publicPid: false)
        let e = refusal(f)
        XCTAssertEqual(e?.code, .notSupported)
        XCTAssertEqual(e?.retry, .never)
    }

    func testNoTransportIsEverTheSessionOrHIDTap() {
        // The transports are per-process by construction: the enum has nothing else.
        XCTAssertEqual(Set([PostTransport.skyLightPid, .publicPid].map(\.rawValue)), ["skylight_pid", "cgevent_pid"])
        XCTAssertEqual(Set(BackgroundRoute.allCasesForTest.map(\.rawValue)), ["pid_keys", "window_pointer"])
    }

    func testTheRoutesAreOnePerActionAndTheChoiceIsStable() throws {
        let a = try BackgroundPlanner.plan(ready()).get()
        let b = try BackgroundPlanner.plan(ready()).get()
        XCTAssertEqual(a, b)
    }

    func testEachKeyConditionRefusesBeforeAnythingIsPosted() {
        var siblings = ready(); siblings.siblingWindows = 1
        XCTAssertEqual(refusal(siblings)?.code, .notSupported)
        var notKey = ready(); notKey.focusedWindow = 99
        XCTAssertEqual(refusal(notKey)?.code, .notSupported)
        var elementElsewhere = ready(); elementElsewhere.focusedElementWindow = 99
        XCTAssertEqual(refusal(elementElsewhere)?.code, .notSupported, "the focused element must be inside this window")
        var noFocus = ready(); noFocus.focusedWindow = nil
        XCTAssertEqual(refusal(noFocus)?.code, .notSupported)
        var noVerifier = ready(); noVerifier.verifier = .none
        XCTAssertEqual(refusal(noVerifier)?.code, .notSupported)
        var pixelsOnly = ready(); pixelsOnly.verifier = .pixels
        XCTAssertEqual(refusal(pixelsOnly)?.code, .notSupported, "pixels alone never prove keys, so keys are not sent on them")
        var unresolved = ready(); unresolved.axWindowResolved = false
        XCTAssertEqual(refusal(unresolved)?.code, .notSupported)
    }

    func testPointerConditions() {
        var outside = ready(.pointer); outside.pointInsideWindow = false
        XCTAssertEqual(refusal(outside)?.code, .badArguments)
        var none = ready(.pointer); none.verifier = .none
        XCTAssertEqual(refusal(none)?.code, .notSupported)
        var pixels = ready(.pointer); pixels.verifier = .pixels
        XCTAssertNotNil(try? BackgroundPlanner.plan(pixels).get(), "a canvas has no tree: pixels can verify a pointer")
        // A pointer does not care about sibling windows or the app's key window: it carries the window number.
        var siblings = ready(.pointer); siblings.siblingWindows = 2; siblings.focusedWindow = 1
        XCTAssertNotNil(try? BackgroundPlanner.plan(siblings).get())
    }

    func testMinimizedAndHiddenWindowsAreRefused() {
        for c in [WindowCondition.minimized, .appHidden] {
            var f = ready(); f.condition = c
            XCTAssertEqual(refusal(f)?.code, .notSupported)
            var p = ready(.pointer); p.condition = c
            XCTAssertEqual(refusal(p)?.code, .notSupported)
        }
    }

    func testASheetOrPanelIsOffLimits() {
        var f = ready(); f.hasSheetOrPanel = true
        XCTAssertEqual(refusal(f)?.code, .needsSandbox)
    }
}

final class BackgroundScopeAtExecutionTests: XCTestCase {
    func testAProcessBaneySpacesDidNotStartIsNeverPostedToOnTheAgentWorkspace() {
        var f = ready(); f.pidIsAgentOwned = false
        let e = refusal(f)
        XCTAssertEqual(e?.code, .needsLend)
        XCTAssertEqual(e?.retry, .never)
        var p = ready(.pointer); p.pidIsAgentOwned = false
        XCTAssertEqual(refusal(p)?.code, .needsLend)
    }

    func testALentWindowNeedsNoOwnershipButTheLendItself() throws {
        var f = ready(); f.scope = .lent; f.pidIsAgentOwned = false
        XCTAssertNotNil(try? BackgroundPlanner.plan(f).get(), "the lend names this pid and window; the scope guard checked it")
    }

    func testAWindowOutsideTheAgentWorkspaceAndNotLentIsRefusedFirst() {
        var f = ready(); f.scope = .outside
        XCTAssertEqual(refusal(f)?.code, .outsideAgentWorkspace)
        f.pidIsAgentOwned = false
        XCTAssertEqual(refusal(f)?.code, .outsideAgentWorkspace, "scope is decided before ownership")
    }

    func testAReusedPidOrAWindowThatMovedToAnotherProcessIsStale() {
        var f = ready(); f.windowOwnerPid = 612
        let e = refusal(f)
        XCTAssertEqual(e?.code, .staleRef)
        XCTAssertEqual(e?.retry, .afterSnapshot)
        f.windowOwnerPid = nil
        XCTAssertEqual(refusal(f)?.code, .staleRef, "a window the server no longer lists")
    }

    func testDonovanBeingInTheAppStopsTheAction() {
        var f = ready(); f.targetIsFront = true
        let e = refusal(f)
        XCTAssertEqual(e?.code, .inUse)
        XCTAssertEqual(e?.retry, .safe, "nothing was posted")
    }

    func testTheOrderOfRefusalsPutsWhoseProcessFirst() {
        var f = ready()
        f.scope = .agentWorkspace; f.pidIsAgentOwned = false; f.targetIsFront = true; f.siblingWindows = 3
        XCTAssertEqual(refusal(f)?.code, .needsLend)
        f.pidIsAgentOwned = true
        XCTAssertEqual(refusal(f)?.code, .inUse)
        f.targetIsFront = false
        XCTAssertEqual(refusal(f)?.code, .notSupported)
    }

    func testAnAppShutOutForTheRunIsRefusedWithTheSandboxSuggestion() {
        for b in [RouteBlock.selfActivates, .refusesBackgroundInput] {
            var f = ready(); f.block = b
            let e = refusal(f)
            XCTAssertEqual(e?.code, .notSupported)
            XCTAssertEqual(e?.retry, .never)
            XCTAssertTrue(e?.suggestion.contains("sandbox") ?? false)
        }
    }

    func testTheScopeGuardAndThePlannerAgreeOnTheAgentWorkspace() {
        // The planner never widens the scope guard: a window the guard denies is `.outside` to the planner.
        let w = HandsWindow(id: 77, pid: 500, app: "TextEdit", workspace: 3)
        if case .denied = ScopeGuard.check(w, agentWorkspace: 9, lends: LendBook(), now: Date()) {} else { XCTFail() }
        let on = HandsWindow(id: 77, pid: 500, app: "TextEdit", workspace: 9)
        XCTAssertEqual(ScopeGuard.check(on, agentWorkspace: 9, lends: LendBook(), now: Date()), .onAgentWorkspace)
    }
}

final class DeliveryProofTests: XCTestCase {
    let target: UInt32 = 77
    func el(_ value: String, window: UInt32? = 77, id: String = "AXTextArea|0,0,100,40", sel: (Int, Int)? = nil) -> ElementReading {
        ElementReading.text(window: window, identity: id, value: value, selection: sel)
    }
    func keys(ref: (ElementReading?, ElementReading?) = (nil, nil), focus: (ElementReading?, ElementReading?) = (nil, nil),
              tree: Bool? = nil, pixels: PixelChange? = nil) -> DeliveryVerdict {
        DeliveryProof.keys(target: target, ref: (ref.0, ref.1), focus: (focus.0, focus.1), treeChanged: tree, pixels: pixels)
    }

    func testAChangedValueOnTheExactElementProvesKeys() {
        let v = keys(ref: (el("a"), el("ab")))
        XCTAssertTrue(v.verified)
        XCTAssertEqual(v.basis, "value_changed")
    }

    func testAChangedSelectionProvesSelectAll() {
        let v = keys(focus: (el("hello", sel: (5, 0)), el("hello", sel: (0, 5))))
        XCTAssertTrue(v.verified)
        XCTAssertEqual(v.basis, "selection_changed")
    }

    func testFocusMovingInsideTheWindowProvesTab() {
        let v = keys(focus: (el("a", id: "AXTextField|0,0,10,10"), el("b", id: "AXButton|0,20,10,10")))
        XCTAssertTrue(v.verified)
        XCTAssertEqual(v.basis, "focus_moved")
    }

    func testATreeChangeProvesAShortcutThatOnlyTogglesState() {
        let v = keys(tree: true)
        XCTAssertTrue(v.verified)
        XCTAssertEqual(v.basis, "tree_changed")
    }

    func testAReadingFromAnotherWindowOfTheSameProcessNeverProvesAnything() {
        // The sibling's field changed; the target's did not. A PID-wide focused-element reader would call this success.
        let sibling = keys(focus: (el("a", window: 88), el("ab", window: 88)))
        XCTAssertFalse(sibling.verified)
        let noWindow = keys(focus: (el("a", window: nil), el("ab", window: nil)))
        XCTAssertFalse(noWindow.verified, "a reading with no window proves nothing")
        let mixed = keys(focus: (el("a", window: 77), el("ab", window: 88)))
        XCTAssertFalse(mixed.verified)
    }

    func testPixelsAloneNeverProveKeys() {
        let v = keys(ref: (el("a"), el("a")), pixels: PixelChange(insideChanged: 5000, insideTotal: 9000, outsideChanged: 10, outsideTotal: 100))
        XCTAssertFalse(v.verified)
        XCTAssertEqual(v.basis, "pixels_only")
    }

    func testNothingChangedAndNothingReadAreDifferentAnswersNeitherVerified() {
        XCTAssertEqual(keys(ref: (el("a"), el("a")), tree: false).basis, "no_change")
        XCTAssertEqual(keys().basis, "no_reading")
        XCTAssertFalse(keys().verified)
    }

    func testTheSameReadingTwiceIsNotAChange() {
        XCTAssertFalse(keys(focus: (el("same", sel: (1, 2)), el("same", sel: (1, 2)))).verified)
    }

    func testContentIsHashedNotKept() {
        let r = el("Donovan's private text")
        XCTAssertEqual(r.valueLength, 22)
        XCTAssertNotNil(r.valueDigest)
        XCTAssertEqual(ElementReading.digest("abc"), ElementReading.digest("abc"))
        XCTAssertNotEqual(ElementReading.digest("abc"), ElementReading.digest("abd"))
    }

    func testAStrokeIsProvedByPixelsAlongItWhileTheRestStaysPut() {
        let stroke = PixelChange(insideChanged: 400, insideTotal: 5000, outsideChanged: 3, outsideTotal: 40000)
        let v = DeliveryProof.pointer(target: target, ref: (nil, nil), focus: (nil, nil), treeChanged: nil, pixels: stroke)
        XCTAssertTrue(v.verified)
        XCTAssertEqual(v.basis, "pixels_along_stroke")
    }

    func testAWholeWindowRepaintOrATinySpeckIsNotAStroke() {
        let repaint = PixelChange(insideChanged: 400, insideTotal: 5000, outsideChanged: 20000, outsideTotal: 40000)
        XCTAssertFalse(DeliveryProof.pointer(target: target, ref: (nil, nil), focus: (nil, nil), treeChanged: nil, pixels: repaint).verified)
        let speck = PixelChange(insideChanged: 3, insideTotal: 5000, outsideChanged: 0, outsideTotal: 40000)
        XCTAssertFalse(DeliveryProof.pointer(target: target, ref: (nil, nil), focus: (nil, nil), treeChanged: nil, pixels: speck).verified)
        let caretElsewhere = PixelChange(insideChanged: 0, insideTotal: 5000, outsideChanged: 12, outsideTotal: 40000)
        let v = DeliveryProof.pointer(target: target, ref: (nil, nil), focus: (nil, nil), treeChanged: nil, pixels: caretElsewhere)
        XCTAssertFalse(v.verified)
        XCTAssertEqual(v.basis, "pixels_only")
    }

    func testAPointerOnAControlIsProvedByTheTreeLikeKeys() {
        let v = DeliveryProof.pointer(target: target, ref: (nil, nil), focus: (nil, nil), treeChanged: true, pixels: nil)
        XCTAssertTrue(v.verified)
    }

    func testNoProofIsUnverifiedWithRetryNever() {
        let e = BackgroundRefusal.unverified(basis: "no_change")
        XCTAssertEqual(e.code, .unverified)
        XCTAssertEqual(e.retry, .never)
        XCTAssertFalse(e.suggestion.isEmpty)
        XCTAssertEqual(HandsErrorCode.unverified.defaultRetry, .never)
        XCTAssertEqual(HandsErrorCode.unverified.rawValue, "unverified")
        XCTAssertTrue(e.suggestion.contains("Do not send them again"))
    }
}

final class PixelAndGeometryTests: XCTestCase {
    func image(_ w: Int, _ h: Int, fill: UInt8 = 255) -> [UInt8] { Array(repeating: fill, count: w * h * 4) }

    func testCompareCountsChangesInsideAndOutsideTheRegion() throws {
        let w = 20, h = 10
        let before = image(w, h)
        var after = before
        for x in 4..<8 { let i = (5 * w + x) * 4; after[i] = 0; after[i + 1] = 0; after[i + 2] = 0 }   // a 4 px stroke
        let i = (0 * w + 19) * 4; after[i] = 0   // one stray pixel outside
        let c = try XCTUnwrap(PixelDiff.compare(before: before, after: after, width: w, height: h, region: PixelRegion(x0: 2, y0: 3, x1: 10, y1: 8)))
        XCTAssertEqual(c.insideChanged, 4)
        XCTAssertEqual(c.insideTotal, 8 * 5)
        XCTAssertEqual(c.outsideChanged, 1)
        XCTAssertEqual(c.outsideTotal, w * h - 40)
    }

    func testSmallValueDriftIsNotAChangeAndSizeMismatchIsNil() {
        let before = image(4, 4, fill: 100)
        let after = image(4, 4, fill: 105)
        let c = PixelDiff.compare(before: before, after: after, width: 4, height: 4, region: PixelRegion(x0: 0, y0: 0, x1: 4, y1: 4))
        XCTAssertEqual(c?.anyChange, false)
        XCTAssertNil(PixelDiff.compare(before: before, after: image(5, 4), width: 4, height: 4, region: PixelRegion(x0: 0, y0: 0, x1: 4, y1: 4)))
    }

    func testALineHasBothEndsAndTheAskedSteps() {
        let p = PointerPath.line(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 60), steps: 10)
        XCTAssertEqual(p.count, 11)
        XCTAssertEqual(p.first, CGPoint(x: 10, y: 10))
        XCTAssertEqual(p.last, CGPoint(x: 110, y: 60))
        XCTAssertEqual(PointerPath.line(from: .zero, to: CGPoint(x: 1, y: 1), steps: 0).count, 2)
        XCTAssertEqual(PointerPath.line(from: .zero, to: CGPoint(x: 1, y: 1), steps: 10_000).count, PointerPath.maxSteps + 1)
    }

    func testWindowLocalPointsBecomeScreenPointsByTheWindowsOrigin() {
        let frame = CGRect(x: 2800, y: 1500, width: 400, height: 300)
        XCTAssertEqual(PointerPath.screenPoint(local: CGPoint(x: 20, y: 30), frame: frame), CGPoint(x: 2820, y: 1530))
        XCTAssertTrue(PointerPath.inside(CGPoint(x: 0, y: 0), size: frame.size))
        XCTAssertFalse(PointerPath.inside(CGPoint(x: 400, y: 10), size: frame.size))
        XCTAssertFalse(PointerPath.inside(CGPoint(x: -1, y: 10), size: frame.size))
    }

    func testTheStrokeRegionIsItsBoundingBoxGrownAndClipped() {
        let r = PointerPath.region(path: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 30)], margin: 5, scale: 2, width: 200, height: 100)
        XCTAssertEqual(r, PixelRegion(x0: 10, y0: 10, x1: 110, y1: 70))
        let clipped = PointerPath.region(path: [CGPoint(x: 1, y: 1)], margin: 50, scale: 2, width: 20, height: 20)
        XCTAssertEqual(clipped, PixelRegion(x0: 0, y0: 0, x1: 20, y1: 20))
    }
}

final class PostGuardTests: XCTestCase {
    func testAnyChangeToTheRealPointerIsAFailure() {
        XCTAssertEqual(PostGuard.pointer(before: CGPoint(x: 5, y: 6), after: CGPoint(x: 5, y: 6)), .unmoved)
        let moved = PostGuard.pointer(before: CGPoint(x: 5, y: 6), after: CGPoint(x: 5, y: 7))
        XCTAssertNotNil(moved.error)
        XCTAssertEqual(moved.error?.code, .actionFailed)
        XCTAssertEqual(moved.error?.retry, .never)
        XCTAssertNil(PostGuard.pointer(before: CGPoint(x: 5, y: 6), after: CGPoint(x: 5, y: 6)).error)
    }

    func testAPointerThatCouldNotBeReadIsReportedUncheckedNotPassed() {
        XCTAssertEqual(PostGuard.pointer(before: nil, after: CGPoint(x: 1, y: 1)), .unchecked)
        XCTAssertEqual(PostGuard.pointer(before: nil, after: nil).label, "unchecked")
    }

    func testFrontAppChangesAreTold() {
        XCTAssertEqual(PostGuard.front(start: 10, now: 10, target: 500), .same)
        XCTAssertEqual(PostGuard.front(start: 10, now: 500, target: 500), .targetCameForward)
        XCTAssertEqual(PostGuard.front(start: 10, now: 20, target: 500), .other(20))
        XCTAssertEqual(PostGuard.front(start: nil, now: 20, target: 500), .same)
    }

    func testTheFrontChangeRefusalSaysPartOfItMayHaveLanded() {
        let e = BackgroundRefusal.frontChanged("TextEdit", to: 20)
        XCTAssertEqual(e.retry, .never)
        XCTAssertTrue(e.suggestion.contains("part of the input may have landed"))
    }
}

final class RouteBreakerTests: XCTestCase {
    func testAnAppThatCameForwardIsShutOutForThatRouteOnly() {
        var b = RouteBreaker()
        XCTAssertNil(b.block(bundle: "com.apple.TextEdit", kind: .keys))
        b.selfActivated(bundle: "com.apple.TextEdit", kind: .keys)
        XCTAssertEqual(b.block(bundle: "com.apple.TextEdit", kind: .keys), .selfActivates)
        XCTAssertNil(b.block(bundle: "com.apple.TextEdit", kind: .pointer))
        XCTAssertNil(b.block(bundle: "com.apple.calculator", kind: .keys))
    }

    func testTwoPostsWithNoEffectShutTheRouteAndAProofOpensTheCount() {
        var b = RouteBreaker()
        b.noEffect(bundle: "x", kind: .keys)
        XCTAssertNil(b.block(bundle: "x", kind: .keys))
        b.proved(bundle: "x", kind: .keys)
        b.noEffect(bundle: "x", kind: .keys)
        XCTAssertNil(b.block(bundle: "x", kind: .keys), "a proof in between starts the count again")
        b.noEffect(bundle: "x", kind: .keys)
        XCTAssertEqual(b.block(bundle: "x", kind: .keys), .refusesBackgroundInput)
    }
}

final class RefusalSuggestionTests: XCTestCase {
    /// Every refusal the planner or the pipeline can return tells the caller what to do next.
    func testEveryRefusalHasASuggestionAndAVerdict() {
        let all: [HandsError] = [
            BackgroundRefusal.outside("TextEdit", window: 1), BackgroundRefusal.notOurProcess("TextEdit", pid: 2),
            BackgroundRefusal.windowChanged(window: 1, owner: 3, pid: 2), BackgroundRefusal.inUse("TextEdit"),
            BackgroundRefusal.notVisibleToInput("TextEdit", .minimized), BackgroundRefusal.notVisibleToInput("TextEdit", .appHidden),
            BackgroundRefusal.sheet("TextEdit"), BackgroundRefusal.blocked("TextEdit", .selfActivates), BackgroundRefusal.blocked("TextEdit", .refusesBackgroundInput),
            BackgroundRefusal.axUnresolved("TextEdit", window: 1), BackgroundRefusal.siblings("TextEdit", count: 2), BackgroundRefusal.siblings("TextEdit", count: 1),
            BackgroundRefusal.notKeyWindow("TextEdit", focused: nil, window: 1), BackgroundRefusal.noTransport("TextEdit"),
            BackgroundRefusal.noVerifier("TextEdit"), BackgroundRefusal.pointOutside(window: 1), BackgroundRefusal.unverified(basis: "no_change"),
            BackgroundRefusal.frontChanged("TextEdit", to: nil), BackgroundRefusal.pointerMoved(from: .zero, to: CGPoint(x: 1, y: 1)),
        ]
        for e in all {
            XCTAssertFalse(e.suggestion.isEmpty, e.message)
            XCTAssertFalse(e.message.isEmpty)
            XCTAssertTrue([HandsRetry.safe, .afterSnapshot, .never].contains(e.retry))
        }
    }

    func testAnAppThatRefusesBackgroundKeysIsNotSupportedWithARouteToTheSandbox() {
        for e in [BackgroundRefusal.blocked("Pages", .refusesBackgroundInput), BackgroundRefusal.blocked("Pages", .selfActivates),
                  BackgroundRefusal.notVisibleToInput("Pages", .minimized), BackgroundRefusal.noTransport("Pages"), BackgroundRefusal.noVerifier("Pages"),
                  BackgroundRefusal.axUnresolved("Pages", window: 1), BackgroundRefusal.siblings("Pages", count: 1)] {
            XCTAssertEqual(e.code, .notSupported, e.message)
            XCTAssertEqual(e.retry, .never)
            XCTAssertTrue(e.suggestion.contains("sandbox") || e.suggestion.contains("Close the other"), e.suggestion)
        }
    }

    func testNoRefusalSuggestsRaisingActivatingOrGlobalInput() {
        let all = [BackgroundRefusal.siblings("A", count: 1), BackgroundRefusal.notKeyWindow("A", focused: 3, window: 1), BackgroundRefusal.noVerifier("A"),
                   BackgroundRefusal.notVisibleToInput("A", .minimized), BackgroundRefusal.blocked("A", .selfActivates), BackgroundRefusal.unverified(basis: "x")]
        for e in all {
            let text = (e.suggestion + e.message).lowercased()
            for bad in ["bring it to the front", "raise", "activate", "unminimize", "switch to", "foreground"] {
                XCTAssertFalse(text.contains(bad), "\(e.message): suggests \(bad)")
            }
        }
    }
}

extension BackgroundRoute {
    static let allCasesForTest: [BackgroundRoute] = [.pidKeys, .windowPointer]
}

final class BackgroundPosterSourceTests: XCTestCase {
    func poster() throws -> String { try HandsSourceTests.code("Sources/BaneySpaces/Hands/BackgroundPoster.swift") }

    func testThePosterNeverNamesTheSessionOrHIDTapsOrTheCursorOrAnActivation() throws {
        let text = try poster()
        for banned in ["CGEventPost(", "CGEventTapPost", "cghidEventTap", "cgSessionEventTap", "cgAnnotatedSessionEventTap", "CGWarpMouse", "CGDisplayMoveCursor",
                       "CGAssociateMouse", "CGEventPostToPSN", "activate(", "SetFrontProcess", "SLPSSetFrontProcess", "SLPSPostEventRecordTo", "AXRaise",
                       "NSApp.activate", "makeKeyAndOrderFront", "AXUIElementPerformAction", "osascript", "Process()", "orderFront", "SLSSetFrontProcess"] {
            XCTAssertFalse(text.contains(banned), "BackgroundPoster must not use \(banned)")
        }
        XCTAssertTrue(text.contains("postToPid"), "events go to one process")
    }

    func testSkyLightIsFoundByNameAtRunTimeWithAFallback() throws {
        let text = try poster()
        XCTAssertTrue(text.contains("dlopen(") && text.contains("dlsym("), "SkyLight symbols are resolved at run time")
        XCTAssertTrue(text.contains("SLEventPostToPid"))
        XCTAssertTrue(text.contains("event.postToPid(permit.pid)"), "the public per-process call is the fallback")
        XCTAssertTrue(text.contains("symbol(\"SLEventPostToPid\").map"), "a missing symbol is nil, not a crash")
        XCTAssertFalse(text.contains("@_silgen_name"), "no link-time import of a private function")
        XCTAssertFalse(text.contains("unsafeBitCast(dlsym"), "the optional symbol is mapped, never force-cast")
    }

    func testEveryPostNeedsAPermitAndEveryEntryPointTakesOne() throws {
        let text = try poster()
        XCTAssertTrue(text.contains("private static func post(_ event: CGEvent, _ permit: BackgroundPermit)"))
        let posts = text.components(separatedBy: "post(event, permit)").count - 1
        XCTAssertGreaterThanOrEqual(posts, 2)
        for entry in ["static func keys(", "static func pointer("] {
            let sig = try XCTUnwrap(text.range(of: entry))
            let line = text[sig.lowerBound...].prefix(while: { $0 != "{" })
            XCTAssertTrue(line.contains("permit: BackgroundPermit"), "\(entry) takes a permit")
        }
        XCTAssertEqual(text.components(separatedBy: ".postToPid(").count - 1, 1, "one public post site")
    }

    func testOnlyThePosterMakesEvents() throws {
        for f in try HandsSourceTests.handsFiles() where !f.hasSuffix("/BackgroundPoster.swift") {
            let text = try HandsSourceTests.code(f)
            XCTAssertFalse(text.contains("CGEvent("), "\(f) must not make events")
            XCTAssertFalse(text.contains("postToPid"), "\(f) must not post events")
            XCTAssertFalse(text.contains("SLEventPostToPid"), "\(f) must not post events")
        }
    }

    func testThePointerPostsNeverMoveTheRealCursor() throws {
        let text = try poster()
        XCTAssertTrue(text.contains("static func pointerLocation()"), "the pointer is sampled, not moved")
        XCTAssertTrue(text.contains("stamp(event, 40, Int64(permit.pid))"), "the target pid is on every pointer event")
        XCTAssertTrue(text.contains("stamp(event, 91, window)") && text.contains("stamp(event, 92, window)") && text.contains("stamp(event, 51, window)"))
        XCTAssertTrue(text.contains("event.flags = CGEventFlags(rawValue: chord.flags)"), "key flags are exactly the chord's, never inherited")
    }

    func testThePipelineChecksScopeAndFactsOnTheProcessQueueBeforeItPosts() throws {
        let text = try HandsSourceTests.code("Sources/BaneySpaces/Hands/HandsRouter+Background.swift")
        let perform = try XCTUnwrap(text.range(of: "HandsEngine.shared.perform(window: w, check: scopeCheck)"))
        let gather = try XCTUnwrap(text.range(of: "gatherFacts(w, kind: kind"))
        let plan = try XCTUnwrap(text.range(of: "BackgroundPlanner.plan(facts)"))
        let post = try XCTUnwrap(text.range(of: "BackgroundPoster.keys(chords"))
        let postPointer = try XCTUnwrap(text.range(of: "BackgroundPoster.pointer(path"))
        XCTAssertTrue(perform.lowerBound < gather.lowerBound && gather.lowerBound < plan.lowerBound)
        XCTAssertTrue(plan.lowerBound < post.lowerBound && plan.lowerBound < postPointer.lowerBound)
        XCTAssertTrue(text.contains("BackgroundPoster.pointerLocation()"), "the pointer is sampled before and after")
        XCTAssertEqual(text.components(separatedBy: "BackgroundPoster.keys(").count - 1, 1, "one key post site")
        XCTAssertEqual(text.components(separatedBy: "BackgroundPoster.pointer(").count - 1, 1, "one pointer post site")
        XCTAssertTrue(text.contains("host.agentOwned()"), "ownership is read at execution")
        XCTAssertTrue(text.contains("AgentActivity.shared.begin(pid: w.pid, window: w.id)"), "the focus guard is held for the whole action")
        XCTAssertTrue(text.contains("defer { AgentActivity.shared.end(token) }"))
        XCTAssertFalse(text.contains("tryNextRoute"), "no second route after a post")
    }

    func testNoProofIsReturnedAsUnverified() throws {
        let text = try HandsSourceTests.code("Sources/BaneySpaces/Hands/HandsRouter+Background.swift")
        XCTAssertTrue(text.contains("BackgroundRefusal.unverified(basis: verdict.basis)"))
        let guardVerified = try XCTUnwrap(text.range(of: "guard verdict.verified else"))
        let success = try XCTUnwrap(text.range(of: "\"verified\": true"))
        XCTAssertTrue(guardVerified.lowerBound < success.lowerBound, "success is only reached with a verified verdict")
    }

    func testTheProbeNamesTheThingsItMustWatchAndRefusesToRunWhileDonovanIsThere() throws {
        let text = try String(contentsOf: HandsSourceTests.root.appendingPathComponent("scripts/agent-keys-probe.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("HIDIdleTime"))
        XCTAssertTrue(text.contains("untested live"))
        XCTAssertTrue(text.contains("exit(3)"))
        XCTAssertTrue(text.contains("0.05"), "sampled every 50 ms")
        for watched in ["front app", "workspace", "pointer", "key window"] { XCTAssertTrue(text.contains(watched), watched) }
        XCTAssertFalse(text.contains("--force"), "no flag lowers the idle bar")
        XCTAssertFalse(text.contains("\"Notes\""), "never a once-per-user app")
    }
}
