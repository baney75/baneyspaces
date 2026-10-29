import AppKit
import BaneySpacesCore
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

/// One place to open, find, install, update and remove apps, find files, and run the Mac's
/// everyday commands. Type to search everything at once, or pick a menu (Apps, Files, Install,
/// Remove, Update, System, Workspaces) and search inside it. It can take ⌘Space from Spotlight.
enum Launcher {
    /// ⌘Space opens the launcher instead of Spotlight. Off unless chosen.
    static var onCmdSpace: Bool {
        get { UserDefaults.standard.bool(forKey: "launcherOnCmdSpace") }
        set { UserDefaults.standard.set(newValue, forKey: "launcherOnCmdSpace") }
    }

    /// The bang a plain web search uses: Google unless chosen.
    static var searchEngine: String {
        get { UserDefaults.standard.string(forKey: "launcherSearchEngine") ?? "g" }
        set { UserDefaults.standard.set(newValue, forKey: "launcherSearchEngine") }
    }

    /// The agent a "?" question goes to: Claude unless chosen.
    static var agent: String {
        get { UserDefaults.standard.string(forKey: "launcherAgent") ?? "claude" }
        set { UserDefaults.standard.set(newValue, forKey: "launcherAgent") }
    }

    /// Your own bangs, as JSON: [{"trigger": "jira", "name": "Jira", "url": "https://…/browse/{q}"}].
    static let customBangsURL = Spaces.folder.appendingPathComponent("bangs.json")

    /// The bangs you added, and anything wrong with the file. No file is no bangs, not a problem.
    static func readCustomBangs() -> (bangs: [Bang], problems: [String], readable: Bool) {
        guard let data = try? Data(contentsOf: customBangsURL) else {
            let exists = FileManager.default.fileExists(atPath: customBangsURL.path)
            return ([], exists ? ["bangs.json can't be read."] : [], !exists)
        }
        return Bangs.decodeCustom(data)
    }

    enum SaveError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self { case .unreadable(let why): "\(why) Fix or delete \(Launcher.customBangsURL.path) first, so nothing in it is lost." }
        }
    }

    /// Saves the list with `change` applied to what's on disk now. Refuses when the file can't be
    /// read as a list (writing would erase it), and throws if the write itself fails.
    @discardableResult
    static func updateCustomBangs(_ change: ([Bang]) -> [Bang]) throws -> [Bang] {
        let current = readCustomBangs()
        // Any entry it couldn't use would be dropped by saving, so it waits until the file is fixed.
        guard current.readable, current.problems.isEmpty else {
            throw SaveError.unreadable(current.problems.first.map { "bangs.json: \($0)" } ?? "bangs.json can't be read.")
        }
        let list = change(current.bangs)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: Spaces.folder, withIntermediateDirectories: true)
        try enc.encode(list).write(to: customBangsURL, options: .atomic)
        return list
    }

    static func loadBangs() -> [Bang] { Bangs.all(custom: readCustomBangs().bangs) }

    /// `BaneySpaces --bangs list | add <trigger> <name> <address with {q}> [--agent] | remove <trigger>`:
    /// for scripts and agents. The running app picks changes up the next time the launcher opens.
    static func commandLine(_ args: [String]) -> Int32 {
        func out(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
        func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
        let usage = """
        usage: BaneySpaces --bangs list
               BaneySpaces --bangs add <trigger> <name> <address with {q}> [--agent]
               BaneySpaces --bangs remove <trigger>
        Example: BaneySpaces --bangs add jira Jira 'https://acme.atlassian.net/browse/{q}'
        """
        switch args.first {
        case "list", nil:
            let read = readCustomBangs()
            read.problems.forEach { err("bangs.json: \($0)") }
            let mine = Set(read.bangs.map(\.trigger))
            for b in Bangs.all(custom: read.bangs) {
                out("!\(b.trigger)\t\(b.name)\t\(b.url)\(b.isAgent ? "\tagent" : "")\(mine.contains(b.trigger) ? "\tcustom" : "")")
            }
            return 0
        case "add":
            let rest = args.dropFirst().filter { $0 != "--agent" }
            guard rest.count == 3 else { err(usage); return 2 }
            let r = Array(rest)
            if let why = Bangs.problem(trigger: r[0], name: r[1], url: r[2]) { err(why); return 1 }
            let bang = Bang(trigger: r[0], name: r[1], url: r[2], agent: args.contains("--agent"))
            do {
                let list = try updateCustomBangs { Bangs.adding(bang, to: $0) ?? $0 }
                guard let added = list.last else { return 1 }
                out("Added !\(added.trigger) (\(added.name)).")
                return 0
            } catch {
                err(error.localizedDescription)
                return 1
            }
        case "remove":
            guard args.count == 2 else { err(usage); return 2 }
            let t = args[1].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "! "))
            guard readCustomBangs().bangs.contains(where: { $0.trigger == t }) else {
                err("No bang of yours is !\(t). Built-in bangs can be replaced by adding one with the same trigger.")
                return 1
            }
            do {
                try updateCustomBangs { $0.filter { $0.trigger != t } }
                out("Removed !\(t).")
                return 0
            } catch {
                err(error.localizedDescription)
                return 1
            }
        default:
            err(usage)
            return 2
        }
    }

    /// Opens the custom bangs file, writing an example first if there isn't one.
    static func editCustomBangs() {
        if !FileManager.default.fileExists(atPath: customBangsURL.path) {
            let example = """
            [
              {"trigger": "jw", "name": "JW Player docs", "url": "https://docs.jwplayer.com/search?q={q}"},
              {"trigger": "ask", "name": "Claude", "url": "https://claude.ai/new?q={q}", "agent": true}
            ]

            """
            try? FileManager.default.createDirectory(at: Spaces.folder, withIntermediateDirectories: true)
            try? example.write(to: customBangsURL, atomically: true, encoding: .utf8)
        }
        let edit = NSWorkspace.OpenConfiguration()
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([customBangsURL], withApplicationAt: textEdit, configuration: edit)
    }
}

/// What the launcher can do in the rest of BaneySpaces.
struct LauncherActions {
    var focusApp: (pid_t, Int?) -> Void = { _, _ in }
    /// A new window of a running app on the workspace you're on; false when it can't make one.
    var openWindowHere: (pid_t) -> Bool = { _ in false }
    /// Whether a running app has a New Window command.
    var canOpenWindow: (pid_t) -> Bool = { _ in false }
    var current: () -> Int = { 1 }
    var switchTo: (Int) -> Void = { _ in }
    var appsOn: (Int) -> [String] = { _ in [] }
    /// Workspaces each running app (by bundle path) has windows on.
    var workspacesByApp: () -> [String: [Int]] = { [:] }
    var showOverview: () -> Void = {}
    var bringBack: () -> Void = {}
    var toggleDock: () -> Void = {}
    var dockOn: () -> Bool = { false }
    var checkForUpdates: () -> Void = {}
    var showSetup: () -> Void = {}
    /// The Deck's rows (terminal splits, browser tabs, agents) that answer a query; with nothing
    /// typed, only the agents that finished or need you.
    var deckItems: (String) -> [LauncherItem] = { _ in [] }
}

final class LauncherController: NSObject, NSWindowDelegate {
    let model: LauncherModel
    private var panel: LauncherPanel?

    init(actions: LauncherActions) {
        model = LauncherModel(actions: actions)
        super.init()
        model.close = { [weak self] in self?.hide() }
    }

    var isShown: Bool { panel?.isVisible == true }

    func toggle() { isShown ? hide() : show() }

