import CSQLite
import Darwin
import Foundation

func validateDatabaseParentDirectory(_ url: URL) throws {
    var status = stat()
    guard lstat(url.path, &status) == 0 else {
        if errno == ENOENT { throw DatabaseError.missingDatabaseDirectory(url) }
        throw DatabaseError.unsafeFilesystemPath(url, message: String(cString: strerror(errno)))
    }
    guard (status.st_mode & S_IFMT) == S_IFDIR else {
        throw DatabaseError.unsafeFilesystemPath(url, message: "parent is not a real directory")
    }
    let mode = status.st_mode
    let isPrivate = status.st_uid == getuid() && (mode & (S_IWGRP | S_IWOTH)) == 0
    guard isPrivate || (mode & S_ISVTX) != 0 else {
        throw DatabaseError.unsafeFilesystemPath(url, message: "parent is writable by other users without the sticky bit")
    }
}

func validateDatabaseFile(_ url: URL) throws {
    var status = stat()
    guard lstat(url.path, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFREG,
          status.st_uid == getuid(),
          status.st_nlink == 1 else {
        throw DatabaseError.invalidDatabasePath(url)
    }
}

private func createOrValidateDatabaseFile(_ url: URL) throws {
    var status = stat()
    if lstat(url.path, &status) == 0 {
        try validateDatabaseFile(url)
        let descriptor = open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw DatabaseError.invalidDatabasePath(url) }
        defer { close(descriptor) }
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1,
              fchmod(descriptor, 0o600) == 0 else {
            throw DatabaseError.invalidDatabasePath(url)
        }
        return
    }
    guard errno == ENOENT else { throw DatabaseError.invalidDatabasePath(url) }
    let descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    if descriptor >= 0 {
        guard fchmod(descriptor, 0o600) == 0 else {
            let error = errno
            close(descriptor)
            throw DatabaseError.sqlite(message: "Unable to secure database file at \(url.path): \(String(cString: strerror(error))).")
        }
        close(descriptor)
        return
    }
    guard errno == EEXIST else {
        throw DatabaseError.sqlite(message: "Unable to create database file at \(url.path): \(String(cString: strerror(errno))).")
    }
    try validateDatabaseFile(url)
}

public enum DatabaseError: Error, LocalizedError {
    case sqlite(message: String)
    case invalidDatabasePath(URL)
    case missingDatabaseDirectory(URL)
    case unsafeFilesystemPath(URL, message: String)
    case unsupportedSchemaVersion(Int)
    case obsoleteSchema
    case refreshInProgress(URL)
    case refreshLockUnavailable(URL, message: String)
    case invalidRefreshInput(String)

    public var errorDescription: String? {
        switch self {
        case let .sqlite(message): message
        case let .invalidDatabasePath(url): "Database path is not a regular file path: \(url.path)"
        case let .missingDatabaseDirectory(url): "Database parent directory does not exist: \(url.path)"
        case let .unsafeFilesystemPath(url, message): "Unsafe filesystem path \(url.path): \(message)"
        case let .unsupportedSchemaVersion(version): "Database schema version \(version) is newer than this version of Sift supports."
        case .obsoleteSchema: "This is an obsolete pre-release Sift database. Remove it and run Sift again."
        case let .refreshInProgress(url): "Another refresh is already running for database: \(url.deletingPathExtension().path)"
        case let .refreshLockUnavailable(url, message): "Unable to acquire the refresh lock for database: \(url.deletingPathExtension().path) (\(message))."
        case let .invalidRefreshInput(message): "Invalid refresh input: \(message)"
        }
    }
}

