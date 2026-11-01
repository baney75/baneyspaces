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

extension KeyChord {
    func withLabel(_ l: String) -> KeyChord { KeyChord(keyCode: keyCode, flags: flags, label: l) }
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

    func testACapitalAfterAModifierIsTheSameKeyAsTheLowercase() throws {
        XCTAssertEqual(try chord("cmd+A").withLabel("x"), try chord("cmd+a").withLabel("x"))
        XCTAssertEqual(try chord("cmd+S").flags, KeyChord.command, "cmd+S is Save, not Save As")
        XCTAssertEqual(try chord("cmd+shift+S").flags, KeyChord.command | KeyChord.shift)
    }

    func testSequencesAreSeparatedBySpaces() throws {
        let seq = try KeyParse.sequence("h i Return cmd+a").get()
        XCTAssertEqual(seq.map(\.keyCode), [4, 34, 36, 0])
        XCTAssertEqual(seq.last?.flags, KeyChord.command)
    }

    func testBadKeysAreBadArgumentsWithAHint() {
        for bad in ["", "   ", "hyper+a", "nosuchkey", "cmd+shift+nosuchkey", "ab"] {
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
        var noElement = ready(); noElement.focusedElementWindow = nil
        XCTAssertNotNil(try? BackgroundPlanner.plan(noElement).get(), "the window has the keys and there is no element to be wrong about")
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

    func testAPointerEventIsNeverPostedWithAnyFieldOfTheRecipeMissing() {
        var f = ready(.pointer)
        f.transports = TransportSupport(skyLight: true, publicPid: true, pointerStamps: false)
        let e = refusal(f)
        XCTAssertEqual(e?.code, .notSupported)
        XCTAssertEqual(e?.retry, .never)
        var publicOnly = ready(.pointer)
        publicOnly.transports = TransportSupport(skyLight: false, publicPid: true, pointerStamps: false)
        XCTAssertEqual(refusal(publicOnly)?.code, .notSupported, "the public fallback cannot name the window either")
        // Keys carry no window fields, so they do not need the stamps.
        var keys = ready(); keys.transports = TransportSupport(skyLight: false, publicPid: true, pointerStamps: false)
        XCTAssertNotNil(try? BackgroundPlanner.plan(keys).get())
    }

    func testAPointInTheTitleBarIsRefused() {
        var f = ready(.pointer); f.pointInTitleBar = true
        let e = refusal(f)
        XCTAssertEqual(e?.code, .badArguments)
        XCTAssertTrue(e?.suggestion.contains("title bar") ?? false)
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

final class ProbeAppPolicyTests: XCTestCase {
    func testTheProbeAppStartsOnlyFromTheBundlesProbeFolderAndOnlyWhenItsSignatureWasChecked() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("probe-policy-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Resources/probe"), other = root.appendingPathComponent("elsewhere")
        for d in [folder, other] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: root) }
        let inside = folder.appendingPathComponent("CanvasProbe.app"), outside = other.appendingPathComponent("CanvasProbe.app")
        let b = AgentAppPolicy.canvasProbeBundle
        XCTAssertNil(AgentAppPolicy.refusal(app: "CanvasProbe", bundle: b, appURL: inside, probeFolder: folder, probeTrusted: true))
        XCTAssertEqual(AgentAppPolicy.refusal(app: "CanvasProbe", bundle: b, appURL: inside, probeFolder: folder, probeTrusted: false)?.code, .needsSandbox,
                       "in the folder but the signature was not confirmed")
        XCTAssertEqual(AgentAppPolicy.refusal(app: "CanvasProbe", bundle: b, appURL: outside, probeFolder: folder, probeTrusted: true)?.code, .needsSandbox, "another place")
        XCTAssertNotNil(AgentAppPolicy.refusal(app: "CanvasProbe", bundle: b), "no location, no start")
        XCTAssertNotNil(AgentAppPolicy.refusal(app: "CanvasProbe", bundle: b, appURL: inside, probeFolder: nil, probeTrusted: true), "a build without a bundle has no probe app")
        // A link out of the folder is followed.
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent("Link.app")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertNotNil(AgentAppPolicy.refusal(app: "Link", bundle: b, appURL: link, probeFolder: folder, probeTrusted: true))
        // Nothing else gains from the folder or the flag.
        XCTAssertNotNil(AgentAppPolicy.refusal(app: "Safari", bundle: "com.apple.Safari", appURL: inside, probeFolder: folder, probeTrusted: true))
        XCTAssertTrue(AgentAppPolicy.needsSeparateInstance(bundle: b))
    }

    func testTheTrustCheckComparesTheTeamAndTheRecordedCodeHashInsideTheBundle() throws {
        let text = try HandsSourceTests.code("Sources/BaneySpaces/Hands/BackgroundWatch.swift")
        let trust = try XCTUnwrap(HandsSourceTests.block(after: "static func trusted(", in: text))
        for needed in ["Bundle.main.resourceURL", "SecCodeCheckValidity", "SecStaticCodeCheckValidityWithErrors", "kSecCodeInfoTeamIdentifier",
                       "kSecCodeInfoUnique", "CanvasProbe.cdhash", "isProbeApp("] { XCTAssertTrue(trust.contains(needed) || text.contains(needed), needed) }
        let bundle = try String(contentsOf: HandsSourceTests.root.appendingPathComponent("scripts/bundle.sh"), encoding: .utf8)
        XCTAssertTrue(bundle.contains("Resources/probe/CanvasProbe.app"))
        XCTAssertTrue(bundle.contains("CanvasProbe.cdhash"), "the hash is recorded when the bundle is built")
        let codesignProbe = bundle.range(of: "--identifier com.baney.baneyspaces.canvasprobe \"$PROBE\"")
        let codesignApp = bundle.range(of: "--identifier com.baney.baneyspaces \"$APP\"")
        XCTAssertNotNil(codesignProbe)
        XCTAssertTrue(codesignProbe!.lowerBound < codesignApp!.lowerBound, "the probe app is signed before the app that seals it")
    }

    func testTheLicenceOfPortedCodeIsCopiedIntoTheBundleAndCIChecksIt() throws {
        let bundle = try String(contentsOf: HandsSourceTests.root.appendingPathComponent("scripts/bundle.sh"), encoding: .utf8)
        XCTAssertTrue(bundle.contains("cp LICENSES/* \"$APP/Contents/Resources/licenses/\""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: HandsSourceTests.root.appendingPathComponent("LICENSES/cua-driver-MIT.txt").path))
        let ci = try String(contentsOf: HandsSourceTests.root.appendingPathComponent(".github/workflows/ci.yml"), encoding: .utf8)
        XCTAssertTrue(ci.contains("licenses/cua-driver-MIT.txt"), "the bundle job fails if the licence is missing from the built app")
    }
}

final class DeliveryProofTests: XCTestCase {
    let target: UInt32 = 77
    func el(_ value: String, window: UInt32? = 77, id: String = "AXTextArea|0,0,100,40", sel: (Int, Int)? = nil, attrs: String? = nil) -> ElementReading {
        ElementReading.text(window: window, identity: id, value: value, selection: sel, attributes: attrs)
    }
    let none: ReadingPair = (nil, nil)
    func keys(_ spec: String, ref: ReadingPair = (nil, nil), focus: ReadingPair = (nil, nil), content: Bool? = nil,
              window: (WindowReading?, WindowReading?) = (nil, nil), pixels: PixelChange? = nil) -> DeliveryVerdict {
        DeliveryProof.keys(target: target, chords: try! KeyParse.sequence(spec).get(), ref: ref, focus: focus, content: content, window: window, pixels: pixels)
    }

