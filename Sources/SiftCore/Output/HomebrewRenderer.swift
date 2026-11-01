import Foundation

public enum HomebrewRenderer {
    public static func show(_ notes: HomebrewReleaseNotes, full: Bool = false, style: TerminalStyle = TerminalStyle(enabled: false)) -> String {
        let title = style.title(notes.name.terminalInline)
        let version = "\(notes.installedVersion.terminalInline) -> \(notes.availableVersion.terminalInline)"
        let coverage =
            notes.coverage == "complete"
            ? style.success("complete range") : notes.coverage == "repositoryCommits" ? style.warning("repository commits") : style.warning("target release")
        var renderer = MarkdownTerminalRenderer(style: style)
        let content = renderer.render(notes.content, full: full)
        return "\(title)  \(version)\n\(style.label("Changelog:")) \(coverage)\n\(content)\n\(style.label("Source:")) \(notes.sourceURL.terminalInline)"
    }

}
