import AppKit
import BaneySpacesCore

/// Finds new builds on the channel the person chose (Stable or Nightly) and installs one only
/// when they press Update Now. Checking asks GitHub once a day, and can be turned off; it
/// sends nothing about this Mac. Installing runs the same installer as the first install: it
/// downloads the release's signed app (checked against the pinned release key) or, for a build
/// without one, builds on this Mac. Either way the Accessibility permission carries over and
/// Gatekeeper has nothing to ask.
final class Updater: NSObject {
    static let releasesURL = URL(string: "https://api.github.com/repos/baney75/baneyspaces/releases?per_page=30")!

    /// The build on offer, if one is newer than this one.
    private(set) var available: Release?
    /// The build being installed right now.
    private(set) var installing: Release?
    /// Called on the main thread whenever `available` or `installing` changes.
    var onChange: () -> Void = {}

    /// True while BaneySpaces is in the middle of something an alert mustn't interrupt (a
    /// workspace switch): alerts wait for it to end.
    var isBusy: () -> Bool = { false }

    private var timer: Timer?
    private var checking = false
    private var watch: Timer?
    /// Alerts on screen, kept alive until a button closes them.
    private var shown: [NSAlert] = []

    static let build: BuildInfo = {
        let info = Bundle.main.infoDictionary ?? [:]
        let commit = (info["BaneySpacesCommit"] as? String).flatMap { $0.allSatisfy(\.isHexDigit) && $0.count >= 7 ? $0 : nil }
        let date = (info["BaneySpacesCommitDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return BuildInfo(version: info["CFBundleShortVersionString"] as? String ?? "0", commit: commit, commitDate: date)
    }()

    /// "0.2.1" for a stable build, "0.2.1 (abc1234)" when the commit is known.
    static var buildDescription: String {
        build.commit.map { "\(build.version) (\($0.prefix(7)))" } ?? build.version
    }

    var channel: UpdateChannel {
        get { UserDefaults.standard.string(forKey: "updateChannel").flatMap(UpdateChannel.init) ?? .stable }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "updateChannel")
            available = nil
            onChange()
            check(manual: false)
        }
    }