    /// `takeKeys: false` (opened by a link) shows it without taking the keyboard, so typing meant
    /// for another app never lands in it; a click on it takes the keyboard.
    func show(scope: LauncherModel.Scope = .root, takeKeys: Bool = true) {
        let p = panel ?? makePanel()
        panel = p
        model.prepare(scope: scope)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: 700, height: 500)
        // A little above center, where Spotlight sits.
        let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2,
                             y: screen.visibleFrame.minY + screen.visibleFrame.height * 0.62 - size.height / 2)
        p.setFrame(NSRect(origin: origin, size: size), display: false)
        // Drawn with the new list before it appears, never with the last one's.
        p.contentView?.layoutSubtreeIfNeeded()
        p.alphaValue = 1
        if takeKeys { p.makeKeyAndOrderFront(nil) } else { p.orderFrontRegardless(); watchClicksElsewhere() }
        p.displayIfNeeded()
        if let field = model.field { p.makeFirstResponder(field) }
    }

    func hide() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        guard let p = panel, p.isVisible else { return }
        p.orderOut(nil)
    }

    /// Without the keyboard, a launcher a link opened can't see Esc or lose focus; a click in any
    /// other app puts it away instead.
    private var clickMonitor: Any?
    private func watchClicksElsewhere() {
        if clickMonitor != nil { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.panel?.isKeyWindow != true else { return }
            self.hide()
        }
    }

    /// Clicking anywhere else puts it away, like Spotlight.
    func windowDidResignKey(_ notification: Notification) {
        if !model.alertOpen { hide() }
    }


    private func makePanel() -> LauncherPanel {
        let p = LauncherPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .modalPanel
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.delegate = self
        p.contentView = NSHostingView(rootView: LauncherView(model: model).environment(\.colorScheme, .dark))
        return p
    }
}

/// Takes the keyboard without bringing BaneySpaces forward, so the app you were in stays in front.
final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: Model

struct LauncherItem: Identifiable {
    enum Icon {
        case file(String)
        case symbol(String)
        case image(NSImage)
        case remote(URL?)
    }
    enum State: Equatable { case idle, working, failed }

    let id: String
    var section: String
    var title: String
    var subtitle: String = ""
    var icon: Icon
    /// Shown at the right: "Install", "Installed", "Failed".
    var badge: String = ""
    /// Workspaces shown at the right as colored numbers.
    var workspaces: [Int] = []
    var state = State.idle
    var run: () -> Void
    /// ⌘↩: show in Finder, or a cask's web page.
    var reveal: URL?
}

final class LauncherModel: ObservableObject {
    enum Scope: String, CaseIterable {
        case root, web, apps, files, install, remove, update, system, workspaces

        var title: String {
            switch self {
            case .root: "Search"
            case .web: "Search the Web"
            case .apps: "Apps"
            case .files: "Files"
            case .install: "Install"
            case .remove: "Remove"
            case .update: "Update"
            case .system: "System"
            case .workspaces: "Workspaces"
            }
        }
        var symbol: String {
            switch self {
            case .root: "magnifyingglass"
            case .web: "globe"
            case .apps: "square.grid.2x2"
            case .files: "doc.text.magnifyingglass"
            case .install: "arrow.down.circle"
            case .remove: "trash"
            case .update: "arrow.triangle.2.circlepath"
            case .system: "gearshape"
            case .workspaces: "rectangle.split.3x3"
            }
        }
        var blurb: String {
            switch self {
            case .root: ""
            case .web: "Bangs like !yt and !i, and AI agents like !claude"
            case .apps: "Every app on this Mac"
            case .files: "Any file or folder in your home folder and iCloud Drive, by name"
            case .install: "Thousands of apps from Homebrew and the App Store"
            case .remove: "Uninstall apps Homebrew installed"
            case .update: "Homebrew apps, macOS and BaneySpaces"
            case .system: "Lock, sleep, restart, dark mode and more"
            case .workspaces: "Go to any of the nine"
            }
        }
        var placeholder: String {
            switch self {
            case .root: "Search apps, files, the web (!yt), or ask (?)"
            case .files: "Search files and folders by name"
            case .web: "Search the web, or !bang, or ? to ask"
            case .install: "Search for an app to install"
            default: "Search \(title.lowercased())"
            }
        }
    }

    enum Job: Equatable { case installing, removing, failed(String) }

    @Published var query = "" { didSet { if query != oldValue { selected = 0; rebuild(); searchStore(); searchFiles() } } }
    @Published private(set) var scope = Scope.root
    @Published private(set) var items: [LauncherItem] = []
    @Published var selected = 0
    @Published private(set) var jobs: [String: Job] = [:]
    @Published private(set) var storeResults: [StoreApp] = []
    @Published private(set) var catalogState = CaskCatalog.State.idle
    weak var field: NSTextField?
    var close: () -> Void = {}
    var alertOpen = false

    private let actions: LauncherActions
    private var apps: [AppEntry] = []
    private var running: [String: [Int]] = [:]
    private var recents = Recents(UserDefaults.standard.stringArray(forKey: "launcherRecents") ?? [])
    private var iconCache: [String: NSImage] = [:]
    private let catalog = CaskCatalog()
    private var storeWork: DispatchWorkItem?
    /// Files Spotlight found for the query, best first. A newer search makes an older one stale.
    private var fileResults: [FileSearch.Hit] = []
    /// What `fileResults` were found for. Until a newer search answers, they're shown only while
    /// they still match what's typed.
    private var fileResultsQuery = ""
    private var fileWork: DispatchWorkItem?
    private var fileSearches = 0
    private var bangs = Launcher.loadBangs()
    /// Terminal agents found on this Mac: command to path.
    var agents: [String: String] = [:]

    init(actions: LauncherActions) {
        self.actions = actions
        apps = AppEntry.scan()
    }

