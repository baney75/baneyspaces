import Foundation

/// `baneyspaces sandbox …` as the app answers it (and as the command answers it with `--local`).
/// Pure Foundation: the app gives it a window host, tests give it fakes.
public final class SandboxService {
    public let manager: SandboxManager
    public weak var windowHost: SandboxWindowHost?
    let tart: SandboxTart
    let settings: () -> SandboxSettings
    let tartHome: URL

    public init(manager: SandboxManager, tart: SandboxTart, settings: @escaping () -> SandboxSettings,
                windowHost: SandboxWindowHost? = nil, tartHome: URL = SandboxPaths.tartHome) {
        self.manager = manager; self.tart = tart; self.settings = settings; self.windowHost = windowHost; self.tartHome = tartHome
    }

    public static let usage = "usage: baneyspaces sandbox up [--task NAME] | down | reset | status | view [--off] | guest status | images delete"

    /// The request's `text` is the verb, `args` the rest. Long: `up` and `reset` can take a minute, so
    /// the app calls this off the main thread.
    public func handle(_ r: Wire.Request) -> Wire.Reply {
        let args = r.args ?? []
        do {
            switch r.text ?? "status" {
            case "up":
                let task = flag("--task", in: args)
                if let t = task, !SandboxHandoff.valid(t) { return fail("bad_task", "a task name is letters, digits, . - _ (up to 64): \(t)") }
                _ = try manager.up(task: task)
                return reply(extra: ["action": "up"])
            case "down":
                _ = try manager.down()
                return reply(extra: ["action": "down"])
            case "reset":
                let t = try manager.reset()
                return reply(extra: ["action": "reset", "reset": ["route": t.route.rawValue, "ms": t.ms,
                                                                   "within_budget": t.withinBudget, "from": t.from.rawValue, "budget_ms": Int(SandboxPin.resetBudget * 1000)]])
            case "status":
                return reply(guest: true)
            case "view":
                let off = args.contains("--off")
                let r = try manager.view(show: !off, host: windowHost)
                var extra: [String: Any] = ["action": off ? "view_off" : "view"]
                if let r { extra["window"] = ["workspace": r.workspace, "windows": r.windows] }
                return reply(extra: extra)
            case "guest":
                let verb = args.first ?? "status"
                let g = manager.guestCall(GuestHands.Request(verb: verb))
                var out: [String: Any] = ["ok": g.ok, "protocol": g.v, "source": GuestHands.source]
                if let d = g.data { out["data"] = d }
                if let e = g.error { out["error"] = ["code": e.code, "retry": e.retry, "suggestion": e.suggestion] }
                return reply(extra: ["guest": out])
            case "images":
                guard args.first == "delete" else { return fail("usage", SandboxService.usage) }
                try manager.deleteImages()
                return reply(extra: ["action": "images_deleted"])
            default:
                return fail("usage", SandboxService.usage)
            }
        } catch let e as SandboxError {
            return fail(e.code, e.message, deleted: e.vmDeleted, retry: e.retry)
        } catch {
            return fail("error", "\(error)")
        }
    }

    func fail(_ code: String, _ message: String, deleted: Bool = true, retry: String = "never") -> Wire.Reply {
        Wire.Reply(ok: false, error: "\(code): \(message)", info: ["json": Self.json(["ok": false, "code": code, "message": message, "vm_deleted": deleted, "retry": retry])])
    }

    func reply(extra: [String: Any] = [:], guest: Bool = false) -> Wire.Reply {
        var doc = status(guest: guest)
        for (k, v) in extra { doc[k] = v }
        doc["ok"] = true
        return Wire.Reply(ok: true, info: ["json": Self.json(doc)])
    }

