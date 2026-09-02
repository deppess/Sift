import Foundation

public enum HomebrewRenderer {
    public static func humanReadable(_ updates: [HomebrewUpdate]) -> String {
        guard !updates.isEmpty else { return "No updates available for user-installed Homebrew packages." }
        let freshness = updates.map(\.freshness).contains(.stale) ? "Snapshot is stale; run 'sift refresh' before comparing with Homebrew." : "Matches Homebrew's latest cached outdated snapshot."
        var lines = ["Homebrew updates  \(updates.count)", freshness, ""]
        lines.append(contentsOf: updates.map {
            let ownership = $0.ownership == .dependency ? "dependency" : $0.kind == .cask ? "cask" : "requested"
            return "\($0.name.terminalInline)\t\($0.installedVersion.terminalInline) -> \($0.availableVersion.terminalInline)\t\($0.kind.rawValue)\t\(ownership)"
        })
        return lines.joined(separator: "\n")
    }

    public static func json(_ updates: [HomebrewUpdate]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(updates), as: UTF8.self)
    }

    public static func show(_ notes: HomebrewReleaseNotes, full: Bool = false, style: TerminalStyle = TerminalStyle(enabled: false)) -> String {
        let title = style.title(notes.name.terminalInline)
        let version = "\(notes.installedVersion.terminalInline) -> \(notes.availableVersion.terminalInline)"
        let coverage = notes.coverage == "complete" ? style.success("complete range") : notes.coverage == "repositoryCommits" ? style.warning("repository commits") : style.warning("target release")
        var renderer = MarkdownTerminalRenderer(style: style)
        let content = renderer.render(notes.content, full: full)
        return "\(title)  \(version)\n\(style.label("Notes:")) \(coverage)\n\(content)\n\(style.label("Source:")) \(notes.sourceURL.terminalInline)"
    }

}
