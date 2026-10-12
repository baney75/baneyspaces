import Foundation

/// Which builds an install follows. Stable is each tagged release; nightly is main, rebuilt each
/// night it changed. Nightly also offers a stable release that is newer than the last nightly.
public enum UpdateChannel: String, CaseIterable, Sendable {
    case stable, nightly
}

/// What this copy of BaneySpaces was built from, as stamped into Info.plist by the build.
public struct BuildInfo: Equatable, Sendable {
    public let version: String
    public let commit: String?
    public let commitDate: Date?

    public init(version: String, commit: String?, commitDate: Date?) {
        self.version = version
        self.commit = commit
        self.commitDate = commitDate
    }
}

/// One GitHub release, reduced to what the updater needs.
public struct Release: Equatable, Sendable {
    public let tag: String
    public let name: String
    public let notes: String
    public let prerelease: Bool
    public let url: String
    /// From the marker line the release workflow writes into the notes.
    public let commit: String?
    public let commitDate: Date?

    public init(tag: String, name: String, notes: String, prerelease: Bool, url: String) {
        self.tag = tag
        self.name = name
        self.prerelease = prerelease
        self.url = url
        let marker = Release.marker(in: notes)
        commit = marker.commit
        commitDate = marker.date
        // The marker is for BaneySpaces, not for people.
        self.notes = notes.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("<!-- baneyspaces ") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only tags BaneySpaces itself publishes, so nothing else ever reaches the installer.
    public var isInstallable: Bool { tag == "nightly" || Version(tag) != nil }

    public var isNightly: Bool { tag == "nightly" }

    /// `<!-- baneyspaces commit=<sha> date=<ISO 8601> -->`
    static func marker(in notes: String) -> (commit: String?, date: Date?) {
        guard let line = notes.split(separator: "\n").first(where: { $0.contains("<!-- baneyspaces ") }) else { return (nil, nil) }
        var commit: String?, date: Date?
        for field in line.split(separator: " ") {
            let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            if pair[0] == "commit", pair[1].allSatisfy(\.isHexDigit), pair[1].count >= 7 { commit = pair[1] }
            if pair[0] == "date" { date = ISO8601DateFormatter().date(from: pair[1]) }
        }
        return (commit, date)
    }

    /// Releases from the GitHub API's JSON list. Drafts and anything unparsable are skipped.
    public static func list(fromGitHubJSON data: Data) -> [Release] {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard item["draft"] as? Bool != true, let tag = item["tag_name"] as? String else { return nil }
            return Release(tag: tag, name: item["name"] as? String ?? tag, notes: item["body"] as? String ?? "",
                           prerelease: item["prerelease"] as? Bool ?? false, url: item["html_url"] as? String ?? "")
        }
    }
}

/// A release version like `v0.2.1` or `0.2.1`.
public struct Version: Comparable, Sendable {
    public let parts: [Int]

    public init?(_ text: String) {
        let bare = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (2...4).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}

public enum Updates {
    /// Whether installing `release` moves this build forward. Builds and releases that carry
    /// their commit compare by commit date, so nightly and stable can be mixed without ever
    /// offering an older build; otherwise version numbers decide.
    public static func isNewer(_ release: Release, than build: BuildInfo) -> Bool {
        if let commit = release.commit, let built = build.commit, commit.hasPrefix(built) || built.hasPrefix(commit) { return false }
        if let date = release.commitDate, let built = build.commitDate { return date > built }
        guard let v = Version(release.tag), let mine = Version(build.version) else { return false }
        return v > mine
    }

    /// The release to offer on `channel`, if any is newer than `build`.
    public static func offer(from releases: [Release], channel: UpdateChannel, build: BuildInfo) -> Release? {
        let stable = releases.filter { !$0.prerelease && Version($0.tag) != nil }
            .max { Version($0.tag)! < Version($1.tag)! }
        var candidates = [stable].compactMap { $0 }
        if channel == .nightly, let nightly = releases.first(where: \.isNightly) { candidates.append(nightly) }
        // Of the candidates newer than this build, the newest one.
        return candidates.filter { $0.isInstallable && isNewer($0, than: build) }.max { a, b in
            if let x = a.commitDate, let y = b.commitDate { return x < y }
            return !a.isNightly && b.isNightly
        }
    }
}