public final class Database: @unchecked Sendable {
    private static let schemaVersion = 12
    private var handle: OpaquePointer?
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let lock = NSRecursiveLock()
    private var refreshLock: RefreshDatabaseLock?

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    public static func readOnly(url: URL) throws -> Database {
        guard url.isFileURL else { throw DatabaseError.invalidDatabasePath(url) }
        try validateDatabaseParentDirectory(url.deletingLastPathComponent())
        try validateDatabaseFile(url)
        var handle: OpaquePointer?
        // SQLite opens auxiliary journal files independently; validate the final path
        // first because SQLITE_OPEN_NOFOLLOW rejects normal read-only journal access.
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite database."
            sqlite3_close(handle)
            throw DatabaseError.sqlite(message: message)
        }
        guard sqlite3_busy_timeout(handle, 250) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            throw DatabaseError.sqlite(message: message)
        }
        let database = Database(handle: handle)
        do {
            try database.validateExistingSchema()
            return database
        } catch {
            sqlite3_close(handle)
            database.handle = nil
            throw error
        }
    }

    public init(url: URL) throws {
        guard url.isFileURL, !url.hasDirectoryPath else { throw DatabaseError.invalidDatabasePath(url) }
        let parent = url.deletingLastPathComponent()
        try validateDatabaseParentDirectory(parent)
        let refreshLock = try RefreshDatabaseLock(databaseURL: url)

        try createOrValidateDatabaseFile(url)

        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite database."
            sqlite3_close(database)
            throw DatabaseError.sqlite(message: message)
        }

        handle = database
        self.refreshLock = refreshLock
        do {
            guard sqlite3_busy_timeout(database, 5_000) == SQLITE_OK else { throw DatabaseError.sqlite(message: String(cString: sqlite3_errmsg(database))) }
            try execute("PRAGMA foreign_keys = ON;")
            try migrate()
        } catch {
            sqlite3_close(database)
            handle = nil
            self.refreshLock = nil
            throw error
        }
    }

    deinit { sqlite3_close(handle) }

    public func dashboard(now: Date = .now, staleAfter: TimeInterval = 24 * 60 * 60) throws -> Dashboard {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN DEFERRED TRANSACTION;")
        do {
            let session = try latestSession()
            let providerResults = try providerRefreshResults()
            let dataAsOf = providerResults.count == RefreshProvider.allCases.count && providerResults.allSatisfy { $0.dataAsOf != nil } ? providerResults.compactMap(\.dataAsOf).min() : nil
            let nativeAvailableUpdateCount = try scalarInt("""
                SELECT COUNT(DISTINCT installation_id) FROM (
                    SELECT installation_id, authority, is_available,
                        ROW_NUMBER() OVER (PARTITION BY installation_id, authority ORDER BY observed_at DESC, id DESC) AS rank
                    FROM update_availability
                ) WHERE rank = 1 AND is_available = 1;
                """)
            let homebrewAvailableUpdateCount = try scalarInt("""
                SELECT COUNT(*) FROM homebrew_packages
                WHERE active = 1
                  AND available_version IS NOT NULL
                  AND available_version != installed_version
                  AND (target_status IN ('unknown', 'resolved') OR (target_status = 'transientFailure' AND target_for_installed_version = installed_version));
                """)
            let informationalUpdateCount = 0
            let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60).timeIntervalSince1970
            let recentTransitionCount = try scalarInt(
                "SELECT COUNT(DISTINCT installation_id) FROM version_transitions WHERE observed_at >= ? AND observed_at <= ?;",
                bindings: [.double(cutoff), .double(now.timeIntervalSince1970)]
            )
            let failedProviderCount = if let session {
                try scalarInt("SELECT COUNT(*) FROM provider_runs WHERE refresh_session_id = ? AND status = 'failure';", bindings: [.int64(session.id)])
            } else {
                0
            }
            let partialProviderCount = if let session {
                try scalarInt("SELECT COUNT(*) FROM provider_runs WHERE refresh_session_id = ? AND status = 'partial';", bindings: [.int64(session.id)])
            } else {
                0
            }
            try execute("COMMIT;")

            let freshness: Freshness
            if let dataAsOf {
                freshness = now.timeIntervalSince(dataAsOf) >= staleAfter ? .stale : .current
            } else {
                freshness = .unknown
            }
            return Dashboard(
                generatedAt: now,
                lastAttemptAt: session?.finishedAt,
                dataAsOf: dataAsOf,
                freshness: freshness,
                latestRefreshStatus: session?.status ?? .never,
                data: DashboardData(availableUpdateCount: nativeAvailableUpdateCount + homebrewAvailableUpdateCount, informationalUpdateCount: informationalUpdateCount, recentTransitionCount: recentTransitionCount, partialProviderCount: partialProviderCount, failedProviderCount: failedProviderCount, providerResults: providerResults)
            )
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func cachedMetadataResponse(url: String, resourceKind: String) throws -> CachedMetadataResponse? {
        lock.lock()
        defer { lock.unlock() }
        var response: CachedMetadataResponse?
        try withStatement("SELECT status_code, body, etag, last_modified, validated_at, link_header FROM metadata_http_cache WHERE request_url = ? AND resource_kind = ?;") { statement in
            guard sqlite3_bind_text(statement, 1, url, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 2, resourceKind, -1, sqliteTransient) == SQLITE_OK else { throw errorFromHandle() }
            if try stepRow(statement) {
                let body: Data?
                if sqlite3_column_type(statement, 1) == SQLITE_NULL {
                    body = nil
                } else if let bytes = sqlite3_column_blob(statement, 1) {
                    body = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
                } else {
                    body = Data()
                }
                response = CachedMetadataResponse(statusCode: Int(sqlite3_column_int(statement, 0)), body: body, etag: optionalText(statement, column: 2), lastModified: optionalText(statement, column: 3), linkHeader: optionalText(statement, column: 5), validatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)))
            }
        }
        return response
    }

    public func hasActiveHomebrewPackages() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try scalarInt("SELECT EXISTS(SELECT 1 FROM homebrew_packages WHERE active = 1);") == 1
    }

    public func storeMetadataResponse(url: String, resourceKind: String, statusCode: Int, body: Data?, etag: String?, lastModified: String?, validatedAt: Date, linkHeader: String? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        try withStatement("INSERT INTO metadata_http_cache (request_url, resource_kind, status_code, body, etag, last_modified, validated_at, link_header) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(request_url, resource_kind) DO UPDATE SET status_code = excluded.status_code, body = excluded.body, etag = excluded.etag, last_modified = excluded.last_modified, validated_at = excluded.validated_at, link_header = excluded.link_header;") { statement in
            let bodyResult: Int32
            if let body {
                bodyResult = body.isEmpty
                    ? sqlite3_bind_zeroblob(statement, 4, 0)
                    : sqlite3_bind_blob(statement, 4, (body as NSData).bytes, Int32(body.count), sqliteTransient)
            } else {
                bodyResult = sqlite3_bind_null(statement, 4)
            }
            guard sqlite3_bind_text(statement, 1, url, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 2, resourceKind, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_int(statement, 3, Int32(statusCode)) == SQLITE_OK,
                  bodyResult == SQLITE_OK,
                  bindOptionalText(statement, index: 5, value: etag),
                  bindOptionalText(statement, index: 6, value: lastModified),
                  sqlite3_bind_double(statement, 7, validatedAt.timeIntervalSince1970) == SQLITE_OK,
                  bindOptionalText(statement, index: 8, value: linkHeader),
                  sqlite3_step(statement) == SQLITE_DONE else { throw errorFromHandle() }
        }
    }

    public func applyRefresh(_ input: RefreshPersistenceInput) throws -> RefreshSummary {
        lock.lock()
        defer { lock.unlock() }
        try validateRefreshInput(input)
        let status = aggregateRefreshStatus(input.providerResults.map(\.status))
        var added = 0
        var changed = 0
        var unchanged = 0
        var inactive = 0
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            if let latest = try latestSession(), input.finishedAt <= latest.finishedAt {
                throw DatabaseError.invalidRefreshInput("refresh completion is not newer than the latest persisted refresh")
            }
            let sessionID = try insertSession(startedAt: input.startedAt, finishedAt: input.finishedAt, status: status)
            let nativeCounts = try applyNativeInventoryLocked(input.nativeInventory, sessionID: sessionID, observedAt: input.finishedAt)
            added = nativeCounts.added
            changed = nativeCounts.changed
            unchanged = nativeCounts.unchanged
            inactive = nativeCounts.inactive
            let resolvedTargets = Dictionary(uniqueKeysWithValues: input.targetResults.compactMap { key, resolution in
                if case let .resolved(target) = resolution { (key.stringValue, target) } else { nil }
            })
            try applyHomebrewPackagesLocked(input.homebrewInventory, targets: resolvedTargets, observedAt: input.finishedAt)
            try applyTargetResults(input.targetResults, observedAt: input.finishedAt)
            for (key, resolution) in input.releaseNoteResults {
                if case let .resolved(notes) = resolution {
                    try storeReleaseNotesLocked(notes, prefix: key.prefix, kind: key.kind, fetchedAt: input.finishedAt)
                }
            }
            for result in input.providerResults {
                try insertProviderRun(sessionID: sessionID, result: result)
                try updateProviderState(provider: result.provider.rawValue, attemptAt: result.finishedAt, successAt: result.status == .success ? result.dataAsOf ?? result.finishedAt : nil, status: refreshStatus(result.status))
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        let targetCounts = resolutionCounts(input.targetResults.values)
        let noteCounts = resolutionCounts(input.releaseNoteResults.values)
        return RefreshSummary(startedAt: input.startedAt, finishedAt: input.finishedAt, status: status, discoveredCount: input.nativeInventory.applications.count, addedCount: added, changedCount: changed, unchangedCount: unchanged, inactiveCount: inactive, homebrewDiscoveredCount: input.homebrewInventory.packages.count, targetResolvedCount: targetCounts.resolved, targetUnsupportedCount: targetCounts.unsupported, targetFailureCount: targetCounts.failed, releaseNotesFetchedCount: noteCounts.resolved, releaseNotesFailureCount: noteCounts.failed, providerResults: input.providerResults, warningCount: input.providerResults.reduce(0) { $0 + $1.warningCount })
    }

    private func applyNativeInventoryLocked(_ inventory: NativeInventoryResult, sessionID: Int64, observedAt: Date) throws -> (added: Int, changed: Int, unchanged: Int, inactive: Int) {
        var added = 0
        var changed = 0
        var unchanged = 0
        var inactive = 0
        let seenIDs = inventory.candidatePaths.union(inventory.applications.map(\.path))
        for application in inventory.applications {
            let softwareID = try resolveSoftware(application, createdAt: observedAt)
            let installation = try resolveInstallation(application, softwareID: softwareID, observedAt: observedAt)
            if installation.isNew { added += 1 }
            let previous = try latestObservation(for: installation.id)
            try insertObservation(sessionID: sessionID, installationID: installation.id, application: application, observedAt: observedAt)
            if let previous, versionsDiffer(previous, application) {
                changed += 1
                try insertTransition(installationID: installation.id, previous: previous, application: application, observedAt: observedAt)
            } else if !installation.isNew {
                unchanged += 1
            }
        }
        // A partial scan cannot prove an application disappeared.
        if inventory.complete {
            for (id, nativeID) in try activeInstallations(provider: NativeApplicationProvider.identifier, roots: inventory.scannedRoots) where !seenIDs.contains(String(nativeID.dropFirst(5))) {
                try withStatement("UPDATE installations SET active = 0 WHERE id = ?;") { statement in
                    guard sqlite3_bind_int64(statement, 1, id) == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw errorFromHandle() }
                }
                inactive += 1
            }
        }
        return (added, changed, unchanged, inactive)
    }

    private func applyHomebrewPackagesLocked(_ inventory: HomebrewInventory, targets: [String: HomebrewTarget], observedAt: Date) throws {
        for package in inventory.packages {
            let target = targets[HomebrewPackageKey(package).stringValue]
            try withStatement("INSERT INTO homebrew_packages (prefix, kind, name, full_name, tap, ownership, installed_version, available_version, source_url, homepage, observed_at, active, last_seen_at, auto_updates) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?) ON CONFLICT(prefix, kind, full_name) DO UPDATE SET name = excluded.name, tap = excluded.tap, ownership = excluded.ownership, installed_version = excluded.installed_version, available_version = COALESCE(excluded.available_version, homebrew_packages.available_version), source_url = excluded.source_url, homepage = excluded.homepage, observed_at = excluded.observed_at, active = 1, last_seen_at = excluded.last_seen_at, auto_updates = excluded.auto_updates;") { statement in
                guard sqlite3_bind_text(statement, 1, package.prefix, -1, sqliteTransient) == SQLITE_OK,
                      sqlite3_bind_text(statement, 2, package.kind.rawValue, -1, sqliteTransient) == SQLITE_OK,
                      sqlite3_bind_text(statement, 3, package.name, -1, sqliteTransient) == SQLITE_OK,
                      sqlite3_bind_text(statement, 4, package.fullName, -1, sqliteTransient) == SQLITE_OK,
                      bindOptionalText(statement, index: 5, value: package.tap),
                      sqlite3_bind_text(statement, 6, package.ownership.rawValue, -1, sqliteTransient) == SQLITE_OK,
                      sqlite3_bind_text(statement, 7, package.installedVersion, -1, sqliteTransient) == SQLITE_OK,
                      bindOptionalText(statement, index: 8, value: target?.version),
                      bindOptionalText(statement, index: 9, value: package.sourceURL),
                      bindOptionalText(statement, index: 10, value: package.homepage),
                      sqlite3_bind_double(statement, 11, observedAt.timeIntervalSince1970) == SQLITE_OK,
                      sqlite3_bind_double(statement, 12, observedAt.timeIntervalSince1970) == SQLITE_OK,
                      sqlite3_bind_int(statement, 13, package.autoUpdates ? 1 : 0) == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_DONE else { throw errorFromHandle() }
            }
            for path in package.artifactPaths {
                try withStatement("INSERT INTO cask_artifacts (homebrew_package_id, normalized_path, active, last_seen_at) SELECT id, ?, 1, ? FROM homebrew_packages WHERE prefix = ? AND kind = ? AND full_name = ? ON CONFLICT(homebrew_package_id, normalized_path) DO UPDATE SET active = 1, last_seen_at = excluded.last_seen_at;") { statement in
                    guard sqlite3_bind_text(statement, 1, path, -1, sqliteTransient) == SQLITE_OK,
                          sqlite3_bind_double(statement, 2, observedAt.timeIntervalSince1970) == SQLITE_OK,
                          sqlite3_bind_text(statement, 3, package.prefix, -1, sqliteTransient) == SQLITE_OK,
                          sqlite3_bind_text(statement, 4, package.kind.rawValue, -1, sqliteTransient) == SQLITE_OK,
                          sqlite3_bind_text(statement, 5, package.fullName, -1, sqliteTransient) == SQLITE_OK,
                          sqlite3_step(statement) == SQLITE_DONE else { throw errorFromHandle() }
                }
            }
        }
        for scope in inventory.prefixes where scope.complete {
            try withStatement("UPDATE homebrew_packages SET active = 0 WHERE prefix = ? AND last_seen_at < ?;") { statement in
                guard sqlite3_bind_text(statement, 1, scope.prefix, -1, sqliteTransient) == SQLITE_OK,
                      sqlite3_bind_double(statement, 2, observedAt.timeIntervalSince1970) == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_DONE else { throw errorFromHandle() }
            }
            try withStatement("UPDATE cask_artifacts SET active = 0 WHERE homebrew_package_id IN (SELECT id FROM homebrew_packages WHERE prefix = ? AND (active = 0 OR (kind = 'cask' AND last_seen_at = ?))) AND last_seen_at < ?;") { statement in
                guard sqlite3_bind_text(statement, 1, scope.prefix, -1, sqliteTransient) == SQLITE_OK,
                      sqlite3_bind_double(statement, 2, observedAt.timeIntervalSince1970) == SQLITE_OK,
                      sqlite3_bind_double(statement, 3, observedAt.timeIntervalSince1970) == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_DONE else { throw errorFromHandle() }
            }
        }
    }

    private func applyTargetResults(_ results: [HomebrewPackageKey: HomebrewTargetResolution], observedAt: Date) throws {
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
            try withStatement("UPDATE homebrew_packages SET target_status = ?, target_source_url = CASE WHEN ? IS NULL THEN target_source_url ELSE ? END, target_for_installed_version = CASE WHEN ? = 1 THEN NULL WHEN ? IS NULL THEN target_for_installed_version ELSE installed_version END, target_last_attempt_at = ?, target_last_success_at = CASE WHEN ? IS NULL THEN target_last_success_at ELSE ? END, target_error = ?, available_version = CASE WHEN ? = 1 THEN NULL WHEN ? IS NULL THEN available_version ELSE ? END WHERE prefix = ? AND kind = ? AND full_name = ?;") { statement in
                guard sqlite3_bind_text(statement, 1, status, -1, sqliteTransient) == SQLITE_OK,
                      bindOptionalText(statement, index: 2, value: target?.sourceURL),
                      bindOptionalText(statement, index: 3, value: target?.sourceURL),
                      sqlite3_bind_int(statement, 4, clearTarget ? 1 : 0) == SQLITE_OK,
                      bindOptionalText(statement, index: 5, value: target?.version),
                      sqlite3_bind_double(statement, 6, observedAt.timeIntervalSince1970) == SQLITE_OK,
                      bindOptionalText(statement, index: 7, value: target?.version),
                      sqlite3_bind_double(statement, 8, observedAt.timeIntervalSince1970) == SQLITE_OK,
                  bindOptionalText(statement, index: 9, value: error.map { String($0.prefix(4_096)) }),
                      sqlite3_bind_int(statement, 10, clearTarget ? 1 : 0) == SQLITE_OK,
                      bindOptionalText(statement, index: 11, value: target?.version),
                      bindOptionalText(statement, index: 12, value: target?.version),
                      sqlite3_bind_text(statement, 13, key.prefix, -1, sqliteTransient) == SQLITE_OK,
                      sqlite3_bind_text(statement, 14, key.kind.rawValue, -1, sqliteTransient) == SQLITE_OK,
                      sqlite3_bind_text(statement, 15, key.fullName, -1, sqliteTransient) == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_DONE else { throw errorFromHandle() }
            }
        }
    }

    private func storeReleaseNotesLocked(_ notes: HomebrewReleaseNotes, prefix: String, kind: HomebrewPackageKind, fetchedAt: Date) throws {
        try withStatement("INSERT INTO homebrew_release_notes (prefix, kind, full_name, installed_version, available_version, content, source_url, coverage, fetched_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(prefix, kind, full_name, installed_version, available_version) DO UPDATE SET content = excluded.content, source_url = excluded.source_url, coverage = excluded.coverage, fetched_at = excluded.fetched_at;") { statement in
            guard sqlite3_bind_text(statement, 1, prefix, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 2, kind.rawValue, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 3, notes.name, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 4, notes.installedVersion, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 5, notes.availableVersion, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 6, notes.content, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 7, notes.sourceURL, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 8, notes.coverage, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_double(statement, 9, fetchedAt.timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else { throw errorFromHandle() }
        }
    }

    public func catalogItems(includeAll: Bool = false) throws -> [CatalogItem] {
        lock.lock()
        defer { lock.unlock() }
        var items: [CatalogItem] = []
        try withStatement("""
            SELECT software.display_name, software.bundle_identifier, installations.normalized_path,
                   observations.short_version, observations.build_version, installations.active, observations.observed_at
            FROM installations JOIN software ON software.id = installations.software_id
            JOIN observations ON observations.id = (SELECT id FROM observations WHERE installation_id = installations.id ORDER BY observed_at DESC, id DESC LIMIT 1)
            WHERE installations.provider = 'native-apps'
              AND NOT EXISTS (
                  SELECT 1 FROM cask_artifacts
                  JOIN homebrew_packages ON homebrew_packages.id = cask_artifacts.homebrew_package_id
                  WHERE cask_artifacts.active = 1
                    AND homebrew_packages.active = 1
                    AND homebrew_packages.ownership = 'installedCask'
                    AND cask_artifacts.normalized_path = installations.normalized_path
              )
              AND (? = 1 OR (installations.active = 1 AND installations.classification = 'user'));
            """) { statement in
            guard sqlite3_bind_int(statement, 1, includeAll ? 1 : 0) == SQLITE_OK else { throw errorFromHandle() }
            while try stepRow(statement) {
                let name = String(cString: sqlite3_column_text(statement, 0))
                let bundleID = optionalText(statement, column: 1)
                let path = optionalText(statement, column: 2)
                let selector = bundleID.map { "app:\($0)" } ?? "app:\(path ?? name)"
                let version = optionalText(statement, column: 3) ?? optionalText(statement, column: 4)
                items.append(CatalogItem(selector: selector, aliases: [name] + (bundleID.map { [$0] } ?? []), kind: .nativeApp, name: name, fullName: nil, installedVersion: version, availableVersion: nil, active: sqlite3_column_int(statement, 5) == 1, bundleIdentifier: bundleID, path: path, prefix: nil, tap: nil, ownership: nil, autoUpdates: false, observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))))
            }
        }
        try withStatement("""
            SELECT kind, name, full_name, prefix, tap, ownership, installed_version, available_version, auto_updates, active, observed_at
            FROM homebrew_packages
            WHERE (? = 1 OR (active = 1 AND ownership IN ('explicitlyRequested', 'installedCask')));
            """) { statement in
            guard sqlite3_bind_int(statement, 1, includeAll ? 1 : 0) == SQLITE_OK else { throw errorFromHandle() }
            while try stepRow(statement) {
                let kind = HomebrewPackageKind(rawValue: String(cString: sqlite3_column_text(statement, 0))) ?? .formula
                let name = String(cString: sqlite3_column_text(statement, 1))
                let fullName = String(cString: sqlite3_column_text(statement, 2))
                let prefix = String(cString: sqlite3_column_text(statement, 3))
                let selector = "\(kind == .formula ? "formula" : "cask"):\(name)"
                items.append(CatalogItem(selector: selector, aliases: [name, fullName], kind: kind == .formula ? .homebrewFormula : .homebrewCask, name: name, fullName: fullName, installedVersion: String(cString: sqlite3_column_text(statement, 6)), availableVersion: optionalText(statement, column: 7), active: sqlite3_column_int(statement, 9) == 1, bundleIdentifier: nil, path: nil, prefix: prefix, tap: optionalText(statement, column: 4), ownership: String(cString: sqlite3_column_text(statement, 5)), autoUpdates: sqlite3_column_int(statement, 8) == 1, observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))))
            }
        }
        let collisions = Dictionary(grouping: items, by: \CatalogItem.selector)
        return items.map { item in
            guard (collisions[item.selector]?.count ?? 0) > 1, let prefix = item.prefix else { return item }
            return CatalogItem(selector: "\(item.selector)@\(prefix)", aliases: item.aliases, kind: item.kind, name: item.name, fullName: item.fullName, installedVersion: item.installedVersion, availableVersion: item.availableVersion, active: item.active, bundleIdentifier: item.bundleIdentifier, path: item.path, prefix: item.prefix, tap: item.tap, ownership: item.ownership, autoUpdates: item.autoUpdates, observedAt: item.observedAt)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func resolveCatalogItem(_ selector: String, includeAll: Bool = false) throws -> CatalogResolution {
        let items = try catalogItems(includeAll: includeAll)
        let exact = items.filter { $0.selector == selector || $0.aliases.contains(selector) }
        if exact.count == 1 { return .item(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact) }
        let folded = items.filter { $0.name.caseInsensitiveCompare(selector) == .orderedSame || $0.aliases.contains { $0.caseInsensitiveCompare(selector) == .orderedSame } }
        if folded.count == 1 { return .item(folded[0]) }
        return folded.isEmpty ? .missing : .ambiguous(folded)
    }

    public func homebrewUpdates(now: Date = .now, staleAfter: TimeInterval = 24 * 60 * 60) throws -> [HomebrewUpdate] {
        lock.lock()
        defer { lock.unlock() }
        var updates: [HomebrewUpdate] = []
        let providerStatus = try homebrewProviderStatuses()
        try withStatement("SELECT kind, name, full_name, prefix, installed_version, available_version, source_url, auto_updates, ownership, last_seen_at, target_last_success_at, target_status FROM homebrew_packages WHERE active = 1 AND available_version IS NOT NULL AND available_version != installed_version AND target_status = 'resolved' ORDER BY name COLLATE NOCASE;") { statement in
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
                updates.append(HomebrewUpdate(kind: HomebrewPackageKind(rawValue: String(cString: sqlite3_column_text(statement, 0))) ?? .formula, name: String(cString: sqlite3_column_text(statement, 1)), fullName: String(cString: sqlite3_column_text(statement, 2)), prefix: String(cString: sqlite3_column_text(statement, 3)), installedVersion: String(cString: sqlite3_column_text(statement, 4)), availableVersion: String(cString: sqlite3_column_text(statement, 5)), sourceURL: optionalText(statement, column: 6), autoUpdates: sqlite3_column_int(statement, 7) == 1, ownership: HomebrewOwnership(rawValue: String(cString: sqlite3_column_text(statement, 8))) ?? .dependency, freshness: freshness, dataAsOf: dataAsOf))
            }
        }
        return updates
    }

    private func homebrewProviderStatuses() throws -> [ProviderRefreshStatus] {
        var states: [RefreshProvider: ProviderRefreshStatus] = [:]
        try withStatement("SELECT latest_status, provider FROM provider_state WHERE provider IN ('homebrew-inventory', 'homebrew-targets');") { statement in
            while try stepRow(statement) {
                guard let text = sqlite3_column_text(statement, 0),
                      let status = ProviderRefreshStatus(rawValue: String(cString: text)),
                      let providerText = sqlite3_column_text(statement, 1),
                      let provider = RefreshProvider(rawValue: String(cString: providerText)) else { continue }
                states[provider] = status
            }
        }
        return [.homebrewInventory, .homebrewTargets].map { states[$0] ?? .never }
    }

    public func storeReleaseNotes(_ notes: HomebrewReleaseNotes, prefix: String, kind: HomebrewPackageKind) throws {
        lock.lock(); defer { lock.unlock() }
        try withStatement("INSERT INTO homebrew_release_notes (prefix, kind, full_name, installed_version, available_version, content, source_url, coverage, fetched_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(prefix, kind, full_name, installed_version, available_version) DO UPDATE SET content = excluded.content, source_url = excluded.source_url, coverage = excluded.coverage, fetched_at = excluded.fetched_at;") { statement in
            guard sqlite3_bind_text(statement, 1, prefix, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 2, kind.rawValue, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 3, notes.name, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 4, notes.installedVersion, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 5, notes.availableVersion, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 6, notes.content, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 7, notes.sourceURL, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 8, notes.coverage, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_double(statement, 9, Date.now.timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else { throw errorFromHandle() }
        }
    }

    public func homebrewReleaseNotes(prefix: String, kind: HomebrewPackageKind, fullName: String, installedVersion: String, availableVersion: String) throws -> HomebrewReleaseNotes? {
        lock.lock(); defer { lock.unlock() }
        var result: HomebrewReleaseNotes?
        try withStatement("SELECT full_name, installed_version, available_version, content, source_url, coverage FROM homebrew_release_notes WHERE prefix = ? AND kind = ? AND full_name = ? AND installed_version = ? AND available_version = ? LIMIT 1;") { statement in
            guard sqlite3_bind_text(statement, 1, prefix, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 2, kind.rawValue, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 3, fullName, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 4, installedVersion, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 5, availableVersion, -1, sqliteTransient) == SQLITE_OK else { throw errorFromHandle() }
            if try stepRow(statement) { result = HomebrewReleaseNotes(name: String(cString: sqlite3_column_text(statement, 0)), installedVersion: String(cString: sqlite3_column_text(statement, 1)), availableVersion: String(cString: sqlite3_column_text(statement, 2)), content: String(cString: sqlite3_column_text(statement, 3)), sourceURL: String(cString: sqlite3_column_text(statement, 4)), coverage: String(cString: sqlite3_column_text(statement, 5))) }
        }
        return result
    }

    private func resolveSoftware(_ application: NativeApplication, createdAt: Date) throws -> Int64 {
        if let bundleIdentifier = application.bundleIdentifier, let id = try selectID("SELECT id FROM software WHERE bundle_identifier = ?;", text: bundleIdentifier) { return id }
        if application.bundleIdentifier == nil,
           let id = try existingNativeSoftwareID(path: application.path) { return id }
        try withStatement("INSERT INTO software (display_name, bundle_identifier, created_at) VALUES (?, ?, ?);") { statement in
            guard sqlite3_bind_text(statement, 1, application.displayName, -1, sqliteTransient) == SQLITE_OK,
                  bindOptionalText(statement, index: 2, value: application.bundleIdentifier),
                  sqlite3_bind_double(statement, 3, createdAt.timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else { throw errorFromHandle() }
        }
        guard let handle else { throw DatabaseError.sqlite(message: "Database is closed.") }
        return sqlite3_last_insert_rowid(handle)
    }

    private func existingNativeSoftwareID(path: String) throws -> Int64? {
        var id: Int64?
        try withStatement("SELECT software_id FROM installations WHERE provider = 'native-apps' AND native_id = ? LIMIT 1;") { statement in
            guard sqlite3_bind_text(statement, 1, "path:\(path)", -1, sqliteTransient) == SQLITE_OK else { throw errorFromHandle() }
            if try stepRow(statement) { id = sqlite3_column_int64(statement, 0) }
        }
        return id
    }

    private func resolveInstallation(_ application: NativeApplication, softwareID: Int64, observedAt: Date) throws -> (id: Int64, isNew: Bool) {
        let nativeID = "path:\(application.path)"
        if let id = try selectID("SELECT id FROM installations WHERE provider = 'native-apps' AND native_id = ?;", text: nativeID) {
            try withStatement("UPDATE installations SET software_id = ?, path = ?, normalized_path = ?, classification = ?, discovery_root = ?, active = 1, last_seen_at = ? WHERE id = ?;") { statement in
                guard sqlite3_bind_int64(statement, 1, softwareID) == SQLITE_OK,
                      sqlite3_bind_text(statement, 2, application.path, -1, sqliteTransient) == SQLITE_OK,
                      sqlite3_bind_text(statement, 3, application.path, -1, sqliteTransient) == SQLITE_OK,
                      sqlite3_bind_text(statement, 4, application.classification.rawValue, -1, sqliteTransient) == SQLITE_OK,
                      sqlite3_bind_text(statement, 5, application.discoveryRoot, -1, sqliteTransient) == SQLITE_OK,
                      sqlite3_bind_double(statement, 6, observedAt.timeIntervalSince1970) == SQLITE_OK,
                      sqlite3_bind_int64(statement, 7, id) == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_DONE else { throw errorFromHandle() }
            }
            return (id, false)
        }
        try withStatement("INSERT INTO installations (software_id, provider, native_id, path, normalized_path, management_context, created_at, active, last_seen_at, classification, discovery_root) VALUES (?, 'native-apps', ?, ?, ?, 'native', ?, 1, ?, ?, ?);") { statement in
            guard sqlite3_bind_int64(statement, 1, softwareID) == SQLITE_OK,
                  sqlite3_bind_text(statement, 2, nativeID, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 3, application.path, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 4, application.path, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_double(statement, 5, observedAt.timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_bind_double(statement, 6, observedAt.timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_bind_text(statement, 7, application.classification.rawValue, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 8, application.discoveryRoot, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else { throw errorFromHandle() }
        }
        guard let handle else { throw DatabaseError.sqlite(message: "Database is closed.") }
        return (sqlite3_last_insert_rowid(handle), true)
    }

    private func latestObservation(for installationID: Int64) throws -> (shortVersion: String?, buildVersion: String?, providerVersion: String?, observedAt: Date)? {
        var result: (String?, String?, String?, Date)?
        try withStatement("SELECT short_version, build_version, provider_version, observed_at FROM observations WHERE installation_id = ? ORDER BY observed_at DESC, id DESC LIMIT 1;") { statement in
            guard sqlite3_bind_int64(statement, 1, installationID) == SQLITE_OK else { throw errorFromHandle() }
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW { result = (optionalText(statement, column: 0), optionalText(statement, column: 1), optionalText(statement, column: 2), Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))) }
            else if step != SQLITE_DONE { throw errorFromHandle() }
        }
        return result
    }

    private func insertObservation(sessionID: Int64, installationID: Int64, application: NativeApplication, observedAt: Date) throws {
        try withStatement("INSERT INTO observations (refresh_session_id, installation_id, observed_at, short_version, build_version, provider_version) VALUES (?, ?, ?, ?, ?, NULL);") { statement in
            guard sqlite3_bind_int64(statement, 1, sessionID) == SQLITE_OK,
                  sqlite3_bind_int64(statement, 2, installationID) == SQLITE_OK,
                  sqlite3_bind_double(statement, 3, observedAt.timeIntervalSince1970) == SQLITE_OK,
                  bindOptionalText(statement, index: 4, value: application.shortVersion),
                  bindOptionalText(statement, index: 5, value: application.buildVersion),
                  sqlite3_step(statement) == SQLITE_DONE else { throw errorFromHandle() }
        }
    }

    private func versionsDiffer(_ previous: (shortVersion: String?, buildVersion: String?, providerVersion: String?, observedAt: Date), _ application: NativeApplication) -> Bool {
        previous.shortVersion != application.shortVersion || previous.buildVersion != application.buildVersion
    }

    private func insertTransition(installationID: Int64, previous: (shortVersion: String?, buildVersion: String?, providerVersion: String?, observedAt: Date), application: NativeApplication, observedAt: Date) throws {
        let from = versionText(short: previous.shortVersion, build: previous.buildVersion)
        let to = versionText(short: application.shortVersion, build: application.buildVersion)
        try withStatement("INSERT INTO version_transitions (installation_id, from_version, to_version, first_observed_at, observed_at) VALUES (?, ?, ?, ?, ?);") { statement in
            guard sqlite3_bind_int64(statement, 1, installationID) == SQLITE_OK,
                  sqlite3_bind_text(statement, 2, from.isEmpty ? "unknown" : from, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 3, to.isEmpty ? "unknown" : to, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_double(statement, 4, previous.observedAt.timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_bind_double(statement, 5, observedAt.timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else { throw errorFromHandle() }
        }
    }

    private func versionText(short: String?, build: String?) -> String {
        guard let short else { return build ?? "" }
        return build.map { "\(short) (\($0))" } ?? short
    }

    private func activeInstallations(provider: String, roots: [String]) throws -> [(Int64, String)] {
        var result: [(Int64, String)] = []
        guard !roots.isEmpty else { return result }
        let placeholders = Array(repeating: "?", count: roots.count).joined(separator: ",")
        try withStatement("SELECT id, native_id FROM installations WHERE provider = ? AND active = 1 AND discovery_root IN (\(placeholders));") { statement in
            guard sqlite3_bind_text(statement, 1, provider, -1, sqliteTransient) == SQLITE_OK else { throw errorFromHandle() }
            for (offset, root) in roots.enumerated() { guard sqlite3_bind_text(statement, Int32(offset + 2), root, -1, sqliteTransient) == SQLITE_OK else { throw errorFromHandle() } }
            while try stepRow(statement) { result.append((sqlite3_column_int64(statement, 0), String(cString: sqlite3_column_text(statement, 1)))) }
        }
        return result
    }

    private func updateProviderState(provider: String, attemptAt: Date, successAt: Date?, status: RefreshStatus) throws {
        try withStatement("INSERT INTO provider_state (provider, last_attempt_at, last_success_at, latest_status, data_as_of) VALUES (?, ?, ?, ?, ?) ON CONFLICT(provider) DO UPDATE SET last_attempt_at = excluded.last_attempt_at, last_success_at = COALESCE(excluded.last_success_at, provider_state.last_success_at), latest_status = excluded.latest_status, data_as_of = COALESCE(excluded.data_as_of, provider_state.data_as_of);") { statement in
            guard sqlite3_bind_text(statement, 1, provider, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_double(statement, 2, attemptAt.timeIntervalSince1970) == SQLITE_OK,
                  bindOptionalDouble(statement, index: 3, value: successAt?.timeIntervalSince1970),
                  sqlite3_bind_text(statement, 4, status.rawValue, -1, sqliteTransient) == SQLITE_OK,
                  bindOptionalDouble(statement, index: 5, value: successAt?.timeIntervalSince1970),
                  sqlite3_step(statement) == SQLITE_DONE else { throw errorFromHandle() }
        }
    }

    private func migrate() throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY NOT NULL);")
            let version = try scalarInt("SELECT COALESCE(MAX(version), 0) FROM schema_migrations;")
            if version == 1 { throw DatabaseError.obsoleteSchema }
            guard version <= Self.schemaVersion else { throw DatabaseError.unsupportedSchemaVersion(version) }
            if version < 2 {
                try execute("""
                    CREATE TABLE refresh_sessions (
                        id INTEGER PRIMARY KEY,
                        started_at REAL NOT NULL,
                        finished_at REAL NOT NULL,
                        status TEXT NOT NULL CHECK (status IN ('success', 'partial', 'failure'))
                    );
                    CREATE TABLE provider_runs (
                        id INTEGER PRIMARY KEY,
                        refresh_session_id INTEGER NOT NULL REFERENCES refresh_sessions(id),
                        provider TEXT NOT NULL,
                        started_at REAL NOT NULL,
                        finished_at REAL NOT NULL,
                        status TEXT NOT NULL CHECK (status IN ('success', 'failure')),
                        error_message TEXT,
                        UNIQUE(refresh_session_id, provider)
                    );
                    CREATE TABLE settings (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
                    CREATE TABLE software (id INTEGER PRIMARY KEY, display_name TEXT NOT NULL, bundle_identifier TEXT UNIQUE, created_at REAL NOT NULL);
                    CREATE TABLE installations (
                        id INTEGER PRIMARY KEY,
                        software_id INTEGER NOT NULL REFERENCES software(id),
                        provider TEXT NOT NULL,
                        native_id TEXT NOT NULL,
                        path TEXT,
                        management_context TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        UNIQUE(provider, native_id)
                    );
                    CREATE TABLE observations (
                        id INTEGER PRIMARY KEY,
                        refresh_session_id INTEGER NOT NULL REFERENCES refresh_sessions(id),
                        installation_id INTEGER NOT NULL REFERENCES installations(id),
                        observed_at REAL NOT NULL,
                        short_version TEXT,
                        build_version TEXT,
                        provider_version TEXT,
                        UNIQUE(refresh_session_id, installation_id)
                    );
                    CREATE TABLE version_transitions (
                        id INTEGER PRIMARY KEY,
                        installation_id INTEGER NOT NULL REFERENCES installations(id),
                        from_version TEXT NOT NULL,
                        to_version TEXT NOT NULL,
                        first_observed_at REAL NOT NULL,
                        observed_at REAL NOT NULL,
                        UNIQUE(installation_id, from_version, to_version, observed_at)
                    );
                    CREATE TABLE update_availability (
                        id INTEGER PRIMARY KEY,
                        refresh_session_id INTEGER NOT NULL REFERENCES refresh_sessions(id),
                        installation_id INTEGER NOT NULL REFERENCES installations(id),
                        authority TEXT NOT NULL,
                        available_version TEXT,
                        is_available INTEGER NOT NULL CHECK (is_available IN (0, 1)),
                        observed_at REAL NOT NULL,
                        UNIQUE(refresh_session_id, installation_id, authority)
                    );
                    CREATE TABLE release_notes (
                        id INTEGER PRIMARY KEY,
                        software_id INTEGER NOT NULL REFERENCES software(id),
                        target_version TEXT NOT NULL,
                        source TEXT NOT NULL,
                        confidence TEXT NOT NULL CHECK (confidence IN ('exact', 'strong', 'inferred', 'unknown')),
                        source_url TEXT,
                        content TEXT,
                        fetched_at REAL NOT NULL
                    );
                    CREATE INDEX provider_runs_finished_at ON provider_runs(status, finished_at);
                    CREATE INDEX transitions_observed_at ON version_transitions(observed_at, installation_id);
                    CREATE INDEX availability_latest ON update_availability(installation_id, authority, observed_at DESC, id DESC);
                    INSERT INTO schema_migrations (version) VALUES (2);
                    """)
            }
            if version < 3 {
                try execute("""
                    ALTER TABLE installations ADD COLUMN normalized_path TEXT;
                    ALTER TABLE installations ADD COLUMN active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1));
                    ALTER TABLE installations ADD COLUMN last_seen_at REAL;
                    UPDATE installations SET normalized_path = path, last_seen_at = created_at;
                    CREATE INDEX installations_active_provider ON installations(provider, active, normalized_path);
                    CREATE TABLE provider_state (
                        provider TEXT PRIMARY KEY NOT NULL,
                        last_attempt_at REAL,
                        last_success_at REAL,
                        latest_status TEXT NOT NULL CHECK (latest_status IN ('never', 'success', 'partial', 'failure'))
                    );
                    INSERT INTO schema_migrations (version) VALUES (3);
                    """)
            }
            if version < 4 {
                try execute("""
                    ALTER TABLE installations ADD COLUMN classification TEXT NOT NULL DEFAULT 'unknown' CHECK (classification IN ('user', 'system', 'coreService', 'unknown'));
                    ALTER TABLE installations ADD COLUMN discovery_root TEXT NOT NULL DEFAULT '';
                    CREATE INDEX installations_root_active ON installations(provider, discovery_root, active);
                    INSERT INTO schema_migrations (version) VALUES (4);
                    """)
            }
            if version < 5 {
                try execute("""
                    CREATE TABLE homebrew_packages (
                        id INTEGER PRIMARY KEY,
                        prefix TEXT NOT NULL,
                        kind TEXT NOT NULL CHECK (kind IN ('formula', 'cask')),
                        name TEXT NOT NULL,
                        full_name TEXT NOT NULL,
                        tap TEXT,
                        ownership TEXT NOT NULL CHECK (ownership IN ('explicitlyRequested', 'installedCask', 'dependency')),
                        installed_version TEXT NOT NULL,
                        available_version TEXT,
                        source_url TEXT,
                        homepage TEXT,
                        observed_at REAL NOT NULL,
                        UNIQUE(prefix, kind, full_name)
                    );
                    CREATE INDEX homebrew_visible_updates ON homebrew_packages(ownership, available_version, installed_version);
                    INSERT INTO schema_migrations (version) VALUES (5);
                    """)
            }
            if version < 6 {
                try execute("""
                    CREATE TABLE homebrew_release_notes (
                        id INTEGER PRIMARY KEY,
                        prefix TEXT NOT NULL,
                        kind TEXT NOT NULL,
                        full_name TEXT NOT NULL,
                        installed_version TEXT NOT NULL,
                        available_version TEXT NOT NULL,
                        content TEXT NOT NULL,
                        source_url TEXT NOT NULL,
                        coverage TEXT NOT NULL,
                        fetched_at REAL NOT NULL,
                        UNIQUE(prefix, kind, full_name, available_version)
                    );
                    INSERT INTO schema_migrations (version) VALUES (6);
                    """)
            }
            if version < 7 {
                try execute("""
                    ALTER TABLE homebrew_packages ADD COLUMN active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1));
                    ALTER TABLE homebrew_packages ADD COLUMN last_seen_at REAL;
                    UPDATE homebrew_packages SET last_seen_at = observed_at;
                    CREATE TABLE cask_artifacts (
                        id INTEGER PRIMARY KEY,
                        homebrew_package_id INTEGER NOT NULL REFERENCES homebrew_packages(id),
                        normalized_path TEXT NOT NULL,
                        active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
                        last_seen_at REAL NOT NULL,
                        UNIQUE(homebrew_package_id, normalized_path)
                    );
                    CREATE INDEX cask_artifact_paths ON cask_artifacts(normalized_path, active);
                    INSERT INTO schema_migrations (version) VALUES (7);
                    """)
            }
            if version < 8 {
                try execute("""
                    ALTER TABLE homebrew_packages ADD COLUMN auto_updates INTEGER NOT NULL DEFAULT 0 CHECK (auto_updates IN (0, 1));
                    CREATE INDEX homebrew_active_visible_updates ON homebrew_packages(active, ownership, available_version, installed_version);
                    INSERT INTO schema_migrations (version) VALUES (8);
                    """)
            }
            if version < 9 {
                try execute("""
                    CREATE TABLE provider_runs_new (
                        id INTEGER PRIMARY KEY,
                        refresh_session_id INTEGER NOT NULL REFERENCES refresh_sessions(id),
                        provider TEXT NOT NULL,
                        started_at REAL NOT NULL,
                        finished_at REAL NOT NULL,
                        status TEXT NOT NULL CHECK (status IN ('success', 'partial', 'failure')),
                        error_message TEXT,
                        warning_count INTEGER NOT NULL DEFAULT 0,
                        data_as_of REAL,
                        UNIQUE(refresh_session_id, provider)
                    );
                    INSERT INTO provider_runs_new (id, refresh_session_id, provider, started_at, finished_at, status, error_message, warning_count, data_as_of)
                    SELECT id, refresh_session_id, provider, started_at, finished_at, status, error_message, 0,
                        CASE WHEN status = 'success' THEN finished_at ELSE NULL END
                    FROM provider_runs;
                    DROP TABLE provider_runs;
                    ALTER TABLE provider_runs_new RENAME TO provider_runs;
                    CREATE INDEX provider_runs_finished_at ON provider_runs(status, finished_at);
                    ALTER TABLE provider_state ADD COLUMN data_as_of REAL;
                    UPDATE provider_state SET data_as_of = last_success_at;
                    ALTER TABLE homebrew_packages ADD COLUMN target_status TEXT NOT NULL DEFAULT 'unknown' CHECK (target_status IN ('unknown', 'resolved', 'unsupported', 'unavailable', 'transientFailure'));
                    ALTER TABLE homebrew_packages ADD COLUMN target_source_url TEXT;
                    ALTER TABLE homebrew_packages ADD COLUMN target_for_installed_version TEXT;
                    ALTER TABLE homebrew_packages ADD COLUMN target_last_attempt_at REAL;
                    ALTER TABLE homebrew_packages ADD COLUMN target_last_success_at REAL;
                    ALTER TABLE homebrew_packages ADD COLUMN target_error TEXT;
                    UPDATE homebrew_packages
                    SET target_status = CASE WHEN available_version IS NULL THEN 'unknown' ELSE 'resolved' END,
                        target_source_url = source_url,
                        target_for_installed_version = CASE WHEN available_version IS NULL THEN NULL ELSE installed_version END,
                        target_last_success_at = CASE WHEN available_version IS NULL THEN NULL ELSE observed_at END;
                    CREATE INDEX homebrew_actionable_targets ON homebrew_packages(active, ownership, auto_updates, target_status, installed_version, available_version, target_for_installed_version);
                    INSERT INTO schema_migrations (version) VALUES (9);
                    """)
            }
            if version < 10 {
                try execute("""
                    CREATE TABLE metadata_http_cache (
                        request_url TEXT NOT NULL,
                        resource_kind TEXT NOT NULL,
                        status_code INTEGER NOT NULL,
                        body BLOB,
                        etag TEXT,
                        last_modified TEXT,
                        validated_at REAL NOT NULL,
                        PRIMARY KEY (request_url, resource_kind)
                    );
                    INSERT INTO schema_migrations (version) VALUES (10);
                """)
            }
            if version < 11 {
                try execute("""
                    ALTER TABLE metadata_http_cache ADD COLUMN link_header TEXT;
                    CREATE INDEX observations_latest ON observations(installation_id, observed_at DESC, id DESC);
                    INSERT INTO schema_migrations (version) VALUES (11);
                    """)
            }
            if version < 12 {
                try execute("""
                    CREATE TABLE homebrew_release_notes_new (
                        id INTEGER PRIMARY KEY,
                        prefix TEXT NOT NULL,
                        kind TEXT NOT NULL,
                        full_name TEXT NOT NULL,
                        installed_version TEXT NOT NULL,
                        available_version TEXT NOT NULL,
                        content TEXT NOT NULL,
                        source_url TEXT NOT NULL,
                        coverage TEXT NOT NULL,
                        fetched_at REAL NOT NULL,
                        UNIQUE(prefix, kind, full_name, installed_version, available_version)
                    );
                    INSERT INTO homebrew_release_notes_new (id, prefix, kind, full_name, installed_version, available_version, content, source_url, coverage, fetched_at)
                    SELECT id, prefix, kind, full_name, installed_version, available_version, content, source_url, coverage, fetched_at FROM homebrew_release_notes;
                    DROP TABLE homebrew_release_notes;
                    ALTER TABLE homebrew_release_notes_new RENAME TO homebrew_release_notes;
                    INSERT INTO schema_migrations (version) VALUES (12);
                    """)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func validateExistingSchema() throws {
        let version = try scalarInt("SELECT COALESCE(MAX(version), 0) FROM schema_migrations;")
        if version == 1 { throw DatabaseError.obsoleteSchema }
        guard version >= 2, version <= Self.schemaVersion else {
            throw DatabaseError.unsupportedSchemaVersion(version)
        }
    }

    private func validateRefreshInput(_ input: RefreshPersistenceInput) throws {
        guard input.startedAt <= input.finishedAt else { throw DatabaseError.invalidRefreshInput("refresh start is after finish") }
        let providers = input.providerResults.map(\.provider)
        guard providers.count == RefreshProvider.allCases.count, Set(providers) == Set(RefreshProvider.allCases) else {
            throw DatabaseError.invalidRefreshInput("every provider must appear exactly once")
        }
        for result in input.providerResults {
            guard result.startedAt <= result.finishedAt,
                  result.startedAt >= input.startedAt,
                  result.finishedAt <= input.finishedAt,
                  result.warningCount >= 0 else { throw DatabaseError.invalidRefreshInput("invalid timing or warnings for \(result.provider.rawValue)") }
            if result.status == .success, result.dataAsOf == nil { throw DatabaseError.invalidRefreshInput("successful \(result.provider.rawValue) result has no data timestamp") }
            if result.status != .success, result.dataAsOf != nil { throw DatabaseError.invalidRefreshInput("non-successful \(result.provider.rawValue) result has a data timestamp") }
            if let dataAsOf = result.dataAsOf, dataAsOf > result.finishedAt { throw DatabaseError.invalidRefreshInput("data timestamp is after \(result.provider.rawValue) finished") }
        }
        var packages = Set<HomebrewPackageKey>()
        for prefix in input.homebrewInventory.prefixes {
            guard prefix.prefix.hasPrefix("/") else { throw DatabaseError.invalidRefreshInput("Homebrew prefix is not absolute") }
            for package in prefix.packages {
                let key = HomebrewPackageKey(package)
                guard package.prefix == prefix.prefix, packages.insert(key).inserted, !package.name.isEmpty, !package.fullName.isEmpty, !package.installedVersion.isEmpty else { throw DatabaseError.invalidRefreshInput("invalid or duplicate Homebrew package") }
            }
        }
        let expectedTargets = Set(input.homebrewInventory.packages.map(HomebrewPackageKey.init))
        guard Set(input.targetResults.keys) == expectedTargets else { throw DatabaseError.invalidRefreshInput("target results do not match Homebrew packages") }
        guard Set(input.releaseNoteResults.keys).isSubset(of: expectedTargets) else { throw DatabaseError.invalidRefreshInput("release notes contain an unknown package") }
    }

    private func latestSession() throws -> (id: Int64, finishedAt: Date, status: RefreshStatus)? {
        var result: (Int64, Date, RefreshStatus)?
        try withStatement("SELECT id, finished_at, status FROM refresh_sessions ORDER BY finished_at DESC, id DESC LIMIT 1;") { statement in
            if try stepRow(statement), let statusText = sqlite3_column_text(statement, 2), let status = RefreshStatus(rawValue: String(cString: statusText)) {
                result = (sqlite3_column_int64(statement, 0), Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), status)
            }
        }
        return result
    }

    private func providerRefreshResults() throws -> [ProviderRefreshResult] {
        var states: [String: ProviderRefreshResult] = [:]
        try withStatement("SELECT provider, last_attempt_at, last_success_at, latest_status, data_as_of FROM provider_state;") { statement in
            while try stepRow(statement) {
                guard let providerText = sqlite3_column_text(statement, 0),
                      let provider = RefreshProvider(rawValue: String(cString: providerText)),
                      let statusText = sqlite3_column_text(statement, 3),
                      let status = ProviderRefreshStatus(rawValue: String(cString: statusText)) else { continue }
                let attempt = sqlite3_column_type(statement, 1) == SQLITE_NULL ? Date(timeIntervalSince1970: 0) : Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                let dataAsOf = sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                states[provider.rawValue] = ProviderRefreshResult(provider: provider, status: status, startedAt: attempt, finishedAt: attempt, dataAsOf: dataAsOf)
            }
        }
        return RefreshProvider.allCases.map { provider in
            states[provider.rawValue] ?? ProviderRefreshResult(provider: provider, status: .never, startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 0))
        }
    }

    private func insertSession(startedAt: Date, finishedAt: Date, status: RefreshStatus) throws -> Int64 {
        try withStatement("INSERT INTO refresh_sessions (started_at, finished_at, status) VALUES (?, ?, ?);") { statement in
            guard sqlite3_bind_double(statement, 1, startedAt.timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_bind_double(statement, 2, finishedAt.timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_bind_text(statement, 3, status.rawValue, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else { throw errorFromHandle() }
        }
        guard let handle else { throw DatabaseError.sqlite(message: "Database is closed.") }
        return sqlite3_last_insert_rowid(handle)
    }

    private func insertProviderRun(sessionID: Int64, result: ProviderRefreshResult) throws {
        try withStatement("INSERT INTO provider_runs (refresh_session_id, provider, started_at, finished_at, status, error_message, warning_count, data_as_of) VALUES (?, ?, ?, ?, ?, ?, ?, ?);") { statement in
            guard sqlite3_bind_int64(statement, 1, sessionID) == SQLITE_OK,
                  sqlite3_bind_text(statement, 2, result.provider.rawValue, -1, sqliteTransient) == SQLITE_OK,
                  sqlite3_bind_double(statement, 3, result.startedAt.timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_bind_double(statement, 4, result.finishedAt.timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_bind_text(statement, 5, result.status.rawValue, -1, sqliteTransient) == SQLITE_OK,
                  bindOptionalText(statement, index: 6, value: result.message.map { String($0.prefix(4_096)) }),
                  sqlite3_bind_int(statement, 7, Int32(result.warningCount)) == SQLITE_OK,
                  bindOptionalDouble(statement, index: 8, value: result.dataAsOf?.timeIntervalSince1970),
                  sqlite3_step(statement) == SQLITE_DONE else { throw errorFromHandle() }
        }
    }

    private func refreshStatus(_ status: ProviderRefreshStatus) -> RefreshStatus {
        switch status {
        case .never: .failure
        case .success: .success
        case .partial: .partial
        case .failure: .failure
        }
    }

    private func aggregateRefreshStatus(_ statuses: [ProviderRefreshStatus]) -> RefreshStatus {
        if statuses.allSatisfy({ $0 == .success }) { return .success }
        if statuses.contains(where: { $0 == .success || $0 == .partial }) { return .partial }
        return .failure
    }

    private func resolutionCounts(_ results: Dictionary<HomebrewPackageKey, HomebrewTargetResolution>.Values) -> (resolved: Int, unsupported: Int, failed: Int) {
        results.reduce(into: (0, 0, 0)) { counts, result in
            switch result {
            case .resolved: counts.0 += 1
            case .unsupported: counts.1 += 1
            case .transientFailure: counts.2 += 1
            case .unavailable: break
            }
        }
    }

    private func resolutionCounts(_ results: Dictionary<HomebrewPackageKey, HomebrewReleaseNotesResolution>.Values) -> (resolved: Int, unsupported: Int, failed: Int) {
        results.reduce(into: (0, 0, 0)) { counts, result in
            switch result {
            case .resolved: counts.0 += 1
            case .unsupported: counts.1 += 1
            case .transientFailure: counts.2 += 1
            case .unavailable: break
            }
        }
    }

    private enum Binding { case double(TimeInterval), int64(Int64) }

    private func scalarInt(_ sql: String, bindings: [Binding] = []) throws -> Int {
        var value = 0
        try withStatement(sql) { statement in
            for (offset, binding) in bindings.enumerated() {
                let result: Int32
                switch binding { case let .double(value): result = sqlite3_bind_double(statement, Int32(offset + 1), value); case let .int64(value): result = sqlite3_bind_int64(statement, Int32(offset + 1), value) }
                guard result == SQLITE_OK else { throw errorFromHandle() }
            }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw errorFromHandle() }
            value = Int(sqlite3_column_int64(statement, 0))
        }
        return value
    }

    private func execute(_ sql: String) throws {
        guard let handle else { throw DatabaseError.sqlite(message: "Database is closed.") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else { throw DatabaseError.sqlite(message: errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))) }
    }

    private func withStatement(_ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
        guard let handle else { throw DatabaseError.sqlite(message: "Database is closed.") }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { sqlite3_finalize(statement); throw errorFromHandle() }
        defer { sqlite3_finalize(statement) }
        try body(statement)
    }

    private func stepRow(_ statement: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw errorFromHandle()
    }

    private func bindOptionalText(_ statement: OpaquePointer, index: Int32, value: String?) -> Bool {
        value.map { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) == SQLITE_OK } ?? (sqlite3_bind_null(statement, index) == SQLITE_OK)
    }

    private func bindOptionalDouble(_ statement: OpaquePointer, index: Int32, value: Double?) -> Bool {
        value.map { sqlite3_bind_double(statement, index, $0) == SQLITE_OK } ?? (sqlite3_bind_null(statement, index) == SQLITE_OK)
    }

    private func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL, let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private func selectID(_ sql: String, text: String) throws -> Int64? {
        var id: Int64?
        try withStatement(sql) { statement in
            guard sqlite3_bind_text(statement, 1, text, -1, sqliteTransient) == SQLITE_OK else { throw errorFromHandle() }
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW { id = sqlite3_column_int64(statement, 0) }
            else if step != SQLITE_DONE { throw errorFromHandle() }
        }
        return id
    }

    private func errorFromHandle() -> DatabaseError {
        guard let handle else { return .sqlite(message: "Database is closed.") }
        return .sqlite(message: String(cString: sqlite3_errmsg(handle)))
    }
}