    func testTypedLettersAreProvedByTheValueOfTheTargetedElement() {
        let v = keys("h i", ref: (el("a"), el("hia")))
        XCTAssertTrue(v.verified)
        XCTAssertEqual(v.basis, "value_changed")
    }

    func testSelectAllAndMovementAreProvedBySelectionNotByValue() {
        let v = keys("cmd+a", focus: (el("hello", sel: (5, 0)), el("hello", sel: (0, 5))))
        XCTAssertTrue(v.verified)
        XCTAssertEqual(v.basis, "selection_changed")
        XCTAssertTrue(keys("alt+Left", focus: (el("ab cd", sel: (5, 0)), el("ab cd", sel: (3, 0)))).verified)
        XCTAssertTrue(keys("shift+alt+Right", focus: (el("ab cd", sel: (0, 0)), el("ab cd", sel: (0, 2)))).verified)
    }

    func testAValueChangeDoesNotProveAKeyThatPredictsASelection() {
        // cmd+a must select; the text changing instead is something else happening.
        let v = keys("cmd+a", focus: (el("hello", sel: (5, 0)), el("hellox", sel: (5, 0))))
        XCTAssertFalse(v.verified)
        XCTAssertEqual(v.basis, "unpredicted_change")
    }

    func testBoldIsProvedByTheAttributesOfTheTargetedText() {
        let before = el("plain", sel: (0, 5), attrs: "0+5:font=Helvetica")
        let v = keys("cmd+b", focus: (before, el("plain", sel: (0, 5), attrs: "0+5:font=Helvetica-Bold")))
        XCTAssertTrue(v.verified)
        XCTAssertEqual(v.basis, "attributes_changed")
        XCTAssertFalse(keys("cmd+b", focus: (before, before), content: false).verified)
        // A different part of the tree changing does not stand in for it when the attributes can be read.
        XCTAssertFalse(keys("cmd+b", focus: (before, before), content: true).verified)
        // Where the element cannot give its attributes, the toggled Bold checkbox is the next best proof.
        let silent = el("plain", sel: (0, 5))
        XCTAssertTrue(keys("cmd+b", focus: (silent, silent), content: true).verified)
    }

