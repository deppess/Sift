import CSQLite
import Foundation

/// Homebrew packages, update targets, and release notes.
extension Database {
    public func hasActiveHomebrewPackages() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try scalarInt("SELECT EXISTS(SELECT 1 FROM homebrew_packages WHERE active = 1);") == 1
    }

    func applyHomebrewPackagesLocked(_ inventory: HomebrewInventory, targets: [String: HomebrewTarget], observedAt: Date) throws {
        for package in inventory.packages {
            let target = targets[HomebrewPackageKey(package).stringValue]
            try recordPackageTransition(
                provider: "homebrew", scope: package.prefix, kind: package.kind.rawValue, name: package.fullName, to: package.installedVersion,
                observedAt: observedAt,
                previous: "SELECT installed_version, observed_at FROM homebrew_packages WHERE prefix = ? AND kind = ? AND full_name = ?;",
                bindings: [.text(package.prefix), .text(package.kind.rawValue), .text(package.fullName)])
            try run(
                "INSERT INTO homebrew_packages (prefix, kind, name, full_name, tap, ownership, installed_version, available_version, source_url, observed_at, active, last_seen_at, auto_updates) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?) ON CONFLICT(prefix, kind, full_name) DO UPDATE SET name = excluded.name, tap = excluded.tap, ownership = excluded.ownership, installed_version = excluded.installed_version, available_version = COALESCE(excluded.available_version, homebrew_packages.available_version), source_url = excluded.source_url, observed_at = excluded.observed_at, active = 1, last_seen_at = excluded.last_seen_at, auto_updates = excluded.auto_updates;",
                bindings: [
                    .text(package.prefix), .text(package.kind.rawValue), .text(package.name), .text(package.fullName), .optionalText(package.tap),
                    .text(package.ownership.rawValue), .text(package.installedVersion), .optionalText(target?.version), .optionalText(package.sourceURL),
                    .double(observedAt.timeIntervalSince1970), .double(observedAt.timeIntervalSince1970), .int(package.autoUpdates ? 1 : 0)
                ])
            for path in package.artifactPaths {
                try run(
                    "INSERT INTO cask_artifacts (homebrew_package_id, normalized_path, active, last_seen_at) SELECT id, ?, 1, ? FROM homebrew_packages WHERE prefix = ? AND kind = ? AND full_name = ? ON CONFLICT(homebrew_package_id, normalized_path) DO UPDATE SET active = 1, last_seen_at = excluded.last_seen_at;",
                    bindings: [
                        .text(path), .double(observedAt.timeIntervalSince1970), .text(package.prefix), .text(package.kind.rawValue), .text(package.fullName)
                    ])
            }
        }
        for scope in inventory.prefixes where scope.complete {
            try run(
                "UPDATE homebrew_packages SET active = 0 WHERE prefix = ? AND last_seen_at < ?;",
                bindings: [.text(scope.prefix), .double(observedAt.timeIntervalSince1970)])
            try run(
                "UPDATE cask_artifacts SET active = 0 WHERE homebrew_package_id IN (SELECT id FROM homebrew_packages WHERE prefix = ? AND (active = 0 OR (kind = 'cask' AND last_seen_at = ?))) AND last_seen_at < ?;",
                bindings: [.text(scope.prefix), .double(observedAt.timeIntervalSince1970), .double(observedAt.timeIntervalSince1970)])
        }
    }

    func applyTargetResults(_ results: [HomebrewPackageKey: HomebrewTargetResolution], observedAt: Date) throws {
        for (key, result) in results {
            let status: String
            let target: HomebrewTarget?
            let error: String?
            switch result {
            case let .resolved(value): status = "resolved"; target = value; error = nil
            case let .unsupported(message): status = "unsupported"; target = nil; error = message
            case let .unavailable(message): status = "unavailable"; target = nil; error = message
            case let .transientFailure(message): status = "transientFailure"; target = nil; error = message
            }
            let clearTarget = status == "unsupported" || status == "unavailable"
            // A transient failure (e.g. Homebrew's info and outdated snapshots disagreeing on the
            // installed version mid-refresh) must not overwrite target_status either: preserving it
            // is what keeps a previously resolved update visible in `sift updates`,
            // matching how target_for_installed_version/available_version already preserve their
            // prior values below rather than being cleared by uncertain data.
            let preserveStatus = status == "transientFailure"
            try run(
                "UPDATE homebrew_packages SET target_status = CASE WHEN ? = 1 THEN target_status ELSE ? END, target_source_url = CASE WHEN ? IS NULL THEN target_source_url ELSE ? END, target_for_installed_version = CASE WHEN ? = 1 THEN NULL WHEN ? IS NULL THEN target_for_installed_version ELSE installed_version END, target_last_attempt_at = ?, target_last_success_at = CASE WHEN ? IS NULL THEN target_last_success_at ELSE ? END, target_error = ?, available_version = CASE WHEN ? = 1 THEN NULL WHEN ? IS NULL THEN available_version ELSE ? END WHERE prefix = ? AND kind = ? AND full_name = ?;",
                bindings: [
                    .int(preserveStatus ? 1 : 0),
                    .text(status),
                    .optionalText(target?.sourceURL),
                    .optionalText(target?.sourceURL),
                    .int(clearTarget ? 1 : 0),
                    .optionalText(target?.version),
                    .double(observedAt.timeIntervalSince1970),
                    .optionalText(target?.version),
                    .double(observedAt.timeIntervalSince1970),
                    .optionalText(error.map { String($0.prefix(4_096)) }),
                    .int(clearTarget ? 1 : 0),
                    .optionalText(target?.version),
                    .optionalText(target?.version),
                    .text(key.prefix),
                    .text(key.kind.rawValue),
                    .text(key.fullName)
                ])
        }
    }

    func storeReleaseNotesLocked(_ notes: HomebrewReleaseNotes, prefix: String, kind: HomebrewPackageKind, fetchedAt: Date) throws {
        try run(
            "INSERT INTO homebrew_release_notes (prefix, kind, full_name, installed_version, available_version, content, source_url, coverage, fetched_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(prefix, kind, full_name, installed_version, available_version) DO UPDATE SET content = excluded.content, source_url = excluded.source_url, coverage = excluded.coverage, fetched_at = excluded.fetched_at;",
            bindings: [
                .text(prefix), .text(kind.rawValue), .text(notes.name), .text(notes.installedVersion), .text(notes.availableVersion), .text(notes.content),
                .text(notes.sourceURL), .text(notes.coverage), .double(fetchedAt.timeIntervalSince1970)
            ])
    }

    public func homebrewUpdates(includeAll: Bool = false, now: Date = .now, staleAfter: TimeInterval = 24 * 60 * 60) throws -> [HomebrewUpdate] {
        lock.lock()
        defer { lock.unlock() }
        var updates: [HomebrewUpdate] = []
        let providerStatus = try homebrewProviderStatuses()
        // target_for_installed_version = installed_version guards against the same stale-preserved-
        // target case documented on the dashboard's equivalent count above: without it, a target
        // resolved against a since-superseded installed_version (preserved through a later transient
        // info/outdated mismatch) would be shown as an update for the package's current version.
        //
        // Dependency-only formulae are hidden unless includeAll, matching catalogItems()/apps: a user
        // can't act on e.g. `readline` having an update independent of what depends on it.
        try withStatement(
            """
            SELECT kind, name, full_name, prefix, installed_version, available_version, source_url, auto_updates, ownership, last_seen_at, target_last_success_at, target_status
            FROM homebrew_packages
            WHERE active = 1
              AND available_version IS NOT NULL
              AND available_version != installed_version
              AND target_status = 'resolved'
              AND target_for_installed_version = installed_version
              AND (? = 1 OR ownership IN ('explicitlyRequested', 'installedCask'))
            ORDER BY name COLLATE NOCASE;
            """
        ) { statement in
            try bind(statement, [.int(includeAll ? 1 : 0)])
            while try stepRow(statement) {
                let inventoryAsOf = sqlite3_column_type(statement, 9) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
                let targetAsOf = sqlite3_column_type(statement, 10) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))
                let dataAsOf = [inventoryAsOf, targetAsOf].compactMap { $0 }.min()
                let targetStatus = String(cString: sqlite3_column_text(statement, 11))
                let freshness: Freshness
                if targetStatus == "transientFailure" || providerStatus.contains(where: { $0 != .success }) {
                    freshness = dataAsOf == nil ? .unknown : .stale
                } else if targetStatus != "resolved" || dataAsOf == nil {
                    freshness = .unknown
                } else if now.timeIntervalSince(dataAsOf!) >= staleAfter {
                    freshness = .stale
                } else {
                    freshness = .current
                }
                updates.append(
                    HomebrewUpdate(
                        kind: HomebrewPackageKind(rawValue: String(cString: sqlite3_column_text(statement, 0))) ?? .formula,
                        name: String(cString: sqlite3_column_text(statement, 1)), fullName: String(cString: sqlite3_column_text(statement, 2)),
                        prefix: String(cString: sqlite3_column_text(statement, 3)), installedVersion: String(cString: sqlite3_column_text(statement, 4)),
                        availableVersion: String(cString: sqlite3_column_text(statement, 5)), sourceURL: optionalText(statement, column: 6),
                        autoUpdates: sqlite3_column_int(statement, 7) == 1,
                        ownership: HomebrewOwnership(rawValue: String(cString: sqlite3_column_text(statement, 8))) ?? .dependency, freshness: freshness,
                        dataAsOf: dataAsOf))
            }
        }
        return updates
    }

    func homebrewProviderStatuses() throws -> [ProviderRefreshStatus] {
        let states = try providerStatuses(for: [.homebrewInventory, .homebrewTargets])
        return [.homebrewInventory, .homebrewTargets].map { states[$0] ?? .never }
    }

    // Only exercised directly by tests as a seam for seeding release-note state without running a
    // full refresh; production writes always go through storeReleaseNotesLocked inside applyRefresh's
    // transaction. Not `public`: nothing outside this module has a reason to call it standalone.
    func storeReleaseNotes(_ notes: HomebrewReleaseNotes, prefix: String, kind: HomebrewPackageKind) throws {
        lock.lock(); defer { lock.unlock() }
        try storeReleaseNotesLocked(notes, prefix: prefix, kind: kind, fetchedAt: .now)
    }

    public func homebrewReleaseNotes(prefix: String, kind: HomebrewPackageKind, fullName: String, installedVersion: String, availableVersion: String) throws
        -> HomebrewReleaseNotes?
    {
        lock.lock(); defer { lock.unlock() }
        var result: HomebrewReleaseNotes?
        try withStatement(
            "SELECT full_name, installed_version, available_version, content, source_url, coverage FROM homebrew_release_notes WHERE prefix = ? AND kind = ? AND full_name = ? AND installed_version = ? AND available_version = ? LIMIT 1;"
        ) { statement in
            try bind(statement, [.text(prefix), .text(kind.rawValue), .text(fullName), .text(installedVersion), .text(availableVersion)])
            if try stepRow(statement) {
                result = HomebrewReleaseNotes(
                    name: String(cString: sqlite3_column_text(statement, 0)), installedVersion: String(cString: sqlite3_column_text(statement, 1)),
                    availableVersion: String(cString: sqlite3_column_text(statement, 2)), content: String(cString: sqlite3_column_text(statement, 3)),
                    sourceURL: String(cString: sqlite3_column_text(statement, 4)), coverage: String(cString: sqlite3_column_text(statement, 5)))
            }
        }
        return result
    }
}
