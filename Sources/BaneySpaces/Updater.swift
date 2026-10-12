import AppKit
import BaneySpacesCore

/// Finds new builds on the channel the person chose (Stable or Nightly) and installs one only
/// when they press Update Now. Checking asks GitHub once a day, and can be turned off; it
/// sends nothing about this Mac. Installing runs the same installer as the first install,
/// building on this Mac, so the Accessibility permission carries over and no download has to
/// be trusted by Gatekeeper.
final class Updater: NSObject {
    static let releasesURL = URL(string: "https://api.github.com/repos/baney75/baneyspaces/releases?per_page=30")!

    /// The build on offer, if one is newer than this one.
    private(set) var available: Release?
    /// The build being installed right now.
    private(set) var installing: Release?
    /// Called on the main thread whenever `available` or `installing` changes.
    var onChange: () -> Void = {}

    private var timer: Timer?
    private var checking = false
    private var watch: Timer?

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
                self.available = Updates.offer(from: Release.list(fromGitHubJSON: data), channel: self.channel, build: Self.build)
                self.onChange()
                guard manual else { return }
                if let release = self.available {
                    self.offer(release)
                } else {
                    self.tell("BaneySpaces is up to date", "You have \(Self.buildDescription), the newest \(self.channel == .stable ? "stable release" : "build on the Nightly channel").")
                }
            }
        }.resume()
    }

    // MARK: Offering an update

    /// Shows what's new in `release` and installs it if the person agrees.
    func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = release.isNightly ? "A new nightly build is available" : "\(release.name) is available"
        alert.informativeText = "You have \(Self.buildDescription). Updating builds the new version on this Mac in about a minute, then BaneySpaces restarts by itself. Your workspaces stay as they are."
        alert.accessoryView = Self.notesView(release.notes)
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { install(release) }
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

    /// Runs the installer for `release` in the background. It builds first and only then quits
    /// and replaces this app, so a failed build leaves BaneySpaces running as it was.
    func install(_ release: Release) {
        guard installing == nil, release.isInstallable else { return }
        let folder = Self.supportFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The tag only ever reaches the shell as an environment variable, and only a tag
        // BaneySpaces publishes (vX.Y.Z or nightly) gets this far.
        let script = """
        set -euo pipefail
        echo "== $(date) updating to $BANEYSPACES_REF"
        TMP=$(mktemp -d)
        trap 'rm -rf "$TMP"' EXIT
        curl -fsSL "https://raw.githubusercontent.com/baney75/baneyspaces/$BANEYSPACES_REF/install.sh" -o "$TMP/install.sh"
        bash "$TMP/install.sh" || { echo "BaneySpaces update failed"; exit 1; }
        """
        let scriptURL = folder.appendingPathComponent("update.sh")
        do { try script.write(to: scriptURL, atomically: true, encoding: .utf8) } catch {
            return tell("Couldn't start the update", error.localizedDescription)
        }
        try? Data().write(to: Self.logURL)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        // nohup and & let the installer outlive this app, which it quits and replaces.
        task.arguments = ["-c", "nohup /bin/bash \"$0\" >>\"$1\" 2>&1 &", scriptURL.path, Self.logURL.path]
        var env = ProcessInfo.processInfo.environment
        env["BANEYSPACES_REF"] = release.tag
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

    /// The installer quits BaneySpaces when it succeeds. If BaneySpaces is still here and the
    /// log says it failed, say so instead of leaving "Updating…" in the menu forever.
    private func watchForFailure() {
        let started = Date()
        watch?.invalidate()
        watch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let log = (try? String(contentsOf: Self.logURL, encoding: .utf8)) ?? ""
            let failed = log.contains("update failed") || log.contains("install failed")
            guard failed || Date().timeIntervalSince(started) > 20 * 60 else { return }
            timer.invalidate()
            self.installing = nil
            UserDefaults.standard.removeObject(forKey: "updatingTo")
            self.onChange()
            let alert = NSAlert()
            alert.messageText = "The update didn't install"
            alert.informativeText = failed ? "BaneySpaces is still on \(Self.buildDescription) and works as before. The log says what went wrong."
                : "It has been running for 20 minutes without finishing. BaneySpaces is still on \(Self.buildDescription)."
            alert.addButton(withTitle: "Show Log")
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(Self.logURL) }
        }
    }

    /// The first launch after an update says what changed.
    private func showWhatsNewIfJustUpdated() {
        guard let info = UserDefaults.standard.dictionary(forKey: "updatingTo") as? [String: String] else { return }
        UserDefaults.standard.removeObject(forKey: "updatingTo")
        let wanted = info["commit"] ?? ""
        let arrived = wanted.isEmpty ? info["from"] != Self.buildDescription
            : Self.build.commit.map { $0.hasPrefix(wanted) || wanted.hasPrefix($0) } == true
        guard arrived else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let alert = NSAlert()
            alert.messageText = "BaneySpaces is updated"
            alert.informativeText = "You're on \(Self.buildDescription) now (from \(info["from"] ?? "an older build")). Here's what changed."
            alert.accessoryView = Self.notesView(info["notes"] ?? "")
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func tell(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
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
