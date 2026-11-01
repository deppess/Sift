import Foundation

/// `sift changelog`: what changed, newest first, read in the terminal.
public enum ChangelogRenderer {
    /// By default: every version newer than the installed one, then the installed version's own
    /// entry; for current software, the latest three. `all` shows the whole history.
    public static func humanReadable(_ changelog: Changelog, all: Bool = false, full: Bool = false, style: TerminalStyle = TerminalStyle(enabled: false))
        -> String
    {
        let newEntries = changelog.newEntries
        let installedEntry = changelog.installedEntry
        var lines: [String] = []
        let installed = changelog.installedVersion?.terminalInline ?? "unknown"
        let header: String
        if let available = changelog.availableVersion, available != changelog.installedVersion {
            header = "\(style.title(changelog.name.terminalInline))  \(installed) -> \(available.terminalInline)"
        } else {
            header = "\(style.title(changelog.name.terminalInline))  \(installed)"
        }
        let newCount =
            newEntries.isEmpty
            ? ""
            : changelog.isDatedLog
                ? "  ·  \(newEntries.count) \(newEntries.count == 1 ? "update" : "updates") since this copy was installed"
                : "  ·  \(newEntries.count) new \(newEntries.count == 1 ? "version" : "versions")"
        lines.append(header + style.label(newCount))
        lines.append(style.label("Changelog from \(changelog.source.terminalInline) · \(count(changelog.entries.count, changelog))"))
        if let stale = changelog.staleReason { lines.append(style.warning(stale.terminalInline)) }

        let shown: [ChangelogEntry]
        if all {
            shown = changelog.entries
        } else if !newEntries.isEmpty {
            shown = newEntries + (installedEntry.map { [$0] } ?? [])
        } else {
            shown = Array(changelog.entries.prefix(3))
        }
        for entry in shown {
            lines.append("")
            lines.append(entryHeading(entry, changelog: changelog, newEntries: newEntries, style: style))
            let body = render(entry.content, full: full, style: style)
            lines.append(
                body.isEmpty
                    ? style.label("  (no details given)")
                    : body.split(separator: "\n", omittingEmptySubsequences: false).map { "  \($0)" }.joined(separator: "\n"))
            if full, let url = entry.sourceURL, url != changelog.sourceURL { lines.append(style.label("  \(url.terminalInline)")) }
        }
        let hidden = changelog.entries.count - shown.count
        lines.append("")
        if hidden > 0 { lines.append(style.label("\(count(hidden, changelog, older: true)) · sift changelog \(changelog.selector.terminalInline) --all")) }
        if let url = changelog.sourceURL { lines.append(style.label("Source: \(url.terminalInline)")) }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// "3 versions", or "3 posts" for a source without version numbers (Steam announcements).
    private static func count(_ value: Int, _ changelog: Changelog, older: Bool = false) -> String {
        let versioned = changelog.entries.contains { ChangelogVersion.token(in: $0.version) == $0.version }
        let noun = versioned ? (value == 1 ? "version" : "versions") : (value == 1 ? "post" : "posts")
        return "\(value) \(older ? "older " : "")\(noun)"
    }

    public static func unavailable(name: String, tried: [String], style: TerminalStyle = TerminalStyle(enabled: false)) -> String {
        var lines = ["\(style.title(name.terminalInline))  no changelog found"]
        if !tried.isEmpty {
            lines.append(style.label("Looked in:"))
            lines += tried.map { "  \($0.terminalInline)" }
        }
        return lines.joined(separator: "\n")
    }

    public static func json(_ changelog: Changelog) throws -> String {
        try JSONOutput.encode(changelog)
    }

    private static func entryHeading(_ entry: ChangelogEntry, changelog: Changelog, newEntries: [ChangelogEntry], style: TerminalStyle) -> String {
        var parts = [style.heading(entry.version.terminalInline)]
        if let title = entry.title { parts.append(title.terminalInline) }
        if let date = entry.date { parts.append(style.label(ChangelogRenderer.dateText(date))) }
        if let installed = changelog.installedVersion, ChangelogVersion.matches(entry.version, ChangelogVersion.normalized(installed)) {
            parts.append(style.success("installed"))
        } else if newEntries.contains(entry) {
            parts.append(style.warning("new"))
        }
        return parts.joined(separator: "  ")
    }

    /// A release date: a date-only value (midnight UTC) is shown as that calendar day, not
    /// shifted into the local time zone.
    static func dateText(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.year().month(.abbreviated).day()
        if date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) == 0 { style.timeZone = TimeZone(secondsFromGMT: 0)! }
        return date.formatted(style)
    }

    static func render(_ markdown: String, full: Bool, style: TerminalStyle) -> String {
        var renderer = MarkdownTerminalRenderer(style: style)
        renderer.linkDestinations = full
        return renderer.render(markdown, full: full)
    }
}