    func testTabIsProvedByFocusMovingInsideTheWindow() {
        let v = keys("Tab", focus: (el("a", id: "AXTextField|0,0,10,10"), el("b", id: "AXButton|0,20,10,10")))
        XCTAssertTrue(v.verified)
        XCTAssertEqual(v.basis, "focus_moved")
    }

    func testSaveIsProvedByTheWindowChangingNotByAnyElement() {
        let edited = WindowReading(titleDigest: 1, edited: true, sheets: 0)
        let saved = WindowReading(titleDigest: 1, edited: false, sheets: 0)
        XCTAssertTrue(keys("cmd+s", window: (edited, saved)).verified)
        XCTAssertEqual(keys("cmd+s", window: (edited, saved)).basis, "window_changed")
        XCTAssertFalse(keys("cmd+s", focus: (el("a"), el("ab")), window: (edited, edited)).verified, "an element changing is not a save")
    }

    func testAnAppWithNoTextFocusIsProvedByItsContentAndOnlyByTheNoiseFilteredContent() {
        // Calculator: no field to type into, so the window's content is what the keys change.
        XCTAssertTrue(keys("9 asterisk 8 Return", content: true).verified)
        XCTAssertEqual(keys("9", content: true).basis, "content_changed")
        XCTAssertFalse(keys("9", content: false).verified)
        // A text field in focus predicts a change to the field; a changing clock does not stand in for it.
        let v = keys("h i", ref: (el("a"), el("a")), content: true)
        XCTAssertFalse(v.verified)
        XCTAssertEqual(v.basis, "unpredicted_change")
    }

    func testAReadingFromAnotherWindowOfTheSameProcessNeverProvesAnything() {
        XCTAssertFalse(keys("h i", focus: (el("a", window: 88), el("ab", window: 88))).verified)
        XCTAssertFalse(keys("h i", focus: (el("a", window: nil), el("ab", window: nil))).verified, "a reading with no window proves nothing")
        XCTAssertFalse(keys("h i", focus: (el("a", window: 77), el("ab", window: 88))).verified)
    }

    func testPixelsAloneNeverProveKeys() {
        let v = keys("h i", ref: (el("a"), el("a")), pixels: PixelChange(insideChanged: 5000, insideTotal: 9000, outsideChanged: 10, outsideTotal: 100))
        XCTAssertFalse(v.verified)
        XCTAssertEqual(v.basis, "pixels_only")
    }

    func testNothingChangedAndNothingReadAreDifferentAnswersNeitherVerified() {
        XCTAssertEqual(keys("h i", ref: (el("a"), el("a")), content: false).basis, "no_change")
        XCTAssertEqual(keys("h i").basis, "no_reading")
    }

    func testContentIsHashedNotKept() {
        let r = el("Donovan's private text")
        XCTAssertEqual(r.valueLength, 22)
        XCTAssertNotNil(r.valueDigest)
        XCTAssertEqual(ElementReading.digest("abc"), ElementReading.digest("abc"))
        XCTAssertNotEqual(ElementReading.digest("abc"), ElementReading.digest("abd"))
    }

    func testThePredictionTableAndWhenSilenceIsEvidence() {
        func exp(_ s: String, text: Bool) -> Set<KeyEffect> { KeyPrediction.expected(try! KeyParse.sequence(s).get(), focusIsText: text) }
        XCTAssertEqual(exp("a", text: true), [.text])
        XCTAssertEqual(exp("Return", text: true), [.text])
        XCTAssertEqual(exp("a", text: false), [.content])
        XCTAssertEqual(exp("Left", text: true), [.selection])
        XCTAssertEqual(exp("cmd+a", text: false), [.selection])
        XCTAssertEqual(exp("cmd+b", text: true), [.attributes])
        XCTAssertEqual(exp("cmd+s", text: true), [.window])
        XCTAssertEqual(exp("Tab", text: true), [.focus])
        XCTAssertEqual(exp("h cmd+a", text: true), [.text, .selection])
        XCTAssertTrue(KeyPrediction.certainToShow(try! KeyParse.sequence("h i").get(), focusIsText: true))
        XCTAssertFalse(KeyPrediction.certainToShow(try! KeyParse.sequence("Home").get(), focusIsText: true), "Home at the top changes nothing")
        XCTAssertFalse(KeyPrediction.certainToShow(try! KeyParse.sequence("h").get(), focusIsText: false))
    }

