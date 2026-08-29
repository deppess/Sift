import Foundation

public enum HomebrewRenderer {
    public static func humanReadable(_ updates: [HomebrewUpdate]) -> String {
        guard !updates.isEmpty else { return "No updates available for user-installed Homebrew packages." }
        var lines = ["Available updates", ""]
        lines.append(contentsOf: updates.map {
            let status = $0.freshness == .current ? "current" : "\($0.freshness.rawValue); data as of \($0.dataAsOf?.ISO8601Format() ?? "unknown")"
            return "\($0.name.terminalInline)\t\($0.installedVersion.terminalInline) -> \($0.availableVersion.terminalInline)\t\($0.autoUpdates ? "auto-updates" : $0.kind.rawValue)\t\(status.terminalInline)"
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
