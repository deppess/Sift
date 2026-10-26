import Foundation

public enum RefreshRenderer {
    public static func humanReadable(_ summary: RefreshSummary) -> String {
        var lines = [
            "Sift refresh",
            "",
            "Applications discovered: \(summary.discoveredCount)",
            "Added: \(summary.addedCount)",
            "Changed: \(summary.changedCount)",
            "Unchanged: \(summary.unchangedCount)",
            "Marked inactive: \(summary.inactiveCount)",
            "Homebrew packages: \(summary.homebrewDiscoveredCount)",
            "Targets resolved: \(summary.targetResolvedCount)",
            "Release notes fetched: \(summary.releaseNotesFetchedCount)",
            "Warnings: \(summary.warningCount)",
        ]
        if !summary.providerResults.isEmpty {
            lines.append("")
            lines.append("Providers")
            lines.append(contentsOf: TableFormatter.rows(summary.providerResults.map { [$0.provider.rawValue, $0.status.rawValue] }))
        }
        lines.append("")
        lines.append(summary.status == .success ? "Refresh completed successfully." : "Refresh completed with incomplete provider data.")
        return lines.joined(separator: "\n")
    }

    public static func json(_ summary: RefreshSummary) throws -> String {
        try JSONOutput.encode(summary)
    }
}