    func testOnlyContentBeyondWhatChangedOnItsOwnCounts() throws {
        func tree(_ rows: [String]) -> JSONValue {
            .object(["role": "window", "children": .array(rows.map { .object(["role": "statictext", "name": .string($0), "value": .string($0)]) })])
        }
        let base1 = tree(["clock 10:00:01", "display 0"])
        let base2 = tree(["clock 10:00:02", "display 0"])
        XCTAssertFalse(ContentChange.changed(base1: base1, base2: base2, after: tree(["clock 10:00:01", "display 0"])), "nothing but what already moved")
        XCTAssertFalse(ContentChange.changed(base1: base1, base2: base2, after: tree(["clock 10:00:02", "display 0"])), "the clock ticking on is not the action")
        XCTAssertTrue(ContentChange.changed(base1: base1, base2: base2, after: tree(["clock 10:00:02", "display 72"])))
    }

    func testAStrokeIsProvedByPixelsAlongItWhileTheRestStaysPut() {
        let stroke = PixelChange(insideChanged: 400, insideTotal: 5000, outsideChanged: 3, outsideTotal: 40000)
        let v = DeliveryProof.pointer(target: target, ref: none, focus: none, content: nil, pixels: stroke)
        XCTAssertTrue(v.verified)
        XCTAssertEqual(v.basis, "pixels_along_stroke")
    }

    func testAWholeWindowRepaintASpeckOrAHoverIsNotAStroke() {
        let repaint = PixelChange(insideChanged: 400, insideTotal: 5000, outsideChanged: 20000, outsideTotal: 40000)
        XCTAssertFalse(DeliveryProof.pointer(target: target, ref: none, focus: none, content: nil, pixels: repaint).verified)
        let speck = PixelChange(insideChanged: 3, insideTotal: 5000, outsideChanged: 0, outsideTotal: 40000)
        XCTAssertFalse(DeliveryProof.pointer(target: target, ref: none, focus: none, content: nil, pixels: speck).verified)
        let caretElsewhere = PixelChange(insideChanged: 0, insideTotal: 5000, outsideChanged: 12, outsideTotal: 40000)
        let v = DeliveryProof.pointer(target: target, ref: none, focus: none, content: nil, pixels: caretElsewhere)
        XCTAssertFalse(v.verified)
        XCTAssertEqual(v.basis, "pixels_only")
    }