    /// The sandbox as a JSON document: what `baneyspaces sandbox status` prints.
    public func status(guest: Bool = false) -> [String: Any] {
        let s = manager.snapshot()
        let cfg = settings()
        let disk = SandboxDisk.usage(tartHome: tartHome)
        var doc: [String: Any] = [
            "state": s.phase.rawValue,
            "vm": s.vm as Any? ?? NSNull(),
            "task": s.task as Any? ?? NSNull(),
            "display": s.graphics ? "window" : "headless",
            "uptime_s": s.uptime.map { Int($0) } as Any? ?? NSNull(),
            "warm": ["state": s.warm.rawValue, "location": s.warmLocation.rawValue] as [String: Any],
            "reset_stats": ["count": s.resetStats.count, "p50_ms": Int(s.resetStats.p50 * 1000), "p90_ms": Int(s.resetStats.p90 * 1000), "budget_ms": Int(SandboxPin.resetBudget * 1000), "p90_within_budget": s.resetStats.p90WithinBudget] as [String: Any],
            "network": ["selfcheck": s.selfcheck, "rules_hash": s.rulesHash as Any? ?? NSNull(), "problems": s.selfcheckProblems] as [String: Any],
            "image": ["ref": SandboxPin.image, "pulled": tart.imagePulled()] as [String: Any],
            "tart": ["version": SandboxPin.tartVersion, "softnet": SandboxPin.softnetVersion] as [String: Any],
            "disk": ["vm_gb": SandboxDisk.gb(disk.vmBytes), "image_gb": SandboxDisk.gb(disk.imageBytes), "vm_count": disk.vmCount] as [String: Any],
            "settings": ["enabled": cfg.enabled, "memory_gb": cfg.memoryGB, "cpus": cfg.cpus] as [String: Any],
            "handoff": ["guest_path": SandboxPin.guestHandoffPath, "host_path": (s.slot ?? s.task.map { manager.paths.handoffRoot.appendingPathComponent($0).path }) as Any? ?? NSNull(), "rests_at": s.task.map { manager.paths.handoffRoot.appendingPathComponent($0).path } as Any? ?? NSNull()] as [String: Any],
            "last_error": s.lastError as Any? ?? NSNull(),
            "pending_deletes": s.pendingDeletes,
        ]
        if let t = s.lastReset {
            doc["last_reset"] = ["route": t.route.rawValue, "ms": t.ms, "within_budget": t.withinBudget]
        }
        if let u = s.lastUp {
            doc["last_up"] = ["route": u.route, "boot_ms": Int(u.bootSeconds * 1000), "selfcheck_ms": Int(u.selfcheckSeconds * 1000)]
        }
        if guest, s.phase == .running {
            let g = manager.guestCall(GuestHands.Request(verb: "status"), counts: false) // a look, not use
            doc["guest"] = ["source": GuestHands.source, "data": g.ok ? (g.data ?? [:]) : ["error": g.error?.code ?? "unknown"]] as [String: Any]
        }
        return doc
    }

    static func json(_ doc: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(doc),
              let d = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys, .prettyPrinted]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    func flag(_ name: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

/// The real thing, wired up: Tart from Homebrew, the root-owned setuid Softnet, this Mac's facts.
public enum SandboxSystem {
    public static let tartPath = "/opt/homebrew/bin/tart"
    public static let softnetDir = "/usr/local/lib/baneyspaces/bin"

    public static func make(settings: @escaping () -> SandboxSettings, windowHost: SandboxWindowHost? = nil,
                            paths: SandboxPaths = SandboxPaths()) -> (SandboxService, SandboxTart) {
        let runner = SystemProcessRunner()
        let clock = SystemClock()
        let tart = SandboxTart(tart: tartPath, softnetDir: softnetDir, runner: runner, clock: clock, logDir: paths.logs.path)
        let manager = SandboxManager(tart: tart, facts: SystemHostFacts(runner: runner), clock: clock, paths: paths, settings: settings)
        return (SandboxService(manager: manager, tart: tart, settings: settings, windowHost: windowHost), tart)
    }
}
