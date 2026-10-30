import CSQLite
import Foundation

/// Changelogs, kept per catalog selector until that item's changelog is fetched again.
extension Database {
    public struct ChangelogState: Sendable {
        public let status: String
        public let source: String?
        public let sourceURL: String?
        public let detail: String?
        public let fetchedAt: Date
    }

    public func storeChangelog(selector: String, source: String, sourceURL: String?, entries: [ChangelogEntry], fetchedAt: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try run("DELETE FROM changelog_entries WHERE subject = ?;", bindings: [.text(selector)])
            for (position, entry) in entries.enumerated() {
                try run("INSERT INTO changelog_entries (subject, position, version, title, published_at, content, source_url) VALUES (?, ?, ?, ?, ?, ?, ?);", bindings: [.text(selector), .int64(Int64(position)), .text(entry.version), .optionalText(entry.title), .optionalDouble(entry.date?.timeIntervalSince1970), .text(String(entry.content.prefix(262_144))), .optionalText(entry.sourceURL)])
            }
            try run("INSERT INTO changelog_state (subject, status, source, source_url, detail, fetched_at) VALUES (?, 'resolved', ?, ?, NULL, ?) ON CONFLICT(subject) DO UPDATE SET status = 'resolved', source = excluded.source, source_url = excluded.source_url, detail = NULL, fetched_at = excluded.fetched_at;", bindings: [.text(selector), .text(source), .optionalText(sourceURL), .double(fetchedAt.timeIntervalSince1970)])
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Records a lookup that found nothing (`unavailable`) or failed (`failure`); entries already
    /// cached are kept, so a failed refetch still shows the last changelog.
    public func storeChangelogMiss(selector: String, status: String, detail: String, fetchedAt: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        try run("INSERT INTO changelog_state (subject, status, source, source_url, detail, fetched_at) VALUES (?, ?, NULL, NULL, ?, ?) ON CONFLICT(subject) DO UPDATE SET status = excluded.status, detail = excluded.detail, fetched_at = excluded.fetched_at, source = CASE WHEN excluded.status = 'failure' THEN changelog_state.source ELSE NULL END, source_url = CASE WHEN excluded.status = 'failure' THEN changelog_state.source_url ELSE NULL END;", bindings: [.text(selector), .text(status), .text(detail), .double(fetchedAt.timeIntervalSince1970)])
    }

    public func changelogState(selector: String) throws -> ChangelogState? {
        lock.lock()
        defer { lock.unlock() }
        var state: ChangelogState?
        try withStatement("SELECT status, source, source_url, detail, fetched_at FROM changelog_state WHERE subject = ?;") { statement in
            try bind(statement, [.text(selector)])
            if try stepRow(statement) {
                state = ChangelogState(status: String(cString: sqlite3_column_text(statement, 0)), source: optionalText(statement, column: 1), sourceURL: optionalText(statement, column: 2), detail: optionalText(statement, column: 3), fetchedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)))
            }
        }
        return state
    }

    public func changelogEntries(selector: String) throws -> [ChangelogEntry] {
        lock.lock()
        defer { lock.unlock() }
        var entries: [ChangelogEntry] = []
        try withStatement("SELECT version, title, published_at, content, source_url FROM changelog_entries WHERE subject = ? ORDER BY position;") { statement in
            try bind(statement, [.text(selector)])
            while try stepRow(statement) {
                let date = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                entries.append(ChangelogEntry(version: String(cString: sqlite3_column_text(statement, 0)), title: optionalText(statement, column: 1), date: date, content: String(cString: sqlite3_column_text(statement, 3)), sourceURL: optionalText(statement, column: 4)))
            }
        }
        return entries
    }

    /// The source URL Homebrew recorded for a formula or cask.
    public func homebrewSourceURL(prefix: String, kind: HomebrewPackageKind, fullName: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        var url: String?
        try withStatement("SELECT source_url FROM homebrew_packages WHERE prefix = ? AND kind = ? AND full_name = ?;") { statement in
            try bind(statement, [.text(prefix), .text(kind.rawValue), .text(fullName)])
            if try stepRow(statement) { url = optionalText(statement, column: 0) }
        }
        return url
    }
}