    func testTheMinimumGrowsWithTheStrokeSoAHoverSizedChangeCannotProveALongDrag() {
        let path = PointerPath.line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 300, y: 0), steps: 12)
        let need = PointerPath.strokeMinimum(path: path, scale: 2)
        XCTAssertEqual(need, 300)
        let hoverSized = PixelChange(insideChanged: 60, insideTotal: 5000, outsideChanged: 0, outsideTotal: 40000)
        XCTAssertTrue(DeliveryProof.pointer(target: target, ref: none, focus: none, content: nil, pixels: hoverSized).verified, "enough for a click")
        XCTAssertFalse(DeliveryProof.pointer(target: target, ref: none, focus: none, content: nil, pixels: hoverSized, minStroke: need).verified)
        XCTAssertEqual(PointerPath.strokeMinimum(path: [CGPoint(x: 5, y: 5)], scale: 2), DeliveryProof.minStrokePixels, "a click needs the flat minimum")
    }

    func testAPointerOnAControlIsProvedByTheTargetWindowChangingNotAnotherWindow() {
        XCTAssertTrue(DeliveryProof.pointer(target: target, ref: none, focus: none, content: true, pixels: nil).verified)
        XCTAssertTrue(DeliveryProof.pointer(target: target, ref: none, focus: (el("a", id: "AXTextField|0,0,1,1"), el("a", id: "AXButton|0,9,1,1")), content: nil, pixels: nil).verified)
        XCTAssertFalse(DeliveryProof.pointer(target: target, ref: none, focus: (el("a", window: 88, id: "x"), el("a", window: 88, id: "y")), content: nil, pixels: nil).verified)
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
    func fake(_ pids: Int64...) -> [SessionEvent] { pids.map(SessionEvent.init(sourcePid:)) }
    let a = CGPoint(x: 5, y: 6), b = CGPoint(x: 90, y: 40)

    func testAPointerThatDidNotMoveIsUnmoved() {
        XCTAssertEqual(PointerAudit.verdict(before: a, after: a, posted: [b], tap: fake(), ownPid: 321), .unmoved)
        XCTAssertNil(PostGuard.PointerVerdict.unmoved.error)
    }

    func testDonovansOwnHandMovingTheMouseIsNotOurFailure() {
        // The fake tap saw hardware movement (source pid 0): his mouse, while the agent worked.
        let v = PointerAudit.verdict(before: a, after: b, posted: [CGPoint(x: 2800, y: 1500)], tap: fake(0, 0, 0), ownPid: 321)
        XCTAssertEqual(v, .userMoved)
        XCTAssertNil(v.error)
        XCTAssertEqual(v.label, "user_moved")
    }

    func testAPointerThatMovedWithNoHardwareToExplainItIsAFailure() {
        let v = PointerAudit.verdict(before: a, after: b, posted: [CGPoint(x: 2800, y: 1500)], tap: fake(), ownPid: 321)
        XCTAssertEqual(v, .moved(from: a, to: b))
        XCTAssertEqual(v.error?.code, .actionFailed)
        XCTAssertEqual(v.error?.retry, .never)
        // Events from other software do not explain it either.
        XCTAssertNotNil(PointerAudit.verdict(before: a, after: b, posted: [], tap: fake(555), ownPid: 321).error)
    }

    func testAPointerThatLandsWhereWePostedIsAFailureEvenWithHardwareEvents() {
        let landed = CGPoint(x: 2820, y: 1530)
        let v = PointerAudit.verdict(before: a, after: landed, posted: [CGPoint(x: 2820.2, y: 1529.9)], tap: fake(0, 0), ownPid: 321)
        XCTAssertEqual(v, .moved(from: a, to: landed))
    }

    func testAnEventOfOurOwnReachingTheSessionIsAFailure() {
        let v = PointerAudit.verdict(before: a, after: a, posted: [b], tap: fake(0, 321, 321), ownPid: 321)
        XCTAssertEqual(v, .leaked(2))
        XCTAssertEqual(v.error?.code, .actionFailed)
    }

    func testNoTapMeansASeenMoveCannotBeBlamedUnlessItLandedOnOurPoint() {
        XCTAssertEqual(PointerAudit.verdict(before: a, after: b, posted: [CGPoint(x: 2800, y: 1500)], tap: nil, ownPid: 321), .unchecked)
        XCTAssertEqual(PointerAudit.verdict(before: a, after: b, posted: [b], tap: nil, ownPid: 321), .moved(from: a, to: b))
        XCTAssertEqual(PointerAudit.verdict(before: nil, after: b, posted: [], tap: fake(), ownPid: 321), .unchecked)
        XCTAssertEqual(PostGuard.PointerVerdict.unchecked.label, "unchecked")
    }

    func testFrontAppChangesAreTold() {
        XCTAssertEqual(PostGuard.front(start: 10, now: 10, target: 500), .same)
        XCTAssertEqual(PostGuard.front(start: 10, now: 500, target: 500), .targetCameForward)
        XCTAssertEqual(PostGuard.front(start: 10, now: 20, target: 500), .other(20))
    }

    func testAFrontAppThatCouldNotBeReadIsNotAPass() {
        XCTAssertEqual(PostGuard.front(start: nil, now: 20, target: 500), .unknown)
        XCTAssertEqual(PostGuard.front(start: 20, now: nil, target: 500), .unknown)
        XCTAssertEqual(BackgroundRefusal.frontUnknown("TextEdit").retry, .never)
    }

    func testAnyActivationDuringTheSpanIsAFailureEvenIfItWasBrief() {
        XCTAssertEqual(PostGuard.activations([], target: 500), .same)
        XCTAssertEqual(PostGuard.activations([20], target: 500), .other(20))
        XCTAssertEqual(PostGuard.activations([20, 500, 10], target: 500), .targetCameForward)
        XCTAssertEqual(PostGuard.activations([500], target: 500), .targetCameForward)
    }

    func testTheFrontChangeRefusalSaysPartOfItMayHaveLanded() {
        let e = BackgroundRefusal.frontChanged("TextEdit", to: 20)
        XCTAssertEqual(e.retry, .never)
        XCTAssertTrue(e.suggestion.contains("part of the input may have landed"))
    }
}

final class RouteBreakerTests: XCTestCase {
    func testAnAppThatCameForwardIsShutOutForThatRouteOnlyWhereverItRuns() {
        var b = RouteBreaker()
        XCTAssertNil(b.block(bundle: "com.apple.TextEdit", pid: 1, kind: .keys))
        b.selfActivated(bundle: "com.apple.TextEdit", kind: .keys)
        XCTAssertEqual(b.block(bundle: "com.apple.TextEdit", pid: 1, kind: .keys), .selfActivates)
        XCTAssertEqual(b.block(bundle: "com.apple.TextEdit", pid: 99, kind: .keys), .selfActivates)
        XCTAssertNil(b.block(bundle: "com.apple.TextEdit", pid: 1, kind: .pointer))
        XCTAssertNil(b.block(bundle: "com.apple.calculator", pid: 2, kind: .keys))
    }

