import Foundation

public enum CatalogRenderer {
    public static func list(_ items: [CatalogItem]) -> String {
        guard !items.isEmpty else { return "No cached applications. Run 'sift refresh' to collect them." }
        let rows = items.map { item -> [String] in
            let version = (item.installedVersion ?? "Unknown version").terminalInline
            let target = item.updateAvailable ? " -> \(item.availableVersion!)" : ""
            return [item.name.terminalInline, "\(version)\(target.terminalInline)", sourceLabel(item)]
        }
        return (["Applications", ""] + TableFormatter.rows(rows)).joined(separator: "\n")
    }

    /// Where an item's updates come from, in the words a user would use.
    static func sourceLabel(_ item: CatalogItem) -> String {
        switch item.updateSource {
        case "homebrew": "Homebrew"
        case "homebrewCatalog": "Homebrew catalog"
        case "macports": "MacPorts"
        case "blackmagic": "Blackmagic"
        case "setapp": "Setapp"
        case "electron": "Electron updater"
        case "bundled": "Bundled"
        case "githubReleases": "GitHub Releases"
        case "appStore": "App Store"
        case "sparkle": "Sparkle"
        case "steam": "Steam"
        case "apple": "macOS"
        default: "unknown"
        }
    }

    public static func detail(_ item: CatalogItem, notes: HomebrewReleaseNotes?, nativeNotes: NativeReleaseNotes? = nil, full: Bool = false) -> String {
        let installed = (item.installedVersion ?? "Unknown").terminalInline
        let available = (item.availableVersion ?? item.installedVersion ?? "Unknown").terminalInline
        let version = item.updateAvailable ? "\(installed) -> \(available)" : installed
        let kind = switch item.kind {
        case .homebrewFormula: "Homebrew formula"
        case .homebrewCask: "Homebrew cask"
        case .nativeApp: "Native app"
        case .package: "\(LogRenderer.sourceLabel(item.updateSource ?? "")) package"
        }
        let status = item.updateAvailable ? (item.autoUpdates ? "self-updating" : "update available") : "current"
        var lines = ["\(item.name.terminalInline)  \(version)", "\(kind) · \(status)"]
        if let prefix = item.prefix { lines.append("Prefix: \(prefix.terminalInline)\(item.tap.map { " · \($0.terminalInline)" } ?? "")") }
        else if let path = item.path { lines.append("Path: \(path.terminalInline)") }
        if item.kind == .nativeApp {
            lines.append("Updates: \(sourceLabel(item))\(item.updateDetail.map { " · \($0.terminalInline)" } ?? "")")
        }
        if let notes {
            let coverage = notes.coverage == "complete" ? "complete range" : notes.coverage == "repositoryCommits" ? "repository commits" : "target release"
            lines.append("Changelog: \(coverage) · sift changelog \(item.selector.terminalInline)")
        }
        else if let nativeNotes {
            if let content = nativeNotes.content {
                let body = content.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).terminalInline }
                let shown = full ? body : Array(body.prefix(12))
                lines.append("Changelog:")
                lines.append(contentsOf: shown)
                if shown.count < body.count { lines.append("… sift changelog \(item.selector.terminalInline)") }
            }
            if let source = nativeNotes.sourceURL { lines.append("Source: \(source.terminalInline)") }
        }
        else { lines.append("Changelog: sift changelog \(item.selector.terminalInline)") }
        return lines.joined(separator: "\n")
    }

    /// The item's details and what changed, from the cached changelog: the versions newer than
    /// the installed one (or the latest release when it is current).
    public static func detail(_ item: CatalogItem, changelog: Changelog, style: TerminalStyle = TerminalStyle(enabled: false)) -> String {
        var lines = detail(item, notes: nil).split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.hasPrefix("Changelog:") }
        let newEntries = changelog.newEntries
        let shown = newEntries.isEmpty ? Array(changelog.entries.prefix(1)) : Array(newEntries.prefix(3))
        lines.append("Changelog: \(changelog.source.terminalInline)\(newEntries.isEmpty ? "" : " · \(newEntries.count) new")")
        for entry in shown {
            let date = entry.date.map { "  \(style.label(ChangelogRenderer.dateText($0)))" } ?? ""
            lines.append("")
            lines.append("\(style.heading(entry.version.terminalInline))\(date)")
            let body = ChangelogRenderer.render(entry.content, full: false, style: style).split(separator: "\n", omittingEmptySubsequences: false)
            lines += body.prefix(12).map { "  \($0)" }
            if body.count > 12 { lines.append(style.label("  …")) }
        }
        lines.append("")
        lines.append(style.label("Full changelog: sift changelog \(item.selector.terminalInline)\(changelog.entries.count > shown.count ? " (\(changelog.entries.count) versions)" : "")"))
        return lines.joined(separator: "\n")
    }

    public static func json<T: Encodable>(_ value: T) throws -> String {
        try JSONOutput.encode(value)
    }
}
