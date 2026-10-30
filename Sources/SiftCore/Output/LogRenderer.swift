import Foundation

/// `sift log`: version changes grouped by the day they were observed.
public enum LogRenderer {
    public static func humanReadable(_ entries: [UpdateLogEntry], now: Date = .now, calendar: Calendar = .current, style: TerminalStyle = TerminalStyle(enabled: false)) -> String {
        guard !entries.isEmpty else { return "No version changes observed yet. Each 'sift refresh' records what changed since the last one." }
        var lines = [style.title("Update log  \(entries.count) \(entries.count == 1 ? "change" : "changes")")]
        let days = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.observedAt) }
        for day in days.keys.sorted(by: >) {
            lines.append("")
            lines.append(style.heading(dayLabel(day, now: now, calendar: calendar)))
            let rows = days[day]!.map { entry in
                ["  " + entry.name.terminalInline, "\(entry.fromVersion.terminalInline) -> \(entry.toVersion.terminalInline)", style.label(sourceLabel(entry.source))]
            }
            lines.append(contentsOf: TableFormatter.rows(rows))
        }
        return lines.joined(separator: "\n")
    }

    public static func json(_ entries: [UpdateLogEntry]) throws -> String {
        try JSONOutput.encode(entries)
    }

    static func sourceLabel(_ source: String) -> String {
        switch source {
        case "app": "App"
        case "homebrew": "Homebrew"
        case RefreshProvider.npmGlobal.rawValue: "npm"
        case RefreshProvider.uvTools.rawValue: "uv"
        case RefreshProvider.cargo.rawValue: "cargo"
        case RefreshProvider.macPorts.rawValue: "MacPorts"
        case RefreshProvider.steamGames.rawValue: "Steam"
        default: source
        }
    }

    static func dayLabel(_ day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        return day.formatted(sameYear ? .dateTime.weekday(.abbreviated).month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }
}