    func testDroppedInputShutsOneProcessNotEveryCopyOfTheApp() {
        var b = RouteBreaker()
        b.dropped(pid: 7, kind: .keys)
        XCTAssertNil(b.block(bundle: "x", pid: 7, kind: .keys))
        b.proved(pid: 7, kind: .keys)
        b.dropped(pid: 7, kind: .keys)
        XCTAssertNil(b.block(bundle: "x", pid: 7, kind: .keys), "a proof in between starts the count again")
        b.dropped(pid: 7, kind: .keys)
        XCTAssertEqual(b.block(bundle: "x", pid: 7, kind: .keys), .refusesBackgroundInput)
        XCTAssertNil(b.block(bundle: "x", pid: 8, kind: .keys), "another copy of the same app is not blamed")
    }
}

final class BalancedEventsTests: XCTestCase {
    struct Stop: Error {}
    let stopError = HandsError(.actionFailed, "stopped", suggestion: "x", retry: .never)

    /// Runs `events` stopping at the `n`th question (0-based) asked before a new press or move; returns what was posted.
    func run(_ events: [InputEvent], stopAt n: Int?) -> RunReport {
        var asked = 0
        return EventRunner.run(events, stop: {
            defer { asked += 1 }
            return asked == n ? self.stopError : nil
        }, post: { _ in true })
    }

    /// Every press has its release, last pressed first released, and nothing new follows the stop.
    func assertBalanced(_ r: RunReport, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        var held: [InputEvent] = []
        for e in r.posted {
            switch e {
            case .keyDown, .mouseDown: held.append(e)
            case .keyUp(let c):
                guard case .keyDown(let h)? = held.last, h == c else { return XCTFail("\(label): key up out of order", file: file, line: line) }
                held.removeLast()
            case .mouseUp:
                guard case .mouseDown? = held.last else { return XCTFail("\(label): mouse up with no mouse down", file: file, line: line) }
                held.removeLast()
            default: break
            }
        }
        XCTAssertTrue(held.isEmpty, "\(label): left pressed: \(held)", file: file, line: line)
    }

    func nonReleases(_ events: [InputEvent]) -> Int { events.filter { !$0.isRelease }.count }

    func testAStopAtEveryStepOfAChordLeavesNothingPressed() throws {
        let chords = try KeyParse.sequence("cmd+a b Return").get()
        let events = InputScript.chords(chords)
        for n in 0...nonReleases(events) {
            let r = run(events, stopAt: n)
            assertBalanced(r, "chord stop \(n)")
            if n < nonReleases(events) {
                XCTAssertEqual(r.stopped?.code, .actionFailed, "stop \(n)")
                XCTAssertEqual(r.posted.filter(\.isPress).count, n, "nothing new is pressed after the stop (\(n))")
            } else { XCTAssertNil(r.stopped) }
        }
    }

    func testAStopAtEveryStepOfAClickLeavesTheButtonUp() {
        let events = InputScript.hover(at: CGPoint(x: 5, y: 5)) + InputScript.click(at: CGPoint(x: 5, y: 5))
        for n in 0...nonReleases(events) {
            let r = run(events, stopAt: n)
            assertBalanced(r, "click stop \(n)")
            XCTAssertEqual(r.posted.filter { if case .mouseUp = $0 { return true }; return false }.count, r.posted.filter { if case .mouseDown = $0 { return true }; return false }.count)
        }
    }

