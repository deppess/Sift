import Foundation

/// One release in a changelog, newest first within a `Changelog`.
public struct ChangelogEntry: Codable, Equatable, Sendable {
    /// The version the entry describes, as the source writes it ("0.39.1", "v2.103.2"); for a
    /// source without versions (Steam announcements) the entry's title.
    public let version: String
    public let title: String?
    public let date: Date?
    /// Markdown.
    public let content: String
    public let sourceURL: String?

    public init(version: String, title: String? = nil, date: Date? = nil, content: String, sourceURL: String? = nil) {
        self.version = version
        self.title = title
        self.date = date
        self.content = content
        self.sourceURL = sourceURL
    }
}

/// Everything Sift found about what changed in one app, game, or package, from a single source.
public struct Changelog: Codable, Equatable, Sendable {
    public let selector: String
    public let name: String
    public let installedVersion: String?
    public let availableVersion: String?
    /// The source in a user's words: "GitHub releases (cli/cli)", "sw.kovidgoyal.net", "Steam news".
    public let source: String
    public let sourceURL: String?
    public let entries: [ChangelogEntry]
    public let fetchedAt: Date
    /// Why a cached copy is shown instead of a fresh one, when fetching failed.
    public var staleReason: String?

    public init(selector: String, name: String, installedVersion: String?, availableVersion: String?, source: String, sourceURL: String?, entries: [ChangelogEntry], fetchedAt: Date, staleReason: String? = nil) {
        self.selector = selector
        self.name = name
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.source = source
        self.sourceURL = sourceURL
        self.entries = entries
        self.fetchedAt = fetchedAt
        self.staleReason = staleReason
    }

    /// Entries newer than the installed version, newest first; empty when it is current or
    /// can't be placed.
    public var newEntries: [ChangelogEntry] {
        guard let installedVersion else { return [] }
        let installed = ChangelogVersion.normalized(installedVersion)
        if let index = ChangelogVersion.installedIndex(in: entries, installed: installed) { return Array(entries[..<index]) }
        // The installed version has no entry of its own (a rebuild, or a source that skips
        // versions): keep the entries that compare newer.
        guard entries.contains(where: { ChangelogVersion.token(in: $0.version) != nil }) else { return [] }
        return Array(entries.prefix { entry in
            guard let token = ChangelogVersion.token(in: entry.version) else { return false }
            return SparkleVersion.compare(token, installed) == .orderedDescending
        })
    }

    /// The entry for the installed version itself, when the source has one.
    public var installedEntry: ChangelogEntry? {
        guard let installedVersion else { return nil }
        return ChangelogVersion.installedIndex(in: entries, installed: ChangelogVersion.normalized(installedVersion)).map { entries[$0] }
    }
}

/// Version strings as changelogs and package managers write them.
enum ChangelogVersion {
    /// The first version-looking token: "v2.103.2" in "Release v2.103.2 (2026-10-21)" is
    /// "2.103.2"; "Version 8" is "8".
    static func token(in text: String) -> String? {
        // A short word may be attached: "go1.25.0", "bash-5.3-release", "v2.1".
        if let match = text.firstMatch(of: #/(?i)\bto\s+v?(\d+(?:\.\d+)+[a-z]?)\s*$/#), text.range(of: "from", options: .caseInsensitive) != nil { return String(match.1) }
        // The number after "release" or "version" wins over others ("POSIX 1003.1" in a heading).
        if let match = text.firstMatch(of: #/(?i)\b(?:release|version)\s+v?(\d+(?:\.\d+)+(?:-?(?:alpha|beta|rc|preview|pre|dev)\.?\d*)?)/#) { return String(match.1) }
        let pattern = #/(?i)(?:^|[^\w.])(?:[a-z]{1,12}[-_]?)?v?(\d+(?:\.\d+)+(?:-?(?:alpha|beta|rc|preview|pre|dev)\.?\d*)?)/#
        if let match = text.firstMatch(of: pattern) { return String(match.1) }
        if let match = text.firstMatch(of: #/(?i)\bversion\s+(\d+)\b/#) { return String(match.1) }
        return nil
    }

    /// What an installed version is compared as: Homebrew's `_1` revision and a cask's `,build`
    /// suffix, and an app's "(build)", are dropped.
    static func normalized(_ installed: String) -> String {
        var value = installed.trimmingCharacters(in: .whitespaces)
        if let paren = value.firstIndex(of: "(") { value = String(value[..<paren]).trimmingCharacters(in: .whitespaces) }
        if let comma = value.firstIndex(of: ",") { value = String(value[..<comma]) }
        if let match = value.firstMatch(of: #/^(.+)_\d+$/#) { value = String(match.1) }
        if value.lowercased().hasPrefix("v"), value.dropFirst().first?.isNumber == true { value.removeFirst() }
        return value
    }

    static func matches(_ entryVersion: String, _ installed: String) -> Bool {
        guard !installed.isEmpty else { return false }
        if entryVersion == installed { return true }
        guard let token = token(in: entryVersion) else { return false }
        return token == installed || SparkleVersion.compare(token, installed) == .orderedSame
    }

    /// "7.30" and "7.3", or "7.50.1" and "7.5.1": the same version written with and without a
    /// trailing zero in a minor part. Only used when nothing matches exactly, since "1.10" and
    /// "1.1" are different versions for most projects.
    static func looselyMatches(_ entryVersion: String, _ installed: String) -> Bool {
        guard let token = token(in: entryVersion) else { return false }
        func key(_ value: String) -> [String] {
            value.split(separator: ".").enumerated().map { index, part in
                guard index > 0, part.count > 1, part.allSatisfy(\.isNumber) else { return String(part) }
                let trimmed = part.drop { _ in false }.reversed().drop { $0 == "0" }.reversed()
                return trimmed.isEmpty ? "0" : String(trimmed)
            }
        }
        if key(token) == key(installed) { return true }
        // Leading zeros ("019" and "19") and a build number after the release ("26.1.5.5384"
        // installed, "26.1.5" listed).
        let numbers = { (value: String) in value.split(separator: ".").map { part in Int(part).map(String.init) ?? String(part) } }
        let (a, b) = (numbers(token), numbers(installed))
        if a == b { return true }
        return a.count >= 3 && b.count == a.count + 1 && Array(b.prefix(a.count)) == a
    }

    /// The index of the installed version's entry: an exact match, or else a loose one.
    static func installedIndex(in entries: [ChangelogEntry], installed: String) -> Int? {
        entries.firstIndex { matches($0.version, installed) } ?? entries.firstIndex { looselyMatches($0.version, installed) }
    }
}