    func prepare(scope: Scope) {
        self.scope = scope
        query = ""
        field?.stringValue = ""
        selected = 0
        running = actions.workspacesByApp()
        storeResults = []
        fileResults = []
        bangs = Launcher.loadBangs()
        rebuild()
        // Apps installed since the last look show up without a restart.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fresh = AppEntry.scan()
            DispatchQueue.main.async { self?.apps = fresh; self?.rebuild() }
        }
        Terminals.installedAgents { [weak self] found in
            guard let self, found != self.agents else { return }
            self.agents = found
            self.rebuild()
        }
        if scope == .install || scope == .remove { loadCatalog() }
    }

    func enter(_ s: Scope) {
        scope = s
        query = ""
        field?.stringValue = ""
        selected = 0
        storeResults = []
        fileResults = []
        if s == .install || s == .remove { loadCatalog() }
        rebuild()
    }

    func back() {
        guard scope != .root else { return }
        enter(.root)
    }

    func icon(for path: String) -> NSImage {
        if let i = iconCache[path] ?? fileIcons.object(forKey: path as NSString) { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        // Apps are a bounded list; files found by search aren't, so their icons can be let go.
        if path.hasSuffix(".app") { iconCache[path] = i } else { fileIcons.setObject(i, forKey: path as NSString) }
        return i
    }
    private let fileIcons: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 300
        return c
    }()

    // MARK: Keys

    func move(_ by: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + by + items.count) % items.count
    }

    func runSelected(reveal: Bool = false) {
        guard items.indices.contains(selected) else { return }
        let item = items[selected]
        if reveal, let url = item.reveal {
            close()
            if url.isFileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(url) }
            return
        }
        item.run()
    }

    func run(_ item: LauncherItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { selected = i }
        item.run()
    }

    /// Tab: into the selected menu, or complete "Install …" from the search.
    func tab() {
        guard items.indices.contains(selected) else { return }
        let id = items[selected].id
        if id.hasPrefix("scope:"), let s = Scope(rawValue: String(id.dropFirst("scope:".count))) { enter(s) }
        else if id == "find-install" || id.hasPrefix("bang-pick:") { items[selected].run() }
    }

    // MARK: Building the list

    private func rebuild() {
        let q = query
        var out: [LauncherItem] = []
        // A bang or a question takes over the list, wherever you are: it's clearly for the web.
        if scope == .root || scope == .web, let web = webItems(q) {
            items = web
            if selected >= items.count { selected = max(0, items.count - 1) }
            return
        }
        switch scope {
        case .web: out = q.isEmpty ? bangDirectory() : searchEverywhere(q)
        case .root:
            if q.isEmpty {
                out += actions.deckItems("")
                out += recentApps().prefix(5)
                out += menuItems()
            } else {
                out += appItems(q, limit: 8)
                out += actions.deckItems(q).prefix(8)
                out += agentItems(q)
                out += workspaceItems(q)
                out += commandItems(q)
                out += menuItems().filter { Fuzzy.score(q, $0.title) != nil }
                // Files come in a moment after the rest, below them, so the row you're on stays put.
                out += fileItems().prefix(5)
                out += searchEverywhere(q).prefix(3)
                out.append(LauncherItem(id: "find-install", section: "Install", title: "Install “\(q)”…",
                                        subtitle: "Search Homebrew and the App Store", icon: .symbol("arrow.down.circle"),
                                        badge: "⇥", run: { [weak self] in self?.enter(.install); self?.setQuery(q) }))
            }
        case .apps: out = appItems(q, limit: 500)
        case .files: out = fileItems()
        case .install: out = installItems(q)
        case .remove: out = removeItems(q)
        case .update: out = updateItems().filter { q.isEmpty || Fuzzy.score(q, $0.title) != nil }
        case .system: out = commandItems(q)
        case .workspaces: out = workspaceItems(q, all: true)
        }
        items = out
        if selected >= items.count { selected = max(0, items.count - 1) }
    }

    /// Rebuilds for results that came in after the typing (files, the App Store): the row you
    /// were on stays selected wherever it moved, so Return still does what it showed.
    private func rebuildKeepingSelection() {
        let on = items.indices.contains(selected) ? items[selected].id : nil
        rebuild()
        // A row that went away leaves the top selected, never whatever moved into its place.
        selected = on.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
    }

    // MARK: Web and agents

    /// "!yt cats", "cats !yt", "!y" while typing a bang, or "? a question". Nil for anything else.
    private func webItems(_ q: String) -> [LauncherItem]? {
        let t = q.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("?") {
            let question = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
            let mine = Bangs.find(Launcher.agent, in: bangs) ?? Bangs.agents[0]
            return [bangItem(mine, question, section: "Ask")]
                + bangs.filter { $0.isAgent && $0.trigger != mine.trigger }.map { bangItem($0, question, section: "Other agents") }
        }
        // Still typing the bang: "!" or "!yo" with nothing after it yet.
        if t.hasPrefix("!"), !t.contains(" ") {
            let partial = String(t.dropFirst())
            if let exact = Bangs.find(partial, in: bangs), !partial.isEmpty {
                return [bangItem(exact, "", section: "Bang")] + Bangs.suggest(partial, in: bangs).filter { $0 != exact }.map(bangPick)
            }
            let picks = Bangs.suggest(partial, in: bangs).map(bangPick)
            return picks.isEmpty && !partial.isEmpty ? [unknownBang(partial, "")] : picks
        }
        guard let parsed = Bangs.parse(t) else { return nil }
        guard let bang = Bangs.find(parsed.trigger, in: bangs) else { return [unknownBang(parsed.trigger, parsed.terms)] }
        return [bangItem(bang, parsed.terms, section: "Bang")]
    }

    /// One row that searches (or asks) with a bang.
    private func bangItem(_ b: Bang, _ terms: String, section: String) -> LauncherItem {
        let title: String
        if terms.isEmpty { title = "Open \(b.name)" } else if b.isAgent { title = "Ask \(b.name) “\(terms)”" } else { title = "Search \(b.name) for “\(terms)”" }
        let subtitle = b.isAgent ? "!\(b.trigger) · opens a new chat in your browser with the question asked" : "!\(b.trigger) · opens in your browser"
        return LauncherItem(id: "bang:\(b.trigger):\(section)", section: section, title: title, subtitle: subtitle, icon: .symbol(Self.symbol(for: b)),
                            run: { [weak self] in self?.openWeb(b.address(for: terms)) })
    }

    /// A bang offered while typing "!": Tab or Return fills it in, ready for the words.
    private func bangPick(_ b: Bang) -> LauncherItem {
        LauncherItem(id: "bang-pick:\(b.trigger)", section: "Bangs", title: b.name, subtitle: "!\(b.trigger)",
                     icon: .symbol(Self.symbol(for: b)), badge: "⇥", run: { [weak self] in self?.setQuery("!\(b.trigger) ") })
    }

    private func unknownBang(_ trigger: String, _ terms: String) -> LauncherItem {
        LauncherItem(id: "bang-ddg:\(trigger)", section: "Bang", title: "Search with !\(trigger)\(terms.isEmpty ? "" : " for “\(terms)”")",
                     subtitle: "Not a built-in bang; DuckDuckGo knows thousands more", icon: .symbol("globe"),
                     run: { [weak self] in self?.openWeb(Bangs.fallbackAddress(trigger: trigger, terms: terms)) })
    }

    /// Plain words: your search engine, images, and your agent first, then every other bang.
    private func searchEverywhere(_ q: String) -> [LauncherItem] {
        let engine = Bangs.find(Launcher.searchEngine, in: bangs) ?? Bangs.builtIn.first { $0.trigger == "g" }!
        let agent = Bangs.find(Launcher.agent, in: bangs) ?? Bangs.agents[0]
        let images = Bangs.find("i", in: bangs)
        var seen = Set<String>()
        let lead = [engine, images, agent].compactMap { $0 }.filter { seen.insert($0.trigger).inserted }
        let builtInImages = Bangs.builtIn.first { $0.trigger == "i" }
        let leadItems = lead.map { b -> LauncherItem in
            var item = bangItem(b, q, section: "Web")
            if b == builtInImages { item.title = "Search images for “\(q)”" }
            return item
        }
        guard scope == .web else { return leadItems }
        let skip = Set(lead.map(\.trigger) + ["img", "gi"])
        return leadItems + bangs.filter { !skip.contains($0.trigger) }.map { bangItem($0, q, section: $0.isAgent ? "Agents" : "Sites") }
    }

    /// The Search the Web menu with nothing typed: every agent and site, each a bang to fill in.
    private func bangDirectory() -> [LauncherItem] {
        bangs.filter(\.isAgent).map { var i = bangPick($0); i.section = "Agents"; return i }
            + bangs.filter { !$0.isAgent }.map { var i = bangPick($0); i.section = "Sites"; return i }
            + [LauncherItem(id: "bang-edit", section: "Your bangs", title: "Add Your Own Bangs…",
                            subtitle: "Opens bangs.json; each needs a trigger, a name and an address with {q}", icon: .symbol("plus"),
                            run: { [weak self] in self?.close(); Launcher.editCustomBangs() })]
    }

    private static func symbol(for b: Bang) -> String {
        if b.isAgent { return "sparkles" }
        switch b.trigger {
        case "i", "img", "gi", "ddgi": return "photo"
        case "v", "yt": return "play.rectangle"
        case "maps", "am": return "map"
        case "gh", "so", "mdn", "npm", "pypi", "apple", "hf", "brew": return "chevron.left.forwardslash.chevron.right"
        case "bible", "esv": return "book.closed"
        case "a", "ebay": return "cart"
        case "w", "d", "scholar", "wa": return "text.book.closed"
        default: return "globe"
        }
    }

    /// In a new tab of your default browser (or Maps for an Apple Maps bang).
    private func openWeb(_ url: URL?) {
        close()
        guard let url else { return NSSound.beep() }
        NSWorkspace.shared.open(url)
    }

    private func setQuery(_ q: String) {
        field?.stringValue = q
        query = q
    }

    private func menuItems() -> [LauncherItem] {
        Scope.allCases.filter { $0 != .root }.map { s in
            LauncherItem(id: "scope:\(s.rawValue)", section: "Menu", title: s.title, subtitle: s.blurb, icon: .symbol(s.symbol),
                         badge: "⇥", run: { [weak self] in self?.enter(s) })
        }
    }

    private func recentApps() -> [LauncherItem] {
        recents.paths.compactMap { path in apps.first { $0.path == path } }.map { appItem($0, section: "Recent") }
    }

    private func appItems(_ q: String, limit: Int) -> [LauncherItem] {
        let matches: [AppEntry]
        if q.isEmpty {
            matches = apps
        } else {
            matches = apps.compactMap { a -> (AppEntry, Int)? in
                guard let s = Fuzzy.score(q, a.name) else { return nil }
                return (a, s + recents.boost(a.path) + (running[a.path] != nil ? 15 : 0))
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }
            .map(\.0)
        }
        // An app open on more than one workspace also gets a row for each, to pick which, and so
        // does one that opens a new window here instead of going to its workspace.
        return matches.prefix(limit).flatMap { a -> [LauncherItem] in
            let on = running[a.path] ?? []
            let look = !q.isEmpty && limit <= 8
            let main = appItem(a, section: "Apps", look: look)
            guard on.count > 1 || opensHere(a, look: look), !q.isEmpty else { return [main] }
            return [main] + on.map { n in
                LauncherItem(id: "app:\(a.path):\(n)", section: "Apps", title: "\(a.name) on Workspace \(n)",
                             subtitle: "The \(a.name) windows there", icon: .file(a.path), workspaces: [n],
                             run: { [weak self] in self?.focus(a, on: n) }, reveal: URL(fileURLWithPath: a.path))
            }
        }
    }

    /// "claude" or "codex": that agent, started in your terminal.
    private func agentItems(_ q: String) -> [LauncherItem] {
        let matches = TerminalAgent.matches(q, installed: agents.keys)
        guard !matches.isEmpty, let terminal = Terminals.app() else { return [] }
        let name = FileManager.default.displayName(atPath: terminal.path).replacingOccurrences(of: ".app", with: "")
        return matches.map { a in
            LauncherItem(id: "agent:\(a.command)", section: "Terminal", title: a.name, subtitle: "Opens in \(name) · runs \(a.command)",
                         icon: .file(terminal.path), run: { [weak self] in
                             self?.close()
                             if let path = self?.agents[a.command] { Terminals.open(a, at: path, in: terminal) }
                         })
        }
    }

    private func focus(_ a: AppEntry, on n: Int) {
        close()
        guard let app = runningApp(a) else { return open(a) }
        actions.focusApp(app.processIdentifier, n)
    }

    private func appItem(_ a: AppEntry, section: String, look: Bool = false) -> LauncherItem {
        let on = running[a.path] ?? []
        var where_ = on.isEmpty ? a.folder : on.count == 1 ? "Open on workspace \(on[0])" : "Open on workspaces \(on.map(String.init).joined(separator: ", "))"
        if opensHere(a, look: look) { where_ += " · Return opens a new window here" }
        return LauncherItem(id: "app:\(a.path)", section: section, title: a.name, subtitle: where_, icon: .file(a.path),
                            workspaces: on,
                            run: { [weak self] in self?.open(a) }, reveal: URL(fileURLWithPath: a.path))
    }

    /// Apps found to have a New Window command, by path. Only a yes is kept: a no can be an app
    /// that was busy, still building its menus, or showing a sheet.
    private var newWindowCommand: Set<String> = []

    /// An app open only on other workspaces that can open a window here: opening it does that,
    /// as opening an app on a Mac desktop where it has no window would. `look` reads the app's
    /// menus, 15–130 ms an app, so rows only look for the few best matches of a search.
    private func opensHere(_ a: AppEntry, look: Bool = true) -> Bool {
        guard let on = running[a.path], !on.contains(actions.current()), let app = runningApp(a) else { return false }
        if newWindowCommand.contains(a.path) { return true }
        guard look, actions.canOpenWindow(app.processIdentifier) else { return false }
        newWindowCommand.insert(a.path)
        return true
    }

    private func runningApp(_ a: AppEntry) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == a.path }
    }

    /// A running app opens a new window here when it's open only elsewhere and can; otherwise
    /// it's gone to, wherever its windows are. Anything else opens here.
    private func open(_ a: AppEntry) {
        close()
        recents.used(a.path)
        UserDefaults.standard.set(recents.paths, forKey: "launcherRecents")
        let url = URL(fileURLWithPath: a.path)
        if let app = runningApp(a), running[a.path] != nil {
            if opensHere(a), actions.openWindowHere(app.processIdentifier) { return }
            actions.focusApp(app.processIdentifier, nil)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { NSLog("BaneySpaces: couldn't open %@: %@", a.path, error.localizedDescription) }
        }
    }

    private func workspaceItems(_ q: String, all: Bool = false) -> [LauncherItem] {
        Workspaces.range.compactMap { n in
            let apps = actions.appsOn(n)
            let title = "Workspace \(n)"
            let text = "\(title) \(apps.joined(separator: " "))"
            if !q.isEmpty {
                // "3" or "ws 3" goes straight there; names find the workspace an app is on.
                let digitMatch = q.trimmingCharacters(in: .whitespaces) == String(n)
                if !digitMatch && Fuzzy.score(q, title) == nil && !apps.contains(where: { Fuzzy.score(q, $0).map { $0 >= 500 } ?? false }) { return nil }
            } else if !all { return nil }
            _ = text
            return LauncherItem(id: "ws:\(n)", section: "Workspaces", title: title,
                                subtitle: apps.isEmpty ? "Empty" : apps.joined(separator: ", "), icon: .symbol("\(n).square"),
                                run: { [weak self] in self?.close(); self?.actions.switchTo(n) })
        }
    }

    private func commandItems(_ q: String) -> [LauncherItem] {
        let dockOn = actions.dockOn()
        let all: [(String, String, String, () -> Void)] = [
            ("Lock Screen", "lock", "", { System.lock() }),
            ("Sleep", "moon.zzz", "", { System.run("/usr/bin/pmset", ["sleepnow"]) }),
            ("Restart…", "restart", "macOS asks before restarting", { System.loginWindow("rrst") }),
            ("Shut Down…", "power", "macOS asks before shutting down", { System.loginWindow("rsdn") }),
            ("Log Out…", "rectangle.portrait.and.arrow.right", "macOS asks before logging out", { System.loginWindow("rlgo") }),
            ("Toggle Dark Mode", "circle.lefthalf.filled", "Asks once to let BaneySpaces change appearance", { System.toggleDarkMode() }),
            ("Take a Screenshot", "camera.viewfinder", "Choose an area, a window or the screen", { System.run("/usr/bin/open", ["-a", "Screenshot"]) }),
            ("Show All Workspaces", "square.grid.3x3", "", { [weak self] in self?.actions.showOverview() }),
            ("Bring Every Window Back", "arrow.uturn.backward.circle", "Gathers every window onto workspace 1", { [weak self] in self?.actions.bringBack() }),
            (dockOn ? "Turn Off Workspace Dock" : "Turn On Workspace Dock", "dock.rectangle", "", { [weak self] in self?.actions.toggleDock() }),
            ("BaneySpaces Settings", "slider.horizontal.3", "", { [weak self] in self?.actions.showSetup() }),
        ]
        return all.filter { q.isEmpty || Fuzzy.score(q, $0.0) != nil }.map { c in
            LauncherItem(id: "cmd:\(c.0)", section: "System", title: c.0, subtitle: c.2, icon: .symbol(c.1),
                         run: { [weak self] in self?.close(); DispatchQueue.main.async(execute: c.3) })
        }
    }

    private func updateItems() -> [LauncherItem] {
        var out: [LauncherItem] = []
        if Brew.path != nil {
            out.append(LauncherItem(id: "upd:brew", section: "Update", title: "Update Homebrew Apps",
                                    subtitle: "Runs brew update and brew upgrade in Terminal, where you can watch it",
                                    icon: .symbol("shippingbox"),
                                    run: { [weak self] in self?.close(); Brew.openInTerminal(["brew", "update"], ["brew", "upgrade"]) }))
        }
        out.append(LauncherItem(id: "upd:macos", section: "Update", title: "Update macOS and App Store Apps",
                                subtitle: "Opens Software Update", icon: .symbol("apple.logo"),
                                run: { [weak self] in
                                    self?.close()
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)
                                }))
        out.append(LauncherItem(id: "upd:self", section: "Update", title: "Check for BaneySpaces Updates",
                                subtitle: "Stable or Nightly, as set in the menu bar", icon: .symbol("square.grid.3x3.fill"),
                                run: { [weak self] in self?.close(); self?.actions.checkForUpdates() }))
        return out
    }

    // MARK: Install and remove

    /// Picks for an empty Install search: well-known apps most Macs want.
    private static let popular = ["google-chrome", "firefox", "visual-studio-code", "ghostty", "obsidian", "slack", "discord",
                                  "spotify", "zoom", "vlc", "1password", "rectangle", "iina", "appcleaner", "the-unarchiver"]

    private func loadCatalog() {
        catalog.load { [weak self] state in
            self?.catalogState = state
            self?.rebuild()
        }
    }

    private func installItems(_ q: String) -> [LauncherItem] {
        var out: [LauncherItem] = []
        if Brew.path == nil {
            out.append(LauncherItem(id: "brew:get", section: "Homebrew", title: "Get Homebrew First",
                                    subtitle: "The free installer most Mac developers use. Opens Terminal; it asks for your password.",
                                    icon: .symbol("shippingbox"),
                                    run: { [weak self] in self?.close(); Brew.installHomebrew() }))
        }
        let installed = Brew.installedCasks()
        let casks = q.isEmpty
            ? Self.popular.compactMap { t in catalog.casks.first { $0.token == t } }
            : Cask.search(q, in: catalog.casks, limit: 25)
        if catalog.casks.isEmpty {
            switch catalogState {
            case .loading: out.append(LauncherItem(id: "brew:loading", section: "Homebrew", title: "Loading Homebrew’s app list…",
                                                   icon: .symbol("hourglass"), state: .working, run: {}))
            case .failed(let why): out.append(LauncherItem(id: "brew:failed", section: "Homebrew", title: "Couldn’t load Homebrew’s app list",
                                                           subtitle: why + ". Press ↩ to try again.", icon: .symbol("wifi.exclamationmark"),
                                                           run: { [weak self] in self?.catalog.reset(); self?.loadCatalog() }))
            default: break
            }
        }
        for c in casks { out.append(caskItem(c, installed: installed.contains(c.token), section: q.isEmpty ? "Popular" : "Homebrew")) }
        for app in storeResults {
            let local = app.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            out.append(LauncherItem(id: "store:\(app.id)", section: "App Store", title: app.name,
                                    subtitle: [app.seller, app.price].filter { !$0.isEmpty }.joined(separator: " · "),
                                    icon: .remote(app.artwork), badge: local != nil ? "Installed" : "App Store",
                                    run: { [weak self] in
                                        self?.close()
                                        if let local { NSWorkspace.shared.open(local) } else if let url = app.storeURL { NSWorkspace.shared.open(url) }
                                    }, reveal: app.webURL))
        }
        return out
    }

    private func caskItem(_ c: Cask, installed: Bool, section: String) -> LauncherItem {
        let job = jobs[c.token]
        var item = LauncherItem(id: "cask:\(c.token)", section: section, title: c.name,
                                subtitle: c.desc.isEmpty ? c.token : c.desc, icon: .symbol("shippingbox"),
                                badge: installed ? "Installed" : "Install", run: {},
                                reveal: URL(string: c.homepage))
        if let local = Brew.appPath(for: c, installedApps: apps) { item.icon = .file(local) }
        switch job {
        case .installing: item.badge = "Installing…"; item.state = .working
        case .removing: item.badge = "Removing…"; item.state = .working
        case .failed(let why):
            item.state = .failed
            item.subtitle = why + " Press ↩ to finish in Terminal."
            item.badge = "Failed"
            item.run = { [weak self] in self?.close(); Brew.openInTerminal(["brew", "install", "--cask", c.token]) }
            return item
        case nil: break
        }
        if job == nil {
            item.run = installed
                ? { [weak self] in
                    guard let self else { return }
                    if let path = Brew.appPath(for: c, installedApps: self.apps), let a = self.apps.first(where: { $0.path == path }) { self.open(a) }
                }
                : { [weak self] in self?.confirmInstall(c) }
        }
        return item
    }

    /// Installing changes the Mac, so it is always asked, the same as removing.
    private func confirmInstall(_ c: Cask) {
        guard Brew.path != nil else { close(); return Brew.installHomebrew() }
        guard ask("Install \(c.name)?", c.desc.isEmpty ? "Homebrew downloads and installs it from \(c.homepage.isEmpty ? "its maker" : c.homepage)."
                  : "\(c.desc). Homebrew downloads it from \(c.homepage.isEmpty ? "its maker" : c.homepage).", button: "Install") else { return }
        install(c)
    }

    /// A yes-or-no question over the launcher. The app you were in comes back afterwards.
    private func ask(_ title: String, _ detail: String, button: String, destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = destructive
        let previous = NSWorkspace.shared.frontmostApplication
        alertOpen = true
        NSApp.activate(ignoringOtherApps: true)
        let answer = alert.runModal()
        alertOpen = false
        if let previous, previous.processIdentifier != getpid() { previous.activate(options: []) }
        field?.window?.makeKey()
        return answer == .alertFirstButtonReturn
    }

    private func install(_ c: Cask) {
        guard Brew.path != nil else { return Brew.installHomebrew() }
        jobs[c.token] = .installing
        rebuild()
        Brew.run(["install", "--cask", c.token]) { [weak self] ok, tail in
            guard let self else { return }
            if ok {
                self.jobs[c.token] = nil
                self.apps = AppEntry.scan()
                Toast.show("\(c.name) is installed", symbol: "checkmark.circle.fill")
            } else {
                self.jobs[c.token] = .failed(tail.isEmpty ? "Homebrew stopped." : "Homebrew: \(tail).")
                Toast.show("\(c.name) didn’t install. Open the launcher to finish in Terminal.", symbol: "exclamationmark.triangle.fill")
            }
            self.rebuild()
        }
    }

    private func removeItems(_ q: String) -> [LauncherItem] {
        guard Brew.path != nil else {
            return [LauncherItem(id: "rm:none", section: "Remove", title: "Homebrew isn’t installed",
                                 subtitle: "Apps from elsewhere are removed by dragging them from Applications to the Trash.",
                                 icon: .symbol("shippingbox"), run: {})]
        }
        let installed = Brew.installedCasks().sorted()
        let list = installed.map { t in catalog.casks.first { $0.token == t } ?? Cask(token: t, name: t, desc: "", homepage: "") }
            .filter { q.isEmpty || Fuzzy.score(q, $0.name) != nil || Fuzzy.score(q, $0.token) != nil }
        if list.isEmpty {
            return [LauncherItem(id: "rm:empty", section: "Remove", title: q.isEmpty ? "Homebrew hasn’t installed any apps" : "No Homebrew app matches",
                                 icon: .symbol("tray"), run: {})]
        }
        return list.map { c in
            var item = LauncherItem(id: "rm:\(c.token)", section: "Installed with Homebrew", title: c.name,
                                    subtitle: c.desc.isEmpty ? c.token : c.desc, icon: .symbol("shippingbox"), badge: "Remove",
                                    run: { [weak self] in self?.remove(c) }, reveal: URL(string: c.homepage))
            if let local = Brew.appPath(for: c, installedApps: apps) { item.icon = .file(local) }
            if jobs[c.token] == .removing { item.badge = "Removing…"; item.state = .working; item.run = {} }
            return item
        }
    }

    private func remove(_ c: Cask) {
        guard ask("Remove \(c.name)?", "Homebrew uninstalls the app. Its documents and settings stay.",
                  button: "Remove", destructive: true) else { return }
        jobs[c.token] = .removing
        rebuild()
        Brew.run(["uninstall", "--cask", c.token]) { [weak self] ok, tail in
            guard let self else { return }
            self.jobs[c.token] = nil
            self.apps = AppEntry.scan()
            Toast.show(ok ? "\(c.name) is removed" : "\(c.name) wasn’t removed: \(tail)",
                       symbol: ok ? "trash.fill" : "exclamationmark.triangle.fill")
            self.rebuild()
        }
    }

    /// App Store results arrive a moment after typing stops, and only in the Install menu.
    private func searchStore() {
        storeWork?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard scope == .install, q.count >= 2 else {
            if !storeResults.isEmpty { storeResults = []; rebuild() }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            StoreApp.search(q) { results in
                guard let self, self.query.trimmingCharacters(in: .whitespaces) == q, self.scope == .install else { return }
                self.storeResults = results
                self.rebuildKeepingSelection()
            }
        }
        storeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: Files

    /// Spotlight, a moment after typing stops: the top five in the main search, more in Files.
    /// A bang or a question is for the web, not a file name.
    private func searchFiles() {
        fileWork?.cancel()
        fileSearches += 1
        let q = query.trimmingCharacters(in: .whitespaces)
        let forFiles = scope == .files || scope == .root && !q.hasPrefix("!") && !q.hasPrefix("?") && Bangs.parse(q) == nil
        guard forFiles, FileSearch.spotlightQuery(q) != nil else {
            if !fileResults.isEmpty { fileResults = []; rebuild() }
            return
        }
        let search = fileSearches, inScope = scope
        let work = DispatchWorkItem {
            FileFinder.find(q, limit: inScope == .files ? 60 : 5, search: search) { [weak self] hits in
                guard let self, self.fileSearches == search, self.scope == inScope else { return }
                self.fileResults = hits
                self.fileResultsQuery = q
                self.rebuildKeepingSelection()
            }
        }
        fileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func fileItems() -> [LauncherItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // An older search's files stay up while the newer one runs, only those that still match.
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = q == fileResultsQuery ? fileResults : fileResults.filter { FileSearch.matches(q, $0.name) }
        return shown.map { f in
            let url = URL(fileURLWithPath: f.path)
            return LauncherItem(id: "file:\(f.path)", section: "Files", title: f.name,
                                subtitle: FileSearch.folder(of: f.path, home: home) + " · ⌘↩ shows it in Finder",
                                icon: .file(f.path), run: { [weak self] in
                                    self?.close()
                                    if !NSWorkspace.shared.open(url) { NSSound.beep() }
                                }, reveal: url)
        }
    }
}

/// Runs `FileSearch`'s query through Spotlight over your own folders (iCloud Drive and cloud
/// drives included, the rest of Library left out), off the main thread, and ranks what it finds.
enum FileFinder {
    private static let queue = DispatchQueue(label: "BaneySpaces file search", qos: .userInitiated)
    /// Files kept per search for ranking. A two-letter search can match thousands; the ranking
    /// only needs enough to find the few worth showing.
    static let cap = 1000
    /// Matches Spotlight gathers per search, most recently used first. Noise is skipped as it's
    /// read, since Spotlight can't leave it out (it ignores kMDItemPath) and it can be most of
    /// the matches: 4,887 of 5,159 for "ind" in ~/Projects on Donovan's Mac were in node_modules.
    /// Measured there: 6,000 takes 80–580 ms a search; 20,000 took up to 1.9 s.
    static let scanLimit = 6_000
    /// Reading each match's path costs about 0.3 ms, so reading stops after this long with what
    /// it has kept.
    static let readBudget: TimeInterval = 0.3
    /// The newest search asked for. One queued behind it is stale and doesn't run.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var newest = 0
    private static func isNewest(_ n: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return newest == n }

    static func find(_ typed: String, limit: Int, search n: Int, done: @escaping ([FileSearch.Hit]) -> Void) {
        guard let text = FileSearch.spotlightQuery(typed) else { return done([]) }
        lock.lock(); newest = n; lock.unlock()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        queue.async {
            guard isNewest(n) else { return }
            let start = Date()
            let places = scopes(home)
            let hits = search(text, in: places, stale: { !isNewest(n) }) + topLevel(typed, home)
            guard isNewest(n) else { return }
            let ranked = FileSearch.rank(typed, hits, home: home, limit: limit)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            DispatchQueue.main.async {
                // One line a search, so an empty list can be told apart from a slow or blocked one.
                Trace.log("files q=\(typed.count)ch places=\(places.count) kept=\(hits.count) shown=\(ranked.count) ms=\(ms)")
                done(ranked)
            }
        }
    }

    /// The home folder's own folders, without Library or hidden ones, plus iCloud Drive and the
    /// cloud drives: noise never takes a place under the cap.
    private static func scopes(_ home: String) -> [String] {
        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(atPath: home)) ?? []
        let own = top.filter { name in
            var dir: ObjCBool = false
            return !name.hasPrefix(".") && name != "Library"
                && fm.fileExists(atPath: home + "/" + name, isDirectory: &dir) && dir.boolValue
        }.map { home + "/" + $0 }
        return own + FileSearch.cloudFolders.sorted().map { home + "/Library/" + $0 }.filter { fm.fileExists(atPath: $0) }
    }

    /// Files and folders right in the home folder, which no scope above covers.
    private static func topLevel(_ typed: String, _ home: String) -> [FileSearch.Hit] {
        let top = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        return top.filter { !$0.hasPrefix(".") && $0 != "Library" && FileSearch.matches(typed, $0) }.map { name in
            let path = home + "/" + name
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            return FileSearch.Hit(name: name, path: path, modified: attrs?[.modificationDate] as? Date)
        }
    }

    /// Spotlight hands these back with the results; asking item by item took seconds. The path
    /// isn't one it can (it isn't stored), so that one is asked of each item.
    private static let attributes = [kMDItemFSName, kMDItemLastUsedDate, kMDItemFSContentChangeDate] as [CFString]

    private static func search(_ text: String, in scopes: [String], stale: () -> Bool) -> [FileSearch.Hit] {
        guard !scopes.isEmpty,
              let q = MDQueryCreate(kCFAllocatorDefault, text as CFString, attributes as CFArray, [kMDItemLastUsedDate] as CFArray)
        else { return [] }
        MDQuerySetSearchScope(q, scopes as CFArray, 0)
        MDQuerySetMaxCount(q, scanLimit)
        guard MDQueryExecute(q, CFOptionFlags(kMDQuerySynchronous.rawValue)), !stale() else { return [] }
        func value<T>(_ attr: CFString, _ i: Int) -> T? {
            MDQueryGetAttributeValueOfResultAtIndex(q, attr, i).map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() } as? T
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var out: [FileSearch.Hit] = []
        let until = Date().addingTimeInterval(readBudget)
        for i in 0..<MDQueryGetResultCount(q) where out.count < cap {
            if i % 200 == 199 {
                if stale() { return [] }
                if Date() > until { break }
            }
            guard let raw = MDQueryGetResultAtIndex(q, i),
                  let path = MDItemCopyAttribute(Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue(), kMDItemPath) as? String,
                  !FileSearch.isNoise(path, home: home)
            else { continue }
            out.append(FileSearch.Hit(name: value(kMDItemFSName, i) ?? (path as NSString).lastPathComponent, path: path,
                                      lastUsed: value(kMDItemLastUsedDate, i), modified: value(kMDItemFSContentChangeDate, i)))
        }
        return out
    }
}

