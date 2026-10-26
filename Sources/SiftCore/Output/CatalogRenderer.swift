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
        let kind = item.kind == .homebrewFormula ? "Homebrew formula" : item.kind == .homebrewCask ? "Homebrew cask" : "Native app"
        let status = item.updateAvailable ? (item.autoUpdates ? "self-updating" : "update available") : "current"
        var lines = ["\(item.name.terminalInline)  \(version)", "\(kind) · \(status)"]
        if let prefix = item.prefix { lines.append("Prefix: \(prefix.terminalInline)\(item.tap.map { " · \($0.terminalInline)" } ?? "")") }
        else if let path = item.path { lines.append("Path: \(path.terminalInline)") }
        if item.kind == .nativeApp {
            lines.append("Updates: \(sourceLabel(item))\(item.updateDetail.map { " · \($0.terminalInline)" } ?? "")")
        }
        if let notes {
            let coverage = notes.coverage == "complete" ? "complete range" : notes.coverage == "repositoryCommits" ? "repository commits" : "target release"
            lines.append("Notes: \(coverage) · sift show \(item.selector.terminalInline) --full")
        }
        else if let nativeNotes {
            if let content = nativeNotes.content {
                let body = content.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).terminalInline }
                let shown = full ? body : Array(body.prefix(12))
                lines.append("Notes:")
                lines.append(contentsOf: shown)
                if shown.count < body.count { lines.append("… sift show \(item.selector.terminalInline) --full") }
            }
            if let source = nativeNotes.sourceURL { lines.append("Source: \(source.terminalInline)") }
        }
        else if item.updateAvailable { lines.append("Notes: unavailable") }
        return lines.joined(separator: "\n")
    }

    public static func json<T: Encodable>(_ value: T) throws -> String {
        try JSONOutput.encode(value)
    }
}
