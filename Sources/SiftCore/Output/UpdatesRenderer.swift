import Foundation

public enum UpdatesRenderer {
    public static func humanReadable(_ updates: [UnifiedUpdate]) -> String {
        guard !updates.isEmpty else { return "No cached updates available." }
        let rows = updates.map { [$0.name.terminalInline, "\($0.installedVersion.terminalInline) -> \($0.availableVersion.terminalInline)", $0.provider.terminalInline, $0.scope.terminalInline, $0.selfUpdating ? "self-updating" : ""] }
        let freshness = updates.contains(where: { $0.freshness == .stale }) ? "Snapshot is stale; run 'sift refresh' before comparing." : "Matches the latest cached snapshot."
        let selfUpdatingCount = updates.filter(\.selfUpdating).count
        let header = selfUpdatingCount == 0 ? "Updates  \(updates.count)" : "Updates  \(updates.count - selfUpdatingCount) + \(selfUpdatingCount) self-updating"
        return ([header, freshness, ""] + TableFormatter.rows(rows).map { $0.trimmingTrailingSpaces }).joined(separator: "\n")
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