// MARK: Sources

struct AppEntry: Equatable {
    let name: String
    let path: String
    /// Where it lives, for the subtitle: "Applications", "Utilities", "System".
    let folder: String

    private static var roots: [(String, String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [("/Applications", "Applications"), ("/Applications/Utilities", "Utilities"),
                ("/System/Applications", "Applications"), ("/System/Applications/Utilities", "Utilities"),
                (home + "/Applications", "Your Applications"), ("/System/Library/CoreServices/Applications", "System"),
                ("/Applications/Setapp", "Setapp")]
    }

    /// Every app in the usual folders, plus one folder level down (Adobe and the like). The
    /// first copy of a name wins, in the order above.
    static func scan() -> [AppEntry] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [AppEntry] = []
        func add(_ path: String, _ folder: String) {
            let name = fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
            guard seen.insert(name.lowercased()).inserted else { return }
            out.append(AppEntry(name: name, path: path, folder: folder))
        }
        add("/System/Library/CoreServices/Finder.app", "System")
        for (root, folder) in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for n in names.sorted() where !n.hasPrefix(".") {
                let path = root + "/" + n
                if n.hasSuffix(".app") { add(path, folder); continue }
                guard root.hasSuffix("Applications"), n != "Utilities",
                      let inner = try? fm.contentsOfDirectory(atPath: path) else { continue }
                for m in inner.sorted() where m.hasSuffix(".app") { add(path + "/" + m, n) }
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Homebrew's list of installable apps, kept on disk and refreshed once a day.
final class CaskCatalog {
    enum State: Equatable { case idle, loading, ready, failed(String) }
    private(set) var casks: [Cask] = []
    private var state = State.idle
    private var waiting: [(State) -> Void] = []
    private static let url = URL(string: "https://formulae.brew.sh/api/cask.json")!
    private static let cache = Spaces.folder.appendingPathComponent("casks.json")

    func reset() { state = .idle }

    func load(_ done: @escaping (State) -> Void) {
        if state == .ready || state == .loading {
            if state == .loading { waiting.append(done) }
            return done(state)
        }
        state = .loading
        waiting = [done]
        done(.loading)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cached = ((try? Data(contentsOf: Self.cache)).flatMap { try? JSONDecoder().decode([Cask].self, from: $0) } ?? [])
                .filter { Cask.isSafeToken($0.token) }
            let age = (try? FileManager.default.attributesOfItem(atPath: Self.cache.path)[.modificationDate] as? Date)
                .map { Date().timeIntervalSince($0) } ?? .infinity
            if !cached.isEmpty { self?.finish(cached, .ready) }
            guard cached.isEmpty || age > 86_400 else { return }
            URLSession.shared.dataTask(with: Self.url) { data, response, error in
                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                let fresh = ok ? data.map(Cask.parseCatalog) ?? [] : []
                if !fresh.isEmpty {
                    try? FileManager.default.createDirectory(at: Spaces.folder, withIntermediateDirectories: true)
                    try? JSONEncoder().encode(fresh).write(to: Self.cache, options: .atomic)
                    self?.finish(fresh, .ready)
                } else if cached.isEmpty {
                    self?.finish([], .failed(error?.localizedDescription ?? "No answer from formulae.brew.sh"))
                }
            }.resume()
        }
    }

    private func finish(_ list: [Cask], _ s: State) {
        DispatchQueue.main.async {
            self.casks = list
            self.state = s
            let w = self.waiting
            if s != .loading { self.waiting = [] }
            w.forEach { $0(s) }
        }
    }
}

enum Brew {
    static var path: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Tokens of the casks Homebrew has installed, read from its Caskroom folder.
    static func installedCasks() -> Set<String> {
        let rooms = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]
        return Set(rooms.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }.filter(Cask.isSafeToken))
    }

