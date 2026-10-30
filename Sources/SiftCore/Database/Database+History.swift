import CSQLite
import Foundation

/// One observed version change of anything Sift tracks.
public struct UpdateLogEntry: Codable, Equatable, Sendable {
    /// What `sift changelog` and `sift show` accept for this item.
    public let selector: String
    public let name: String
    /// Where the item comes from: "app", "homebrew", or a managed provider ("npm-global", "cargo", …).
    public let source: String
    /// An application's bundle path; nil for packages.
    public let path: String?
    public let fromVersion: String
    public let toVersion: String
    public let observedAt: Date
}

/// `sift log`: version changes across every provider, newest first.
extension Database {
    public func updateLog(since: Date? = nil, includeAll: Bool = false) throws -> [UpdateLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = since?.timeIntervalSince1970 ?? 0
        var entries: [(entry: UpdateLogEntry, order: Int64)] = []
        // An app a package manager installed is logged by that package manager instead.
        try withStatement("""
            SELECT COALESCE(installations.display_name, software.display_name), software.bundle_identifier, installations.normalized_path,
                   version_transitions.from_version, version_transitions.to_version, version_transitions.observed_at, version_transitions.id
            FROM version_transitions
            JOIN installations ON installations.id = version_transitions.installation_id
            JOIN software ON software.id = installations.software_id
            WHERE installations.provider = 'native-apps'
              AND version_transitions.observed_at >= ?
              AND (? = 1 OR (installations.classification IN ('user', 'system') AND (\(Self.installationOwnerSQL)) IS NULL));
            """) { statement in
            try bind(statement, [.double(cutoff), .int(includeAll ? 1 : 0)])
            while try stepRow(statement) {
                let name = String(cString: sqlite3_column_text(statement, 0))
                let path = optionalText(statement, column: 2)
                let selector = optionalText(statement, column: 1).map { "app:\($0)" } ?? "app:\(path ?? name)"
                entries.append((UpdateLogEntry(selector: selector, name: name, source: "app", path: path, fromVersion: String(cString: sqlite3_column_text(statement, 3)), toVersion: String(cString: sqlite3_column_text(statement, 4)), observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))), sqlite3_column_int64(statement, 6)))
            }
        }
        // Dependency-only formulae and ports are hidden unless includeAll, as in `sift updates`.
        try withStatement("""
            SELECT transitions.provider, transitions.kind, transitions.name, transitions.from_version, transitions.to_version, transitions.observed_at, transitions.id,
                   COALESCE(brew.name, transitions.name)
            FROM package_transitions AS transitions
            LEFT JOIN homebrew_packages AS brew ON transitions.provider = 'homebrew' AND brew.prefix = transitions.scope AND brew.kind = transitions.kind AND brew.full_name = transitions.name
            LEFT JOIN managed_packages AS managed ON transitions.provider != 'homebrew' AND managed.provider = transitions.provider AND managed.scope = transitions.scope AND managed.name = transitions.name
            WHERE transitions.observed_at >= ?
              AND (? = 1 OR COALESCE(brew.ownership != 'dependency', managed.requested = 1, 1));
            """) { statement in
            try bind(statement, [.double(cutoff), .int(includeAll ? 1 : 0)])
            while try stepRow(statement) {
                let provider = String(cString: sqlite3_column_text(statement, 0))
                let kind = String(cString: sqlite3_column_text(statement, 1))
                let name = String(cString: sqlite3_column_text(statement, 7))
                let selector = provider == "homebrew" ? "\(kind):\(name)" : "\(Self.packageSelectorPrefix(provider)):\(name)"
                entries.append((UpdateLogEntry(selector: selector, name: name, source: provider, path: nil, fromVersion: String(cString: sqlite3_column_text(statement, 3)), toVersion: String(cString: sqlite3_column_text(statement, 4)), observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))), sqlite3_column_int64(statement, 6)))
            }
        }
        return entries.sorted {
            if $0.entry.observedAt != $1.entry.observedAt { return $0.entry.observedAt > $1.entry.observedAt }
            return $0.entry.name.localizedCaseInsensitiveCompare($1.entry.name) == .orderedAscending
        }.map(\.entry)
    }
}