    var checksAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "checkForUpdates") }
    }

    private var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastUpdateCheck") }
    }

    func start() {
        showWhatsNewIfJustUpdated()
        // A quiet check soon after launch, then once a day while BaneySpaces runs.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard checksAutomatically, installing == nil else { return }
        if let last = lastCheck, Date().timeIntervalSince(last) < 23 * 3600, available == nil { return }
        check(manual: false)
    }

    /// Asks GitHub for releases. A manual check always answers, even "you're up to date".
    func check(manual: Bool) {
        guard !checking else { return }
        checking = true
        var request = URLRequest(url: Self.releasesURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BaneySpaces/\(Self.build.version)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard let data, status == 200 else {
                    if manual { self.tell("Couldn't check for updates", error?.localizedDescription ?? "GitHub answered with status \(status). Try again later.") }
                    return
                }
                self.lastCheck = Date()
                let candidates = Updates.candidates(from: Release.list(fromGitHubJSON: data), channel: self.channel, build: Self.build)
                self.firstContainingBuild(candidates) { release in
                    self.available = release
                    self.onChange()
                    guard manual else { return }
                    if let release {
                        self.offer(release)
                    } else {
                        self.tell("BaneySpaces is up to date", "You have \(Self.buildDescription), the newest \(self.channel == .stable ? "stable release" : "build on the Nightly channel").")
                    }
                }
            }
        }.resume()
    }

    /// The first candidate GitHub confirms is ahead of this build: it contains every change this
    /// build has, plus more. Dates alone can't tell a hotfix branch from main. Without an answer
    /// (offline, rate limited), the date comparison stands.
    private func firstContainingBuild(_ candidates: [Release], then: @escaping (Release?) -> Void) {
        guard let release = candidates.first else { return then(nil) }
        guard let mine = Self.build.commit, let theirs = release.commit,
              let url = URL(string: "https://api.github.com/repos/baney75/baneyspaces/compare/\(mine)...\(theirs)") else { return then(release) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BaneySpaces/\(Self.build.version)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["status"] as? String
            DispatchQueue.main.async {
                guard (response as? HTTPURLResponse)?.statusCode == 200, let status else { return then(release) }
                if status == "ahead" { return then(release) }
                self.firstContainingBuild(Array(candidates.dropFirst()), then: then)
            }
        }.resume()
    }

    // MARK: Offering an update

    /// Shows what's new in `release` and installs it if the person agrees.
    func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = release.isNightly ? "A new nightly build is available" : "\(release.name) is available"
        alert.informativeText = "You have \(Self.buildDescription). Updating installs the new version in about a minute, then BaneySpaces restarts by itself. Your workspaces stay as they are."
        alert.accessoryView = Self.notesView(release.notes)
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")
        present(alert) { [weak self] button in if button == 0 { self?.install(release) } }
    }

    /// Shows an alert as an ordinary window, not a modal one: a modal alert stops the timers a
    /// workspace switch runs on. It waits for a switch in progress to end, so focus doesn't
    /// jump to BaneySpaces halfway through one.
    private func present(_ alert: NSAlert, then: @escaping (Int) -> Void = { _ in }) {
        guard !isBusy() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.present(alert, then: then) }
            return
        }
        shown.append(alert)
        for (i, button) in alert.buttons.enumerated() {
            let target = ButtonAction { [weak self, weak alert] in
                guard let alert else { return }
                alert.window.orderOut(nil)
                self?.shown.removeAll { $0 === alert }
                then(i)
            }
            button.target = target
            button.action = #selector(ButtonAction.run(_:))
            objc_setAssociatedObject(button, &ButtonAction.key, target, .OBJC_ASSOCIATION_RETAIN)
        }
        alert.layout()
        alert.window.level = .floating
        alert.window.center()
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)
    }

    /// Release notes in a scrolling view, Markdown rendered.
    private static func notesView(_ notes: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 280))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.autoresizingMask = .width
        text.textStorage?.setAttributedString(ReleaseNotes.render(notes.isEmpty ? "No notes for this release." : notes))
        scroll.documentView = text
        return scroll
    }

    // MARK: Installing

    private static var supportFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BaneySpaces")
    }
    private static var logURL: URL { supportFolder.appendingPathComponent("update.log") }

    private static var statusURL: URL { supportFolder.appendingPathComponent("update.status") }
    private static var pidURL: URL { supportFolder.appendingPathComponent("update.pid") }

    /// Whether an installer started earlier (by this launch or one before it) is still running.
    private static var installerRunning: Bool {
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    /// Runs the installer for `release` in the background. It downloads (or builds) first and only
    /// then quits and replaces this app, so a failed update leaves BaneySpaces running as it was. The
    /// exact commit whose notes were shown is installed, or nothing is.
    func install(_ release: Release) {
        guard installing == nil, release.isInstallable else { return }
        guard !Self.installerRunning else {
            return tell("An update is already installing", "It installs in the background and restarts BaneySpaces when it's done.")
        }
        let folder = Self.supportFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The tag and commit only ever reach the shell as environment variables, and only a tag
        // BaneySpaces publishes (vX.Y.Z or nightly) and a hex commit get this far. The script
        // writes its exit status last, whatever stopped it.
        let script = """
        set -uo pipefail
        echo $$ > "$BANEYSPACES_PID_FILE"
        TMP=$(mktemp -d)
        trap 'code=$?; rm -rf "$TMP"; [ $code = 0 ] || echo "BaneySpaces update failed ($code)"; echo $code > "$BANEYSPACES_STATUS_FILE"; rm -f "$BANEYSPACES_PID_FILE"' EXIT
        set -e
        echo "== $(date) updating to $BANEYSPACES_REF ${BANEYSPACES_COMMIT:-}"
        curl -fsSL "https://raw.githubusercontent.com/baney75/baneyspaces/${BANEYSPACES_COMMIT:-$BANEYSPACES_REF}/install.sh" -o "$TMP/install.sh"
        bash "$TMP/install.sh"
        """
        let scriptURL = folder.appendingPathComponent("update.sh")
        do { try script.write(to: scriptURL, atomically: true, encoding: .utf8) } catch {
            return tell("Couldn't start the update", error.localizedDescription)
        }
        try? FileManager.default.removeItem(at: Self.statusURL)
        try? Data().write(to: Self.logURL)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        // nohup and & let the installer outlive this app, which it quits and replaces.
        task.arguments = ["-c", "nohup /bin/bash \"$0\" >>\"$1\" 2>&1 &", scriptURL.path, Self.logURL.path]
        var env = ProcessInfo.processInfo.environment
        env["BANEYSPACES_REF"] = release.tag
        if let commit = release.commit { env["BANEYSPACES_COMMIT"] = commit }
        env["BANEYSPACES_STATUS_FILE"] = Self.statusURL.path
        env["BANEYSPACES_PID_FILE"] = Self.pidURL.path
        task.environment = env
        do { try task.run() } catch {
            return tell("Couldn't start the update", error.localizedDescription)
        }
        UserDefaults.standard.set(["tag": release.tag, "name": release.name, "notes": release.notes,
                                   "commit": release.commit ?? "", "from": Self.buildDescription], forKey: "updatingTo")
        installing = release
        onChange()
        watchForFailure()
    }

    /// The installer quits BaneySpaces when it succeeds. If BaneySpaces is still here when the
    /// installer has finished with a failure, say so instead of leaving "Updating…" in the menu.
    private func watchForFailure() {
        watch?.invalidate()
        watch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            guard let text = try? String(contentsOf: Self.statusURL, encoding: .utf8),
                  let code = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            timer.invalidate()
            self.installing = nil
            UserDefaults.standard.removeObject(forKey: "updatingTo")
            self.onChange()
            // Success means this app is about to be replaced; nothing to say.
            guard code != 0 else { return }
            let log = (try? String(contentsOf: Self.logURL, encoding: .utf8)) ?? ""
            let alert = NSAlert()
            alert.messageText = "The update didn't install"
            alert.informativeText = log.contains("moved to a newer build")
                ? "A newer build was published while you were reading the notes. Check for updates again to see it."
                : "BaneySpaces is still on \(Self.buildDescription) and works as before. The log says what went wrong."
            alert.addButton(withTitle: "Show Log")
            alert.addButton(withTitle: "OK")
            self.present(alert) { if $0 == 0 { NSWorkspace.shared.open(Self.logURL) } }
        }
        RunLoop.main.add(watch!, forMode: .common)
    }

    /// The first launch after an update says what changed.
    private func showWhatsNewIfJustUpdated() {
        guard let info = UserDefaults.standard.dictionary(forKey: "updatingTo") as? [String: String] else { return }
        UserDefaults.standard.removeObject(forKey: "updatingTo")
        let wanted = info["commit"] ?? ""
        let arrived = wanted.isEmpty ? info["from"] != Self.buildDescription
            : Self.build.commit.map { $0.hasPrefix(wanted) || wanted.hasPrefix($0) } == true
        guard arrived else { return }
        // After setup has had its chance to open: it comes first when permission needs fixing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            let alert = NSAlert()
            alert.messageText = "BaneySpaces is updated"
            alert.informativeText = "You're on \(Self.buildDescription) now (from \(info["from"] ?? "an older build")). Here's what changed."
            alert.accessoryView = Self.notesView(info["notes"] ?? "")
            alert.addButton(withTitle: "OK")
            present(alert)
        }
    }

    private func tell(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        present(alert)
    }
}