    /// The installed app a cask most likely put in Applications, matched by name.
    static func appPath(for c: Cask, installedApps: [AppEntry]) -> String? {
        let names = [c.name, c.token.replacingOccurrences(of: "-", with: " ")].map { $0.lowercased() }
        return installedApps.first { names.contains($0.name.lowercased()) }?.path
    }

    /// Runs brew without a terminal. An installer that wants a password fails here and is
    /// finished in Terminal instead. Calls back on the main thread with the last useful line.
    static func run(_ args: [String], done: @escaping (Bool, String) -> Void) {
        guard let brew = path, args.dropFirst(2).allSatisfy(Cask.isSafeToken) else { return done(false, "not a Homebrew app name") }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: brew)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            env["HOMEBREW_NO_ENV_HINTS"] = "1"
            env["NONINTERACTIVE"] = "1"
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            var ok = false
            var text = ""
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                ok = p.terminationStatus == 0
                text = String(decoding: data, as: UTF8.self)
            } catch {
                text = error.localizedDescription
            }
            let tail = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty && !$0.hasPrefix("==>") } ?? ""
            DispatchQueue.main.async { done(ok, String(tail.prefix(140))) }
        }
    }

    /// Opens Terminal running brew commands, so their output and any password prompt are in
    /// view. Only brew, and only with fixed words or names that passed `Cask.isSafeToken`, each
    /// quoted, ever reaches the script.
    static func openInTerminal(_ commands: [String]...) {
        let allowed: Set<String> = ["brew", "install", "uninstall", "--cask", "update", "upgrade"]
        guard commands.allSatisfy({ $0.first == "brew" && $0.allSatisfy { allowed.contains($0) || Cask.isSafeToken($0) } }) else { return }
        let lines = commands.map { $0.map { "'\($0)'" }.joined(separator: " ") }.joined(separator: " && ")
        runInTerminal(lines)
    }

    private static func runInTerminal(_ command: String) {
        let url = Spaces.folder.appendingPathComponent("launcher.command")
        let script = """
        #!/bin/zsh
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        \(command)
        echo
        echo "Finished. You can close this window."

        """
        try? FileManager.default.createDirectory(at: Spaces.folder, withIntermediateDirectories: true)
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    /// Homebrew's own installer, from brew.sh, in Terminal where it can ask for a password.
    static func installHomebrew() {
        runInTerminal(#"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#)
    }
}

/// Your terminal, and the coding agents it can run.
enum Terminals {
    /// The terminal agents open in: see `TerminalChoice`.
    static func app() -> URL? {
        guard let type = UTType("com.apple.terminal.shell-script") else { return nil }
        let ws = NSWorkspace.shared
        let capable = ws.urlsForApplications(toOpen: type)
        var byID: [String: URL] = [:]
        for url in capable { if let id = Bundle(url: url)?.bundleIdentifier, byID[id] == nil { byID[id] = url } }
        let handler = ws.urlForApplication(toOpen: type)
        let pick = TerminalChoice.pick(handler: handler.flatMap { Bundle(url: $0)?.bundleIdentifier }, capable: Set(byID.keys))
        return byID[pick] ?? handler ?? ws.urlForApplication(withBundleIdentifier: TerminalChoice.terminal)
    }

    /// Writes the agent's script and hands it to the terminal, which runs it in a new window.
    static func open(_ agent: TerminalAgent, at path: String, in terminal: URL) {
        let url = Spaces.folder.appendingPathComponent("agent-\(agent.command).command")
        guard let script = agent.script(at: path) else {
            return Toast.show("Couldn’t start \(agent.name) from \(path)", symbol: "exclamationmark.triangle.fill")
        }
        do {
            try FileManager.default.createDirectory(at: Spaces.folder, withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            return Toast.show("Couldn’t start \(agent.name): \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: config) { _, error in
            if let error { DispatchQueue.main.async { Toast.show("Couldn’t start \(agent.name): \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill") } }
        }
    }

    private static var found: (at: Date, agents: [String: String])?

    /// The agents on this Mac (command to path), checked off the main thread at most every five
    /// minutes: the usual install folders first, then your login shell's PATH for anything
    /// installed somewhere else. The shell gets two seconds; a profile that leaves something
    /// running in the background can't hold the check open.
    static func installedAgents(_ done: @escaping ([String: String]) -> Void) {
        if let found, Date().timeIntervalSince(found.at) < 300 { return done(found.agents) }
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            var paths: [String: String] = [:]
            for cmd in TerminalAgent.all.map(\.command) {
                paths[cmd] = TerminalAgent.folders.lazy
                    .map { (($0 as NSString).expandingTildeInPath as NSString).appendingPathComponent(cmd) }
                    .first(where: fm.isExecutableFile(atPath:))
            }
            let missing = TerminalAgent.all.map(\.command).filter { paths[$0] == nil }
            if !missing.isEmpty {
                let out = fm.temporaryDirectory.appendingPathComponent("baneyspaces-agents-\(UUID().uuidString)")
                fm.createFile(atPath: out.path, contents: nil)
                defer { try? fm.removeItem(at: out) }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lc", "command -v " + missing.joined(separator: " ")]
                p.standardOutput = try? FileHandle(forWritingTo: out)
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                if (try? p.run()) != nil {
                    let deadline = Date().addingTimeInterval(2)
                    while p.isRunning && Date() < deadline { usleep(20_000) }
                    if p.isRunning { p.terminate() }
                    let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
                    for line in text.split(separator: "\n") where line.hasPrefix("/") && fm.isExecutableFile(atPath: String(line)) {
                        let cmd = (String(line) as NSString).lastPathComponent
                        if missing.contains(cmd) { paths[cmd] = String(line) }
                    }
                }
            }
            DispatchQueue.main.async {
                found = (Date(), paths)
                done(paths)
            }
        }
    }
}

/// A Mac App Store result from Apple's public search.
struct StoreApp: Identifiable {
    let id: Int
    let name: String
    let seller: String
    let price: String
    let bundleID: String?
    let artwork: URL?
    let webURL: URL?
    var storeURL: URL? {
        webURL.flatMap { URL(string: $0.absoluteString.replacingOccurrences(of: "https://", with: "macappstore://")) }
    }

    static func search(_ term: String, done: @escaping ([StoreApp]) -> Void) {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "term", value: term), .init(name: "entity", value: "macSoftware"), .init(name: "limit", value: "6"),
                        .init(name: "country", value: Locale.current.region?.identifier ?? "US")]
        guard let url = c.url else { return done([]) }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let results = (json?["results"] as? [[String: Any]] ?? []).compactMap { r -> StoreApp? in
                guard let id = r["trackId"] as? Int, let name = r["trackName"] as? String else { return nil }
                return StoreApp(id: id, name: name, seller: r["sellerName"] as? String ?? r["artistName"] as? String ?? "",
                                price: r["formattedPrice"] as? String ?? "", bundleID: r["bundleId"] as? String,
                                artwork: (r["artworkUrl100"] as? String).flatMap(URL.init(string:)),
                                webURL: (r["trackViewUrl"] as? String).flatMap(URL.init(string:)))
            }
            DispatchQueue.main.async { done(results) }
        }.resume()
    }
}