    func testAStopAtEveryStepOfADragReleasesWhereTheGestureStands() {
        let path = PointerPath.line(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 60), steps: 6)
        let events = InputScript.hover(at: path[0]) + InputScript.drag(path: path)
        for n in 0...nonReleases(events) {
            let r = run(events, stopAt: n)
            assertBalanced(r, "drag stop \(n)")
            let downs = r.posted.filter { if case .mouseDown = $0 { return true }; return false }.count
            if downs == 1, n < nonReleases(events) {
                // Released where the last event stood, once.
                guard case .mouseUp(let at)? = r.posted.last else { return XCTFail("drag stop \(n): no release last") }
                let lastMove = r.posted.dropLast().reversed().compactMap { e -> CGPoint? in
                    switch e { case .mouseDown(let p), .mouseDragged(let p): return p; default: return nil }
                }.first
                XCTAssertEqual(at, lastMove, "drag stop \(n)")
                XCTAssertEqual(r.released, 1)
            }
        }
    }

    func testTheStopIsNeverAskedBeforeARelease() {
        var asks = 0
        var order: [String] = []
        _ = EventRunner.run(InputScript.chords([KeyChord(keyCode: 0, flags: 0, label: "a")]), stop: { asks += 1; order.append("ask"); return nil },
                            post: { e in order.append(e.isRelease ? "up" : "down"); return true })
        XCTAssertEqual(order, ["ask", "down", "up"], "asked before the press only")
        XCTAssertEqual(asks, 1)
    }

    func testAnEventThatCannotBeMadeStopsTheRunAndReleasesWhatIsDown() {
        let c = KeyChord(keyCode: 0, flags: 0, label: "a")
        var n = 0
        let r = EventRunner.run([.keyDown(c), .mouseDown(.zero), .mouseUp(.zero), .keyUp(c)], stop: { nil }, post: { e in
            n += 1
            if case .mouseDown = e { return false }
            return true
        })
        XCTAssertEqual(r.stopped?.code, .engineError)
        XCTAssertEqual(r.posted, [.keyDown(c), .keyUp(c)], "the key already down is released")
        XCTAssertEqual(r.released, 1)
    }

    func testAReleaseThatFailsToPostDoesNotStopTheOthers() {
        let a = KeyChord(keyCode: 0, flags: 0, label: "a"), b = KeyChord(keyCode: 11, flags: 0, label: "b")
        let r = EventRunner.run([.keyDown(a), .keyDown(b), .keyDown(b)], stop: { self.stopError }, post: { e in
            if case .keyUp(let c) = e, c == b { return false }
            return true
        })
        XCTAssertTrue(r.posted.isEmpty, "stopped before anything")
        var asked = 0
        let r2 = EventRunner.run([.keyDown(a), .keyDown(b), .keyDown(b)], stop: { [stopError] in asked += 1; return asked > 2 ? stopError : nil }, post: { e in
            if case .keyUp(let c) = e, c == b { return false }
            return true
        })
        XCTAssertEqual(r2.posted, [.keyDown(a), .keyDown(b), .keyUp(a)], "a's release is sent although b's could not be")
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
        XCTAssertGreaterThanOrEqual(text.components(separatedBy: "post(e, permit)").count - 1, 2)
        for entry in ["static func keys(", "static func pointer("] {
            let sig = try XCTUnwrap(text.range(of: entry))
            let line = text[sig.lowerBound...].prefix(while: { $0 != "{" })
            XCTAssertTrue(line.contains("permit: BackgroundPermit"), "\(entry) takes a permit")
        }
        XCTAssertEqual(text.components(separatedBy: ".postToPid(").count - 1, 1, "one public post site")
    }

    func testEveryScriptRunsThroughTheBalancedRunner() throws {
        let text = try poster()
        XCTAssertEqual(text.components(separatedBy: "EventRunner.run(").count - 1, 2, "keys and pointer both go through it")
        XCTAssertFalse(text.contains("Thread.sleep(forTimeInterval: 0.008)\n            }"), "no hand-rolled loop of down and up")
        XCTAssertFalse(text.contains("for down in"), "no loop that can leave a key down")
    }

    func testAPointerEventIsNeverHalfStamped() throws {
        let text = try poster()
        XCTAssertTrue(text.contains("guard let setField = setIntegerField, let setLocation = setWindowLocation else"), "both setters or nothing is posted")
        XCTAssertFalse(text.contains("default: break"), "no public fallback that silently drops a field")
        XCTAssertTrue(text.contains("pointerStamps: setIntegerField != nil && setWindowLocation != nil"))
        for f in ["1", "3", "7", "40", "51", "91", "92", "58"] { XCTAssertTrue(text.contains("setField(raw, \(f),"), "field \(f)") }
        XCTAssertTrue(text.contains("setLocation(raw,"))
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
        XCTAssertTrue(text.contains("event.flags = CGEventFlags(rawValue: chord.flags)") || text.contains("e.flags = CGEventFlags(rawValue: chord.flags)"), "key flags are exactly the chord's, never inherited")
    }

    func testTheWholeActionIsOneTransactionOnTheProcessQueue() throws {
        let text = try HandsSourceTests.code("Sources/BaneySpaces/Hands/HandsRouter+Background.swift")
        let transaction = try XCTUnwrap(text.range(of: "HandsEngine.shared.transaction(window: w, check: scopeCheck)"))
        let transact = try XCTUnwrap(HandsSourceTests.block(after: "private func transact(", in: text))
        // Inside it, in this order: watch, read before, facts, plan, post, read after.
        let order = ["ActivationWatch()", "SessionTap()", "refReading()", "gatherFacts(w, kind: kind", "BackgroundPlanner.plan(facts)",
                     "BackgroundPoster.keys(chords", "BackgroundPoster.pointer(", "DeliveryProof.keys(", "PointerAudit.verdict("]
        var last = transact.startIndex
        for marker in order {
            let r = try XCTUnwrap(transact.range(of: marker), marker)
            XCTAssertTrue(r.lowerBound >= last, "\(marker) is out of order")
            last = r.lowerBound
        }
        XCTAssertNotNil(transaction)
        // The readings before the post are the transaction's own, not read outside the queue.
        XCTAssertFalse(text.contains("HandsEngine.shared.get("), "reads inside the transaction are inline")
        XCTAssertFalse(text.contains("HandsEngine.shared.snapshot("), "reads inside the transaction are inline")
        XCTAssertTrue(text.contains("HandsEngine.shared.getInline(") && text.contains("HandsEngine.shared.snapshotInline("))
        XCTAssertEqual(text.components(separatedBy: "BackgroundPoster.keys(").count - 1, 1, "one key post site")
        XCTAssertEqual(text.components(separatedBy: "BackgroundPoster.pointer(").count - 1, 2, "the hover, then the press")
        XCTAssertTrue(text.contains("host.agentOwned()"), "ownership is read at execution")
        XCTAssertTrue(text.contains("AgentActivity.shared.begin(pid: w.pid, window: w.id)"), "the focus guard is held for the whole action")
        XCTAssertTrue(text.contains("defer { AgentActivity.shared.end(token) }"))
        XCTAssertFalse(text.contains("tryNextRoute"), "no second route after a post")
    }

    func testTheEngineHasInlineReadsThatRefuseToRunOffTheQueue() throws {
        let engine = try HandsSourceTests.code("Sources/BaneySpaces/Hands/HandsEngine.swift")
        XCTAssertTrue(engine.contains("precondition(isOnQueue(of: w.pid), \"getInline runs inside a transaction\")"))
        XCTAssertTrue(engine.contains("precondition(isOnQueue(of: w.pid), \"snapshotInline runs inside a transaction\")"))
        XCTAssertTrue(engine.contains("q.setSpecific(key: Self.queueKey, value: pid)"))
        XCTAssertTrue(engine.contains("func transaction(window w: HandsWindow"))
    }

    func testTheSpanIsWatchedByTheWorkspaceNotBySamples() throws {
        let watch = try HandsSourceTests.code("Sources/BaneySpaces/Hands/BackgroundWatch.swift")
        XCTAssertTrue(watch.contains("NSWorkspace.didActivateApplicationNotification"))
        XCTAssertTrue(watch.contains("options: .listenOnly"), "the session tap only listens")
        XCTAssertTrue(watch.contains(".cgSessionEventTap"))
        let router = try HandsSourceTests.code("Sources/BaneySpaces/Hands/HandsRouter+Background.swift")
        XCTAssertTrue(router.contains("PostGuard.activations(activations.activated"))
        XCTAssertTrue(router.contains("PointerAudit.verdict("))
        // The span closes after the proof loop, not after the post.
        let loop = try XCTUnwrap(router.range(of: "} while !verdict.verified"))
        let closing = try XCTUnwrap(router.range(of: "let events = tap.stop()"))
        XCTAssertTrue(loop.lowerBound < closing.lowerBound)
    }

    func testOwnershipComparesStartTimeSoAReusedPidFails() throws {
        let deck = try HandsSourceTests.code("Sources/BaneySpaces/Deck/DeckController.swift")
        let pids = try XCTUnwrap(HandsSourceTests.block(after: "var pids: Set<Int32>", in: deck))
        XCTAssertTrue(pids.contains("startedAt: Self.startTime($0)"))
        var set = AgentOwnedSet()
        set.add(10, startedAt: 1000)
        XCTAssertTrue(set.contains(10, startedAt: 1000))
        XCTAssertFalse(set.contains(10, startedAt: 2000), "the same pid, a different process")
        let router = try HandsSourceTests.code("Sources/BaneySpaces/Hands/HandsRouter+Background.swift")
        XCTAssertTrue(router.contains("pidIsAgentOwned: owned.contains(w.pid)"), "owned comes from AgentOwned.pids, which has already compared start times")
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

    func testTheProbeUsesKeysThatAOneLineTextViewCanShowAndCleansUpOnEveryExit() throws {
        let text = try String(contentsOf: HandsSourceTests.root.appendingPathComponent("scripts/agent-keys-probe.swift"), encoding: .utf8)
        for needed in ["AXSelectedTextRange", "alt+Left", "shift+alt+Right", "cmd+a", "cmd+b", "Return", "func cleanup()"] { XCTAssertTrue(text.contains(needed), needed) }
        XCTAssertFalse(text.contains("\"Home\"") || text.contains("\"End\""), "Home and End change nothing in a short document")
        XCTAssertFalse(text.contains("defer { try?"), "exit skips defer; cleanup() runs before every exit")
        XCTAssertGreaterThanOrEqual(text.components(separatedBy: "cleanup()").count - 1, 4)
    }
}
