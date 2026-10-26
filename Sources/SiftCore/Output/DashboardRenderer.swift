import Foundation

public enum DashboardRenderer {
    public static func humanReadable(_ dashboard: Dashboard) -> String {
        var lines = ["Sift"]

        if let dataAsOf = dashboard.dataAsOf {
            lines.append("Data as of \(relativeTimestamp(dataAsOf, relativeTo: dashboard.generatedAt))")
        } else {
            lines.append("Data has never been refreshed")
        }

        if let lastAttemptAt = dashboard.lastAttemptAt, lastAttemptAt != dashboard.dataAsOf {
            lines.append("Last refresh attempt \(relativeTimestamp(lastAttemptAt, relativeTo: dashboard.generatedAt))")
        }

        lines.append("")
        lines.append("Available updates: \(dashboard.data.availableUpdateCount)")
        if dashboard.data.informationalUpdateCount > 0 {
            lines.append("Self-updating casks: \(dashboard.data.informationalUpdateCount)")
        }
        lines.append("Changed in last 7 days: \(dashboard.data.recentTransitionCount)")
        lines.append("")
        lines.append(message(for: dashboard))
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
