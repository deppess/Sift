import Foundation

/// The `livecheck` block of a Homebrew cask or formula: the update endpoint Homebrew itself
/// checks for new versions, which Homebrew maintains for thousands of apps. Sparkle feeds and
/// JSON update endpoints there often carry release notes. Only the block's URL and strategy are
/// read; the Ruby is never run.
struct HomebrewLivecheck: Equatable {
    enum Strategy: Equatable { case sparkle, json, github, page, other }

    let url: URL
    let strategy: Strategy

    /// Parses `source` (the cask or formula Ruby file). `version` and the cask's `arch` line fill
    /// the common interpolations; a URL with any other interpolation is skipped.
    init?(source: String, version: String?, downloadURL: String?, homepage: String?) {
        guard let start = source.range(of: "\n  livecheck do") else { return nil }
        let block = source[start.upperBound...].prefix { _ in true }
        guard let end = block.range(of: "\n  end") else { return nil }
        let body = String(block[..<end.lowerBound])
        let strategyName = body.firstMatch(of: #/strategy\s+:(\w+)/#).map { String($0.1) } ?? ""
        var rawURL: String?
        if let match = body.firstMatch(of: #/url\s+"([^"]+)"/#) {
            rawURL = String(match.1)
        } else if let match = body.firstMatch(of: #/url\s+:(\w+)/#) {
            switch match.1 {
            case "url", "stable": rawURL = downloadURL
            case "homepage": rawURL = homepage
            default: rawURL = nil
            }
        }
        guard var text = rawURL else { return nil }
        // arch arm: "arm64", intel: "amd64"
        let arch = source.firstMatch(of: #/\n  arch\s+arm:\s+"([^"]*)"/#).map { String($0.1) } ?? "arm64"
        let full = version ?? ""
        let csv = full.split(separator: ",").map(String.init)
        let parts = (csv.first ?? full).split(separator: ".").map(String.init)
        let substitutions: [String: String] = [
            "#{arch}": arch,
            "#{version}": full,
            "#{version.csv.first}": csv.first ?? full,
            "#{version.csv.second}": csv.count > 1 ? csv[1] : "",
            "#{version.major}": parts.first ?? "",
            "#{version.major_minor}": parts.prefix(2).joined(separator: "."),
            "#{version.major_minor_patch}": parts.prefix(3).joined(separator: "."),
        ]
        for (key, value) in substitutions { text = text.replacingOccurrences(of: key, with: value) }
        guard !text.contains("#{"), let url = URL(string: text), isPublicHTTPSURL(url) else { return nil }
        self.url = url
        switch strategyName {
        case "sparkle": strategy = .sparkle
        case "json": strategy = .json
        case "github_latest", "github_releases", "git": strategy = .github
        case "page_match", "": strategy = .page
        default: strategy = .other
        }
    }
}

/// Release notes in a vendor's JSON update endpoint (VS Code's `notes`, Postman's `notes`,
/// Raycast's `body`): a release object, a list of them, or an object wrapping a list.
enum UpdateFeedJSON {
    private static let versionKeys = ["version", "productVersion", "release-version", "name", "latestVersion", "tag_name", "tagName"]
    private static let notesKeys = ["whatsnew", "notes", "releaseNotes", "release_notes", "release-notes", "body", "changelog", "changes", "description"]
    private static let dateKeys = ["pub_date", "pubDate", "date", "timestamp", "published_at", "releaseDate", "release_date", "release-date"]

    /// Entries with text, and links (a `notes` field holding a URL) to read as pages.
    static func read(_ data: Data) -> (entries: [ChangelogEntry], links: [URL]) {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return ([], []) }
        var objects: [[String: Any]] = []
        if let object = json as? [String: Any] {
            objects = [object]
            for value in object.values { if let list = value as? [[String: Any]], list.count > 1 { objects += list } }
        } else if let list = json as? [[String: Any]] {
            objects = list
        }
        var entries: [ChangelogEntry] = []
        var links: [URL] = []
        for object in objects {
            guard let label = versionKeys.lazy.compactMap({ object[$0] as? String }).first(where: { ChangelogVersion.token(in: $0) != nil }) else { continue }
            let version = ChangelogVersion.token(in: label) ?? label
            for key in notesKeys {
                guard let value = object[key] as? String, !value.isEmpty else { continue }
                if let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https", !value.contains(" ") {
                    links.append(url)
                } else {
                    let date = dateKeys.lazy.compactMap { key -> Date? in
                        if let text = object[key] as? String { return ISO8601DateFormatter().date(from: text) ?? ChangelogDocument.date(in: text) }
                        if let number = object[key] as? Double { return Date(timeIntervalSince1970: number > 1e11 ? number / 1000 : number) }
                        return nil
                    }.first
                    entries.append(ChangelogEntry(version: version, date: date, content: value.contains("<") ? HTMLMarkdown.convert(value) : ChangelogDocument.tidy(value)))
                }
                break
            }
        }
        return (entries, links)
    }
}