/// The Mac's everyday commands.
enum System {
    static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }

    /// ⌃⌘Q, the lock shortcut macOS itself listens for.
    static func lock() {
        let src = CGEventSource(stateID: .hidSystemState)
        let q = CGKeyCode(kVK_ANSI_Q)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: q, keyDown: down)
            e?.flags = [.maskCommand, .maskControl]
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Restart, shut down or log out through macOS's own confirmation dialog.
    static func loginWindow(_ event: String) {
        run("/usr/bin/osascript", ["-e", "tell application \"loginwindow\" to «event aevt\(event)»"])
    }

    static func toggleDarkMode() {
        run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"])
    }
}

/// A short message near the top of the screen, for work that finishes after the launcher closed.
enum Toast {
    private static var panel: NSPanel?
    private static var work: DispatchWorkItem?

    static func show(_ text: String, symbol: String) {
        let view = HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(Chrome.accent)
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(Chrome.panel(cornerRadius: 16))
        .padding(24)
        .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            return p
        }()
        panel = p
        p.contentView = host
        let screen = NSScreen.main ?? NSScreen.screens[0]
        p.setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height,
                          width: size.width, height: size.height), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        work?.cancel()
        let w = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
        }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: w)
    }
}

// MARK: Views

struct LauncherView: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            results
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            footer
        }
        .background(Chrome.panel(cornerRadius: 22))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(1)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: model.scope.symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                .frame(width: 24)
            if model.scope != .root {
                HStack(spacing: 4) {
                    Text(model.scope.title)
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).opacity(0.7)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(Chrome.accent.opacity(0.85)))
                .onTapGesture { model.back() }
                .accessibilityLabel("\(model.scope.title) menu. Press Delete to go back.")
            }
            SearchField(model: model, placeholder: model.scope.placeholder)
                .frame(height: 30)
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    // One view per item, header included, so the list never mixes old and new rows.
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                        VStack(alignment: .leading, spacing: 2) {
                            if i == 0 || model.items[i - 1].section != item.section {
                                Text(item.section.uppercased())
                                    .font(.system(size: 10, weight: .bold)).tracking(0.8)
                                    .foregroundStyle(.white.opacity(0.4))
                                    .padding(.leading, 12).padding(.top, i == 0 ? 4 : 10).padding(.bottom, 2)
                            }
                            row(item, selected: i == model.selected)
                        }
                        .id(item.id)
                    }
                    if model.items.isEmpty {
                        Text("Nothing matches “\(model.query)”").foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(8)
                .id(model.scope)
            }
            .onChange(of: model.selected) { i in
                if model.items.indices.contains(i) { proxy.scrollTo(model.items[i].id) }
            }
        }
    }

    private func row(_ item: LauncherItem, selected: Bool) -> some View {
        HStack(spacing: 12) {
            iconView(item.icon).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.system(size: 11.5))
                        .foregroundStyle(item.state == .failed ? Color.orange : .white.opacity(0.5)).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if item.state == .working { ProgressView().controlSize(.small).scaleEffect(0.8) }
            if !item.badge.isEmpty { badge(item.badge, strong: selected) }
            HStack(spacing: 3) { ForEach(item.workspaces.prefix(5), id: \.self) { WorkspaceBadge(n: $0, size: 18) } }
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(selected ? Color.white.opacity(0.13) : .clear))
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(Chrome.accent).frame(width: 3, height: 22).offset(x: 1) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.run(item) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func badge(_ text: String, strong: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: text.count <= 5 ? .rounded : .default))
            .foregroundStyle(.white.opacity(strong ? 0.95 : 0.6))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(text == "Install" && strong ? Chrome.accent : Color.white.opacity(0.1)))
    }

    @ViewBuilder private func iconView(_ icon: LauncherItem.Icon) -> some View {
        switch icon {
        case .file(let path): Image(nsImage: model.icon(for: path)).resizable().interpolation(.high)
        case .image(let img): Image(nsImage: img).resizable()
        case .symbol(let name):
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.09))
                .overlay(Image(systemName: name).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.85)))
        case .remote(let url):
            AsyncImage(url: url) { $0.resizable() } placeholder: { RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)) }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            hint("↩", "Open")
            hint("⌘↩", "Show in Finder")
            hint("⇥", "Open menu")
            if model.scope != .root { hint("⌫", "Back") }
            Spacer()
            hint("esc", "Close")
        }
        .padding(.horizontal, 18)
        .frame(height: 34)
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.1)))
            Text(what).font(.system(size: 11))
        }
        .foregroundStyle(.white.opacity(0.5))
    }
}

/// The search box: an AppKit field, so arrow keys, Return, Tab and Esc steer the list.
private struct SearchField: NSViewRepresentable {
    @ObservedObject var model: LauncherModel
    var placeholder: String

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 21, weight: .regular)
        f.textColor = .white
        f.delegate = context.coordinator
        f.cell?.lineBreakMode = .byTruncatingTail
        model.field = f
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.35), .font: NSFont.systemFont(ofSize: 21),
        ])
        if f.stringValue != model.query { f.stringValue = model.query }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: LauncherModel
        init(model: LauncherModel) { self.model = model }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            model.query = f.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.moveDown(_:)): model.move(1)
            case #selector(NSResponder.moveUp(_:)): model.move(-1)
            case #selector(NSResponder.insertNewline(_:)):
                model.runSelected(reveal: NSEvent.modifierFlags.contains(.command))
            case #selector(NSResponder.insertTab(_:)): model.tab()
            case #selector(NSResponder.cancelOperation(_:)):
                if !model.query.isEmpty { model.query = "" } else if model.scope != .root { model.back() } else { model.close() }
            case #selector(NSResponder.deleteBackward(_:)) where model.query.isEmpty && model.scope != .root:
                model.back()
            default: return false
            }
            return true
        }
    }
}
