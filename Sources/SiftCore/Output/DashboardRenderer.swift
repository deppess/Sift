import Foundation

public enum DashboardRenderer {
    public static func humanReadable(_ dashboard: Dashboard, style: TerminalStyle = TerminalStyle(enabled: false)) -> String {
        var lines = [style.brand("Sift")]

        if let dataAsOf = dashboard.dataAsOf {
            lines.append("\(style.label("Data as of")) \(relativeTimestamp(dataAsOf, relativeTo: dashboard.generatedAt))")
        } else {
            lines.append("Data has never been refreshed")
        }

        if let lastAttemptAt = dashboard.lastAttemptAt, lastAttemptAt != dashboard.dataAsOf {
            lines.append("Last refresh attempt \(relativeTimestamp(lastAttemptAt, relativeTo: dashboard.generatedAt))")
        }

        lines.append("")
        lines.append("\(style.label("Available updates:")) \(style.accent(String(dashboard.data.availableUpdateCount)))")
        if dashboard.data.informationalUpdateCount > 0 {
            lines.append("\(style.label("Self-updating casks:")) \(dashboard.data.informationalUpdateCount)")
        }
        if dashboard.data.homebrewCleanupCount > 0 {
            lines.append(
                "\(style.warning("Homebrew cleanup:")) \(style.warning(String(dashboard.data.homebrewCleanupCount))) (see 'sift updates' for commands)")
        }
        lines.append("\(style.label("Changed in last 7 days:")) \(dashboard.data.recentTransitionCount)")
        lines.append("")
        let message = message(for: dashboard)
        lines.append(dashboard.freshness == .stale || dashboard.latestRefreshStatus == .failure ? style.warning(message) : message)
        return lines.joined(separator: "\n")
    }

    public static func json(_ dashboard: Dashboard) throws -> String {
        try JSONOutput.encode(dashboard)
    }

    static func relativeTimestamp(_ date: Date, relativeTo referenceDate: Date) -> String {
        // Timestamps round-trip through whole seconds, so a refresh that just finished can read as
        // slightly in the future.
        if abs(referenceDate.timeIntervalSince(date)) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: referenceDate)
    }

    private static func message(for dashboard: Dashboard) -> String {
        switch dashboard.latestRefreshStatus {
        case .never:
            return "Run 'sift refresh' to collect installed application data."
        case .success where dashboard.freshness == .stale:
            return "Cached data is stale. Run 'sift refresh' to update it."
        case .partial:
            let incomplete = dashboard.data.providerResults.filter { $0.status == .partial || $0.status == .failure }
            let reasons = incomplete.map { result in
                let reason = result.message?.split(separator: "\n").first.map { ": \(String($0).terminalInline)" } ?? ""
                return "  \(result.provider.rawValue)\(reason)"
            }
            return (["Incomplete providers (cached data was preserved):"] + reasons).joined(separator: "\n")
        case .failure:
            return "The latest refresh failed; cached data may be outdated."
        default:
            return "Cached data is current."
        }
    }
}
