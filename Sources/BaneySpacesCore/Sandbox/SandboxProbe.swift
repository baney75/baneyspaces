import Foundation

/// up → self-check → reset ×3 → down, timed, headless (no window is ever asked for). The same
/// sequence `scripts/sandbox-probe.swift` runs against the real Tart.
public enum SandboxProbe {
    public struct Step: Equatable, Sendable {
        public var name: String
        public var seconds: TimeInterval
        public var ok: Bool
        public var detail: String
    }

    public struct Report: Sendable {
        public var steps: [Step] = []
        public var passed: Bool { !steps.isEmpty && steps.allSatisfy(\.ok) }
    }

    /// `markerCheck` proves the guest is clean after a reset: a file written before it must be gone.
    public static func run(manager: SandboxManager, tart: SandboxTart, resets: Int = 3, clock: SandboxClock,
                           warmLimit: TimeInterval = 900, plantLinks: Bool = true, log: (String) -> Void = { _ in }) -> Report {
        var report = Report()
        try? FileManager.default.removeItem(at: manager.paths.handoffRoot.appendingPathComponent("probe")) // the probe's own task folder, fresh
        func step(_ name: String, _ body: () throws -> (Bool, String)) {
            let t0 = clock.now()
            var ok = false, detail = ""
            do { (ok, detail) = try body() } catch { detail = "\(error)" }
            let s = Step(name: name, seconds: clock.now() - t0, ok: ok, detail: detail)
            report.steps.append(s)
            log(String(format: "%@ %@ %.1f s %@", ok ? "ok  " : "FAIL", name, s.seconds, detail))
        }
        step("up (clone or resume, boot, self-check)") {
            let s = try manager.up(task: "probe")
            let u = s.lastUp
            return (s.phase == .running && s.selfcheck == "passed",
                    "route=\(u?.route ?? "?") boot=\(Int((u?.bootSeconds ?? 0) * 1000)) ms selfcheck=\(Int((u?.selfcheckSeconds ?? 0) * 1000)) ms")
        }
        for i in 1...max(1, resets) {
            step("warm clone ready before reset \(i)") {
                let ok = manager.waitUntilWarm(limit: warmLimit)
                return (ok, ok ? "ready" : "not ready in \(Int(warmLimit)) s")
            }
            step("write marker in guest") {
                guard let vm = manager.snapshot().vm else { return (false, "no VM") }
                let r = tart.guest(vm, "touch /tmp/bsx-dirty-\(i) && ls /tmp/bsx-dirty-\(i)", timeout: 30)
                return (r.ok, r.ok ? "written" : r.tail)
            }
            step("reset \(i)") {
                let t = try manager.reset()
                // The budget is for p90 over the run; one slow reset is reported, not a failure of its own.
                return (t.route != .cold, "from=\(t.from.rawValue) route=\(t.route.rawValue) \(t.ms) ms (budget \(Int(SandboxPin.resetBudget * 1000)) ms) [\(t.breakdown)]")
            }
            step("in-guest self-check after reset \(i)") {
                let done = manager.waitUntilVerified(limit: 180)
                let snap = manager.snapshot()
                return (done && snap.selfcheck == "passed" && snap.phase == .running, "selfcheck=\(snap.selfcheck)")
            }
            step("guest is clean after reset \(i)") {
                guard let vm = manager.snapshot().vm else { return (false, "no VM") }
                let r = tart.guest(vm, "ls /tmp/bsx-dirty-* 2>/dev/null | wc -l", timeout: 30)
                let n = Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
                return (r.ok && n == 0, r.ok ? "\(n) marker files" : r.tail)
            }
        }
        step("reset times p50/p90 (p90 must be within the budget)") {
            let st = manager.snapshot().resetStats
            return (st.p90WithinBudget, st.summary)
        }
        step("a root guest that turns IPv6 back on reaches nothing over IPv6") {
            guard let vm = manager.snapshot().vm else { return (false, "no VM") }
            let problems = SandboxSelfcheck.rootIPv6Attempt(vm: vm, tart: tart, hostFacts: manager.facts)
            let after = SandboxSelfcheck.run(vm: vm, tart: tart, hostFacts: manager.facts)
            return (problems.isEmpty && after.passed, problems.isEmpty ? "link-local and unique-local unreachable; IPv6 off again" : problems.joined(separator: "; "))
        }
        step("guest hands stub answers status") {
            let g = manager.guestCall(GuestHands.Request(verb: "status"))
            return (g.ok && g.data?["daemon"] == "stub", g.ok ? "daemon=\(g.data?["daemon"] ?? "?") macos=\(g.data?["macos"] ?? "?")" : (g.error?.suggestion ?? "no answer"))
        }
        if plantLinks {
            step("guest plants symlinks (to a host file and to a host folder) next to real files in its handoff folder") {
                guard let vm = manager.snapshot().vm else { return (false, "no VM") }
                let share = SandboxPin.guestHandoffPath
                let r = tart.guest(vm, "ln -s /etc/hosts '\(share)/evil-link' && mkdir '\(share)/sub' && ln -s /Users '\(share)/sub/dirlink' && echo ok > '\(share)/real.txt' && echo nested > '\(share)/sub/n.txt' && ls '\(share)' | wc -l", timeout: 30)
                return (r.ok, r.ok ? "planted" : GuestHands.sanitize(r.tail))
            }
        }
        step("down") {
            let name = manager.snapshot().vm
            let s = try manager.down()
            let present = (try? tart.localVMs()) ?? ["?"]
            let gone = name != nil && !present.contains(name!) && s.vm == nil
            var detail = gone ? "stopped, \(name ?? "?") deleted" : "\(name ?? "no VM") is still there"
            var ok = s.phase == .stopped && gone
            if plantLinks {
                // Nothing the guest planted was followed or carried over: only the real file came back.
                let folder = manager.paths.handoffRoot.appendingPathComponent("probe")
                let names = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                func isLink(_ rel: String) -> Bool { var st = stat(); return lstat(folder.appendingPathComponent(rel).path, &st) == 0 && st.st_mode & S_IFMT == S_IFLNK }
                func exists(_ rel: String) -> Bool { var st = stat(); return lstat(folder.appendingPathComponent(rel).path, &st) == 0 }
                let clean = names.contains("real.txt") && exists("sub/n.txt") && !exists("evil-link") && !exists("sub/dirlink")
                    && !isLink("evil-link") && !isLink("sub/dirlink") && names.contains("SANDBOX-SKIPPED.txt")
                ok = ok && clean
                detail += clean ? "; real.txt and sub/n.txt came back, the two symlinks did not" : "; handoff folder has: \(names.sorted())"
            }
            return (ok, detail)
        }
        return report
    }
}
