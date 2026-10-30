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

    /// Adds a fetch to the item's history: new versions are inserted, versions already known get
    /// the source's current text (unless it is now only a placeholder), and versions the source no
    /// longer lists are kept.
    public func storeChangelog(selector: String, source: String, sourceURL: String?, entries: [ChangelogEntry], fetchedAt: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        // Two entries for one version (a rebuild listed separately) become one.
        var merged: [ChangelogEntry] = []
        for entry in entries {
            if let index = merged.firstIndex(where: { $0.version == entry.version }) {
                let first = merged[index]
                merged[index] = ChangelogEntry(version: first.version, title: first.title ?? entry.title, date: first.date ?? entry.date, content: [first.content, entry.content].filter { !$0.isEmpty }.joined(separator: "\n\n"), sourceURL: first.sourceURL ?? entry.sourceURL)
            } else {
                merged.append(entry)
            }
        }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try run("UPDATE changelog_history SET position = NULL WHERE subject = ?;", bindings: [.text(selector)])
            for (position, entry) in merged.enumerated() {
                let placeholder = ChangelogDocument.isPlaceholder(entry.content)
                try run("""
                    INSERT INTO changelog_history (subject, version, title, published_at, content, source_url, source, position, first_seen_at, last_seen_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(subject, version) DO UPDATE SET
                        title = CASE WHEN ?11 = 1 THEN COALESCE(excluded.title, changelog_history.title) ELSE excluded.title END,
                        published_at = COALESCE(excluded.published_at, changelog_history.published_at),
                        content = CASE WHEN ?11 = 1 AND changelog_history.content != '' THEN changelog_history.content ELSE excluded.content END,
                        source_url = COALESCE(excluded.source_url, changelog_history.source_url),
                        source = excluded.source,
                        position = excluded.position,
                        last_seen_at = excluded.last_seen_at;
                    """, bindings: [.text(selector), .text(entry.version), .optionalText(entry.title), .optionalDouble(entry.date?.timeIntervalSince1970), .text(String(entry.content.prefix(262_144))), .optionalText(entry.sourceURL), .text(source), .int64(Int64(position)), .double(fetchedAt.timeIntervalSince1970), .double(fetchedAt.timeIntervalSince1970), .int(placeholder ? 1 : 0)])
            }
            // What a better reading has replaced: placeholder text, and posts without a version
            // (a blog feed read by mistake) once the item has a versioned changelog.
            var stale: [String] = []
            let versioned = merged.contains { ChangelogVersion.token(in: $0.version) == $0.version }
            try withStatement("SELECT version, content FROM changelog_history WHERE subject = ? AND position IS NULL;") { statement in
                try bind(statement, [.text(selector)])
                while try stepRow(statement) {
                    let version = String(cString: sqlite3_column_text(statement, 0))
                    if ChangelogDocument.isPlaceholder(String(cString: sqlite3_column_text(statement, 1))) || versioned && ChangelogVersion.token(in: version) != version { stale.append(version) }
                }
            }
            for version in stale { try run("DELETE FROM changelog_history WHERE subject = ? AND version = ?;", bindings: [.text(selector), .text(version)]) }
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

    /// The item's whole known history, newest first: versioned entries by version, others
    /// (Steam announcements) by date, then by their place in the latest fetch.
    public func changelogEntries(selector: String) throws -> [ChangelogEntry] {
        lock.lock()
        defer { lock.unlock() }
        var rows: [(entry: ChangelogEntry, position: Int64?, firstSeen: Double)] = []
        try withStatement("SELECT version, title, published_at, content, source_url, position, first_seen_at FROM changelog_history WHERE subject = ?;") { statement in
            try bind(statement, [.text(selector)])
            while try stepRow(statement) {
                let date = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                let position = sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 5)
                rows.append((ChangelogEntry(version: String(cString: sqlite3_column_text(statement, 0)), title: optionalText(statement, column: 1), date: date, content: String(cString: sqlite3_column_text(statement, 3)), sourceURL: optionalText(statement, column: 4)), position, sqlite3_column_double(statement, 6)))
            }
        }
        return rows.sorted { left, right in
            // A year-numbered version ("2024.2.2") against a plain one ("26.1.7") is ordered by date.
            func yearNumbered(_ version: String) -> Bool { (Int(version.prefix { $0.isNumber }) ?? 0) >= 1990 }
            if let a = left.entry.date, let b = right.entry.date, a != b, yearNumbered(left.entry.version) != yearNumbered(right.entry.version) { return a > b }
            if let a = ChangelogVersion.token(in: left.entry.version), let b = ChangelogVersion.token(in: right.entry.version), a == left.entry.version, b == right.entry.version {
                let order = SparkleVersion.compare(a, b)
                if order != .orderedSame { return order == .orderedDescending }
            }
            if let a = left.entry.date, let b = right.entry.date, a != b { return a > b }
            switch (left.position, right.position) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left.firstSeen > right.firstSeen
            }
        }.map(\.entry)
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
