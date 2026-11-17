import Foundation

public enum RefreshRenderer {
    public static func humanReadable(_ summary: RefreshSummary, style: TerminalStyle = TerminalStyle(enabled: false)) -> String {
        var lines = [
            style.brand("Sift refresh"),
            "",
            "Applications discovered: \(summary.discoveredCount)",
            "Added: \(summary.addedCount)",
            "Changed: \(summary.changedCount)",
            "Unchanged: \(summary.unchangedCount)",
            "Marked inactive: \(summary.inactiveCount)",
            "Homebrew packages: \(summary.homebrewDiscoveredCount)",
            "Targets resolved: \(summary.targetResolvedCount)",
            "Release notes fetched: \(summary.releaseNotesFetchedCount)",
            "Warnings: \(summary.warningCount == 0 ? "0" : style.warning(String(summary.warningCount)))"
        ]
        if !summary.providerResults.isEmpty {
            lines.append("")
            lines.append(style.heading("Providers"))
            let rows = TableFormatter.rows(summary.providerResults.map { [$0.provider.rawValue, $0.status.rawValue] })
            lines.append(
                contentsOf: zip(rows, summary.providerResults).map { row, result in
                    let status = result.status.rawValue
                    let painted = result.status == .success ? style.success(status) : style.warning(status)
                    return String(row.dropLast(status.count)) + painted
                })
            // What each provider had to say: why data is incomplete, or what to do about it.
            let messages = summary.providerResults.compactMap { result in result.message.map { "\(result.provider.rawValue): \($0.terminalInline)" } }
            if !messages.isEmpty {
                lines.append("")
                lines.append(style.heading("Notes"))
                lines.append(contentsOf: messages.map { "  \($0)" })
            }
        }
        lines.append("")
        lines.append(
            summary.status == .success
                ? style.success("Refresh completed successfully.") : style.warning("Refresh completed with incomplete provider data."))
        return lines.joined(separator: "\n")
    }

    public static func json(_ summary: RefreshSummary) throws -> String {
        try JSONOutput.encode(summary)
    }
}