/// A button's action as a closure.
private final class ButtonAction: NSObject {
    static var key = 0
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run(_ sender: Any?) { action() }
}

/// Just enough Markdown for release notes: headings, bullets (with wrapped lines), paragraphs,
/// **bold** and `code`.
enum ReleaseNotes {
    static func render(_ markdown: String) -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: 13)
        let out = NSMutableAttributedString()
        // Wrapped lines (indented continuations) join the line above.
        var blocks: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("  "), let last = blocks.last, !last.isEmpty {
                blocks[blocks.count - 1] = last + " " + line.trimmingCharacters(in: .whitespaces)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty, blocks.last?.isEmpty == false {
                blocks.append("")
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                blocks.append(line)
            }
        }
        for block in blocks where !block.isEmpty {
            let para = NSMutableParagraphStyle()
            para.paragraphSpacing = 6
            var text = block, font = body
            if let range = block.range(of: #"^#{1,6} "#, options: .regularExpression) {
                text = String(block[range.upperBound...])
                font = .boldSystemFont(ofSize: 14)
                para.paragraphSpacingBefore = 6
            } else if block.hasPrefix("- ") || block.hasPrefix("* ") {
                text = "•\t" + block.dropFirst(2)
                para.headIndent = 16
                para.tabStops = [NSTextTab(textAlignment: .left, location: 16)]
            }
            let line = inline(text, font: font)
            line.append(NSAttributedString(string: "\n"))
            line.addAttributes([.paragraphStyle: para, .foregroundColor: NSColor.labelColor], range: NSRange(location: 0, length: line.length))
            out.append(line)
        }
        return out
    }

    private static func inline(_ text: String, font: NSFont) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let code = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
        var rest = Substring(text)
        while !rest.isEmpty {
            if rest.hasPrefix("**"), let end = rest.dropFirst(2).range(of: "**") {
                out.append(NSAttributedString(string: String(rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound]), attributes: [.font: bold]))
                rest = rest[end.upperBound...]
            } else if rest.hasPrefix("`"), let end = rest.dropFirst().firstIndex(of: "`") {
                out.append(NSAttributedString(string: String(rest[rest.index(after: rest.startIndex)..<end]), attributes: [.font: code]))
                rest = rest[rest.index(after: end)...]
            } else {
                let next = rest.dropFirst().firstIndex { $0 == "*" || $0 == "`" } ?? rest.endIndex
                out.append(NSAttributedString(string: String(rest[rest.startIndex..<next]), attributes: [.font: font]))
                rest = rest[next...]
            }
        }
        return out
    }
}
