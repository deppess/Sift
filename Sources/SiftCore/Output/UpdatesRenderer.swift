import Foundation

public enum UpdatesRenderer {
    public static func humanReadable(_ updates: [UnifiedUpdate], style: TerminalStyle = TerminalStyle(enabled: false)) -> String {
        guard !updates.isEmpty else { return "No cached updates available." }
        let available = updates.filter { $0.installationIssue == nil }
        let cleanup = updates.filter { $0.installationIssue != nil }
        let rows = available.map {
            [
                $0.name.terminalInline, "\($0.installedVersion.terminalInline) -> \($0.availableVersion.terminalInline)", $0.provider.terminalInline,
                $0.scope.terminalInline, $0.selfUpdating ? "self-updating" : ""
            ]
        }
        let freshness =
            updates.contains(where: { $0.freshness == .stale })
            ? "Snapshot is stale; run 'sift refresh' before comparing." : "Matches the latest cached snapshot."
        let selfUpdatingCount = available.filter(\.selfUpdating).count
        let header =
            selfUpdatingCount == 0
            ? "Updates  \(available.count)" : "Updates  \(available.count - selfUpdatingCount) + \(selfUpdatingCount) self-updating"
        var lines = [style.title(header), updates.contains(where: { $0.freshness == .stale }) ? style.warning(freshness) : style.label(freshness)]
        if !rows.isEmpty { lines += [""] + TableFormatter.rows(rows).map { $0.trimmingTrailingSpaces } }
        if !cleanup.isEmpty {
            lines += ["", style.warning("Homebrew cleanup  \(cleanup.count)")]
            for item in cleanup {
                if let issue = item.installationIssue { lines.append("\(item.name.terminalInline)  \(issue.terminalInline)") }
                if let command = item.suggestedCommand { lines.append("  Try: \(command.terminalInline)") }
                if let fallback = item.fallbackCommand {
                    lines.append("  If uninstall fails because its script is missing: \(fallback.terminalInline)")
                }
            }
            lines.append("  If Homebrew says it is not installed, do not force it; run 'sift refresh' to clear Sift's old snapshot.")
            lines.append("  --force may leave support files behind. Run 'sift refresh' after cleanup.")
        }
        return lines.joined(separator: "\n")
    }

    public static func json(_ updates: [UnifiedUpdate]) throws -> String {
        try JSONOutput.encode(updates)
    }
}

private extension String {
    var trimmingTrailingSpaces: String {
        guard let end = lastIndex(where: { $0 != " " }) else { return "" }
        return String(self[...end])
    }
}
