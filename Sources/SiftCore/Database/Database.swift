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
    case needsMigration
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
        case .needsMigration: "The Sift database was written by an earlier version; run 'sift refresh' to upgrade it."
        case let .refreshInProgress(url): "Another refresh is already running for database: \(url.deletingPathExtension().path)"
        case let .refreshLockUnavailable(url, message): "Unable to acquire the refresh lock for database: \(url.deletingPathExtension().path) (\(message))."
        case let .invalidRefreshInput(message): "Invalid refresh input: \(message)"
        }
    }
}

public final class Database: @unchecked Sendable {
    static let schemaVersion = 16
    /// The 1.0.0 schema every database starts from; later versions are applied as steps on top.
    static let baselineSchemaVersion = 15
    var handle: OpaquePointer?
    let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let lock = NSRecursiveLock()
    var refreshLock: RefreshDatabaseLock?

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    public static func readOnly(url: URL) throws -> Database {
        guard url.isFileURL else { throw DatabaseError.invalidDatabasePath(url) }
        try validateDatabaseParentDirectory(url.deletingLastPathComponent())
        try validateDatabaseFile(url)
        do {
            return try openReadOnlyRecreatingSidecars(url: url)
        } catch DatabaseError.needsMigration {
            // A cache written by an earlier 1.x release is upgraded in place on first use, so
            // installing a new version never makes the cache-only commands fail until a refresh.
            try upgrade(url: url)
            return try openReadOnlyRecreatingSidecars(url: url)
        }
    }

    private static func openReadOnlyRecreatingSidecars(url: URL) throws -> Database {
        do {
            return try openReadOnly(url: url)
        } catch DatabaseError.needsMigration {
            throw DatabaseError.needsMigration
        } catch {
            // A read-only connection cannot create the WAL index (-shm) itself, so once any other
            // SQLite client closes the database last and deletes the -wal/-shm files, every
            // cache-only command would fail with "unable to open database file" until the next
            // refresh. Recreating them changes no database content.
            guard !walSidecarsExist(url) else { throw error }
            try createWALSidecars(url: url)
            return try openReadOnly(url: url)
        }
    }

    /// Applies pending schema steps without taking the refresh lock: migrate() runs in an
    /// immediate transaction, so it is safe alongside a running refresh.
    static func upgrade(url: URL) throws {
        let database = try writer(url: url)
        try database.migrate()
    }

    /// A read-write connection for writes outside a refresh (changelogs fetched on demand). It
    /// never takes the refresh lock; SQLite's own locking orders it against a running refresh.
    public static func writer(url: URL) throws -> Database {
        guard url.isFileURL else { throw DatabaseError.invalidDatabasePath(url) }
        try validateDatabaseParentDirectory(url.deletingLastPathComponent())
        try validateDatabaseFile(url)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite database."
            sqlite3_close(handle)
            throw DatabaseError.sqlite(message: message)
        }
        let database = Database(handle: handle)
        var persist: Int32 = 1
        _ = sqlite3_file_control(handle, "main", SQLITE_FCNTL_PERSIST_WAL, &persist)
        guard sqlite3_busy_timeout(handle, 5_000) == SQLITE_OK else { throw DatabaseError.sqlite(message: String(cString: sqlite3_errmsg(handle))) }
        try database.execute("PRAGMA foreign_keys = ON;")
        try database.migrate()
        return database
    }

    static func walSidecarsExist(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path + "-wal") && FileManager.default.fileExists(atPath: url.path + "-shm")
    }

    static func createWALSidecars(url: URL) throws {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            throw DatabaseError.sqlite(message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite database.")
        }
        // Keep the files after this connection closes; otherwise closing it deletes them again.
        var persist: Int32 = 1
        _ = sqlite3_file_control(handle, "main", SQLITE_FCNTL_PERSIST_WAL, &persist)
        guard sqlite3_exec(handle, "PRAGMA schema_version;", nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.sqlite(message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    static func openReadOnly(url: URL) throws -> Database {
        var handle: OpaquePointer?
        // SQLite opens auxiliary journal files independently; validate the final path
        // first because SQLITE_OPEN_NOFOLLOW rejects normal read-only journal access.
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite database."
            sqlite3_close(handle)
            throw DatabaseError.sqlite(message: message)
        }
        // 2s, not 250ms: WAL (enabled on the write connection below) means readers normally don't
        // block on a writer at all, but a writer mid-checkpoint or another process's write can still
        // hold things up briefly, and this connection is used by every cache-only command (sift
        // apps/updates/show/changes) that can run concurrently with a 10+ second `sift refresh`.
        guard sqlite3_busy_timeout(handle, 2_000) == SQLITE_OK else {
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
            // WAL lets readers (sift apps/updates/show/changes) see a consistent snapshot without
            // blocking on this connection's writes at all, instead of the default rollback-journal
            // mode where a writer holding the lock blocks every reader outright. This is a
            // database-level setting persisted in the file itself, so it only needs to be set here.
            try execute("PRAGMA journal_mode = WAL;")
            // Leave -wal/-shm in place when this connection closes, so the next read-only open
            // doesn't have to recreate them (see readOnly(url:)).
            var persist: Int32 = 1
            _ = sqlite3_file_control(database, "main", SQLITE_FCNTL_PERSIST_WAL, &persist)
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
            for inventory in input.managedPackageInventories { try applyManagedPackageInventoryLocked(inventory, observedAt: input.finishedAt) }
            try applyNativeUpdateChecksLocked(input.nativeUpdateChecks, sessionID: sessionID, observedAt: input.finishedAt)
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
            try pruneHistoryLocked(now: input.finishedAt)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        let targetCounts = resolutionCounts(input.targetResults.values)
        let noteCounts = resolutionCounts(input.releaseNoteResults.values)
        return RefreshSummary(startedAt: input.startedAt, finishedAt: input.finishedAt, status: status, discoveredCount: input.nativeInventory.applications.count, addedCount: added, changedCount: changed, unchangedCount: unchanged, inactiveCount: inactive, homebrewDiscoveredCount: input.homebrewInventory.packages.count, targetResolvedCount: targetCounts.resolved, targetUnsupportedCount: targetCounts.unsupported, targetFailureCount: targetCounts.failed, releaseNotesFetchedCount: noteCounts.resolved, releaseNotesFailureCount: noteCounts.failed, providerResults: input.providerResults, warningCount: input.providerResults.reduce(0) { $0 + $1.warningCount })
    }

    /// Every query reads only an installation's latest observation and update check (version
    /// history lives in version_transitions), so older rows are dropped instead of growing by one
    /// per app on every refresh. Provider runs are kept for the last 20 refreshes, and cached
    /// metadata and release notes that nothing has used in a while are dropped to be fetched again
    /// if needed.
    func pruneHistoryLocked(now: Date) throws {
        let day: TimeInterval = 24 * 60 * 60
        try execute("""
            DELETE FROM observations WHERE id NOT IN (SELECT MAX(id) FROM observations GROUP BY installation_id);
            DELETE FROM update_availability WHERE id NOT IN (SELECT MAX(id) FROM update_availability GROUP BY installation_id);
            DELETE FROM provider_runs WHERE refresh_session_id NOT IN (SELECT id FROM refresh_sessions ORDER BY id DESC LIMIT 20);
            DELETE FROM refresh_sessions
            WHERE id NOT IN (SELECT refresh_session_id FROM provider_runs)
              AND id NOT IN (SELECT refresh_session_id FROM observations)
              AND id NOT IN (SELECT refresh_session_id FROM update_availability);
            """)
        try run("DELETE FROM metadata_http_cache WHERE validated_at < ?;", bindings: [.double(now.addingTimeInterval(-30 * day).timeIntervalSince1970)])
        try run("DELETE FROM release_notes WHERE fetched_at < ?;", bindings: [.double(now.addingTimeInterval(-90 * day).timeIntervalSince1970)])
        try run("DELETE FROM homebrew_release_notes WHERE fetched_at < ?;", bindings: [.double(now.addingTimeInterval(-90 * day).timeIntervalSince1970)])
    }

    func updateProviderState(provider: String, attemptAt: Date, successAt: Date?, status: RefreshStatus) throws {
        try run("INSERT INTO provider_state (provider, last_attempt_at, last_success_at, latest_status, data_as_of) VALUES (?, ?, ?, ?, ?) ON CONFLICT(provider) DO UPDATE SET last_attempt_at = excluded.last_attempt_at, last_success_at = COALESCE(excluded.last_success_at, provider_state.last_success_at), latest_status = excluded.latest_status, data_as_of = COALESCE(excluded.data_as_of, provider_state.data_as_of);", bindings: [.text(provider), .double(attemptAt.timeIntervalSince1970), .optionalDouble(successAt?.timeIntervalSince1970), .text(status.rawValue), .optionalDouble(successAt?.timeIntervalSince1970)])
    }

    /// 1.0.0 replaced the pre-release migration history with a single baseline at
    /// `baselineSchemaVersion`; each later version is a step applied on top of it, so 1.x caches
    /// keep their history. Pre-release databases (any stored version below the baseline) are
    /// intentionally unsupported: remove the old cache and run `sift refresh` again.
    func migrate() throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY NOT NULL);")
            var version = try scalarInt("SELECT COALESCE(MAX(version), 0) FROM schema_migrations;")
            if version == Self.schemaVersion {
                try execute("COMMIT;")
                return
            }
            guard version <= Self.schemaVersion else { throw DatabaseError.unsupportedSchemaVersion(version) }
            guard version == 0 || version >= Self.baselineSchemaVersion else { throw DatabaseError.obsoleteSchema }
            if version == 0 {
                try createBaselineSchema()
                version = Self.baselineSchemaVersion
            }
            if version < 16 {
                try execute(Self.schema16)
                version = 16
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Version history for Homebrew and managed packages (native apps keep theirs in
    /// version_transitions), each managed package's provider identifier (a Steam app ID), and
    /// changelogs, which are kept until the item they describe is fetched again.
    static let schema16 = """
        CREATE TABLE package_transitions (
            id INTEGER PRIMARY KEY,
            provider TEXT NOT NULL,
            scope TEXT NOT NULL,
            kind TEXT NOT NULL,
            name TEXT NOT NULL,
            from_version TEXT NOT NULL,
            to_version TEXT NOT NULL,
            first_observed_at REAL NOT NULL,
            observed_at REAL NOT NULL
        );
        CREATE INDEX package_transitions_observed_at ON package_transitions(observed_at);
        ALTER TABLE managed_packages ADD COLUMN identifier TEXT;
        CREATE TABLE changelog_entries (
            subject TEXT NOT NULL,
            position INTEGER NOT NULL,
            version TEXT NOT NULL,
            title TEXT,
            published_at REAL,
            content TEXT NOT NULL,
            source_url TEXT,
            PRIMARY KEY (subject, position)
        );
        CREATE TABLE changelog_state (
            subject TEXT PRIMARY KEY NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('resolved', 'unavailable', 'failure')),
            source TEXT,
            source_url TEXT,
            detail TEXT,
            fetched_at REAL NOT NULL
        );
        INSERT INTO schema_migrations (version) VALUES (16);
        """

    private func createBaselineSchema() throws {
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
                    status TEXT NOT NULL CHECK (status IN ('success', 'partial', 'failure')),
                    error_message TEXT,
                    warning_count INTEGER NOT NULL DEFAULT 0,
                    data_as_of REAL,
                    UNIQUE(refresh_session_id, provider)
                );
                CREATE INDEX provider_runs_finished_at ON provider_runs(status, finished_at);
                CREATE INDEX provider_runs_provider ON provider_runs(provider, id);
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
                    normalized_path TEXT,
                    active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
                    last_seen_at REAL,
                    classification TEXT NOT NULL DEFAULT 'unknown' CHECK (classification IN ('user', 'system', 'coreService', 'auxiliary', 'launcher', 'unknown')),
                    discovery_root TEXT NOT NULL DEFAULT '',
                    display_name TEXT,
                    update_authority TEXT NOT NULL DEFAULT 'unknown' CHECK (update_authority IN ('appStore', 'sparkle', 'steam', 'apple', 'blackmagic', 'setapp', 'electron', 'unknown')),
                    UNIQUE(provider, native_id)
                );
                CREATE INDEX installations_active_provider ON installations(provider, active, normalized_path);
                CREATE INDEX installations_root_active ON installations(provider, discovery_root, active);
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
                CREATE INDEX observations_latest ON observations(installation_id, observed_at DESC, id DESC);
                CREATE TABLE version_transitions (
                    id INTEGER PRIMARY KEY,
                    installation_id INTEGER NOT NULL REFERENCES installations(id),
                    from_version TEXT NOT NULL,
                    to_version TEXT NOT NULL,
                    first_observed_at REAL NOT NULL,
                    observed_at REAL NOT NULL,
                    UNIQUE(installation_id, from_version, to_version, observed_at)
                );
                CREATE INDEX transitions_observed_at ON version_transitions(observed_at, installation_id);
                CREATE TABLE update_availability (
                    id INTEGER PRIMARY KEY,
                    refresh_session_id INTEGER NOT NULL REFERENCES refresh_sessions(id),
                    installation_id INTEGER NOT NULL REFERENCES installations(id),
                    authority TEXT NOT NULL,
                    available_version TEXT,
                    is_available INTEGER NOT NULL CHECK (is_available IN (0, 1)),
                    observed_at REAL NOT NULL,
                    installed_version_key TEXT NOT NULL,
                    detail TEXT,
                    UNIQUE(refresh_session_id, installation_id, authority)
                );
                CREATE INDEX availability_latest ON update_availability(installation_id, authority, observed_at DESC, id DESC);
                CREATE TABLE release_notes (
                    id INTEGER PRIMARY KEY,
                    software_id INTEGER NOT NULL REFERENCES software(id),
                    target_version TEXT NOT NULL,
                    source TEXT NOT NULL,
                    confidence TEXT NOT NULL CHECK (confidence IN ('exact', 'strong', 'inferred', 'unknown')),
                    source_url TEXT,
                    content TEXT,
                    fetched_at REAL NOT NULL,
                    UNIQUE(software_id, target_version, source)
                );
                CREATE TABLE provider_state (
                    provider TEXT PRIMARY KEY NOT NULL,
                    last_attempt_at REAL,
                    last_success_at REAL,
                    latest_status TEXT NOT NULL CHECK (latest_status IN ('never', 'success', 'partial', 'failure')),
                    data_as_of REAL
                );
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
                    observed_at REAL NOT NULL,
                    active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
                    last_seen_at REAL,
                    auto_updates INTEGER NOT NULL DEFAULT 0 CHECK (auto_updates IN (0, 1)),
                    target_status TEXT NOT NULL DEFAULT 'unknown' CHECK (target_status IN ('unknown', 'resolved', 'unsupported', 'unavailable', 'transientFailure')),
                    target_source_url TEXT,
                    target_for_installed_version TEXT,
                    target_last_attempt_at REAL,
                    target_last_success_at REAL,
                    target_error TEXT,
                    UNIQUE(prefix, kind, full_name)
                );
                CREATE INDEX homebrew_active_visible_updates ON homebrew_packages(active, ownership, available_version, installed_version);
                CREATE INDEX homebrew_actionable_targets ON homebrew_packages(active, ownership, auto_updates, target_status, installed_version, available_version, target_for_installed_version);
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
                    UNIQUE(prefix, kind, full_name, installed_version, available_version)
                );
                CREATE TABLE cask_artifacts (
                    id INTEGER PRIMARY KEY,
                    homebrew_package_id INTEGER NOT NULL REFERENCES homebrew_packages(id),
                    normalized_path TEXT NOT NULL,
                    active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
                    last_seen_at REAL NOT NULL,
                    UNIQUE(homebrew_package_id, normalized_path)
                );
                CREATE INDEX cask_artifact_paths ON cask_artifacts(normalized_path, active);
                CREATE TABLE metadata_http_cache (
                    request_url TEXT NOT NULL,
                    resource_kind TEXT NOT NULL,
                    status_code INTEGER NOT NULL,
                    body BLOB,
                    etag TEXT,
                    last_modified TEXT,
                    validated_at REAL NOT NULL,
                    link_header TEXT,
                    PRIMARY KEY (request_url, resource_kind)
                );
                CREATE TABLE managed_packages (
                    id INTEGER PRIMARY KEY,
                    provider TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    name TEXT NOT NULL,
                    installed_version TEXT NOT NULL,
                    available_version TEXT,
                    active INTEGER NOT NULL CHECK (active IN (0, 1)),
                    observed_at REAL NOT NULL,
                    last_seen_at REAL NOT NULL,
                    requested INTEGER NOT NULL DEFAULT 1 CHECK (requested IN (0, 1)),
                    self_updating INTEGER NOT NULL DEFAULT 0 CHECK (self_updating IN (0, 1)),
                    UNIQUE(provider, scope, name)
                );
                CREATE INDEX managed_package_updates ON managed_packages(active, available_version, installed_version);
                CREATE TABLE managed_artifacts (
                    managed_package_id INTEGER NOT NULL REFERENCES managed_packages(id) ON DELETE CASCADE,
                    normalized_path TEXT NOT NULL,
                    PRIMARY KEY (managed_package_id, normalized_path)
                );
                CREATE INDEX managed_artifacts_path ON managed_artifacts(normalized_path);
                INSERT INTO schema_migrations (version) VALUES (\(Self.baselineSchemaVersion));
                """)
    }

    func validateExistingSchema() throws {
        let version = try scalarInt("SELECT COALESCE(MAX(version), 0) FROM schema_migrations;")
        guard version <= Self.schemaVersion else { throw DatabaseError.unsupportedSchemaVersion(version) }
        guard version >= Self.baselineSchemaVersion else { throw DatabaseError.obsoleteSchema }
        guard version == Self.schemaVersion else { throw DatabaseError.needsMigration }
    }

    func validateRefreshInput(_ input: RefreshPersistenceInput) throws {
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
        let managedProviders = input.managedPackageInventories.map(\.provider)
        guard Set(managedProviders).count == managedProviders.count,
              managedProviders.allSatisfy(RefreshProvider.managedPackageProviders.contains) else {
            throw DatabaseError.invalidRefreshInput("invalid managed package provider inventory")
        }
        let statuses = Dictionary(uniqueKeysWithValues: input.providerResults.map { ($0.provider, $0.status) })
        guard managedProviders.allSatisfy({ statuses[$0] == .success || statuses[$0] == .partial }) else {
            throw DatabaseError.invalidRefreshInput("managed package inventory requires a successful or partial provider result")
        }
        var packages = Set<HomebrewPackageKey>()
        for prefix in input.homebrewInventory.prefixes {
            guard prefix.prefix.hasPrefix("/") else { throw DatabaseError.invalidRefreshInput("Homebrew prefix is not absolute") }
            for package in prefix.packages {
                let key = HomebrewPackageKey(package)
                guard package.prefix == prefix.prefix, packages.insert(key).inserted, !package.name.isEmpty, !package.fullName.isEmpty, !package.installedVersion.isEmpty else { throw DatabaseError.invalidRefreshInput("invalid or duplicate Homebrew package") }
            }
        }
        let inventoriedPaths = Set(input.nativeInventory.applications.map(\.path))
        guard input.nativeUpdateChecks.allSatisfy({ inventoriedPaths.contains($0.path) }), Set(input.nativeUpdateChecks.map(\.path)).count == input.nativeUpdateChecks.count else {
            throw DatabaseError.invalidRefreshInput("native update checks must name distinct inventoried applications")
        }
        let expectedTargets = Set(input.homebrewInventory.packages.map(HomebrewPackageKey.init))
        guard Set(input.targetResults.keys) == expectedTargets else { throw DatabaseError.invalidRefreshInput("target results do not match Homebrew packages") }
        guard Set(input.releaseNoteResults.keys).isSubset(of: expectedTargets) else { throw DatabaseError.invalidRefreshInput("release notes contain an unknown package") }
    }

    func latestSession() throws -> (id: Int64, finishedAt: Date, status: RefreshStatus)? {
        var result: (Int64, Date, RefreshStatus)?
        try withStatement("SELECT id, finished_at, status FROM refresh_sessions ORDER BY finished_at DESC, id DESC LIMIT 1;") { statement in
            if try stepRow(statement), let statusText = sqlite3_column_text(statement, 2), let status = RefreshStatus(rawValue: String(cString: statusText)) {
                result = (sqlite3_column_int64(statement, 0), Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), status)
            }
        }
        return result
    }

    func insertSession(startedAt: Date, finishedAt: Date, status: RefreshStatus) throws -> Int64 {
        try run("INSERT INTO refresh_sessions (started_at, finished_at, status) VALUES (?, ?, ?);", bindings: [.double(startedAt.timeIntervalSince1970), .double(finishedAt.timeIntervalSince1970), .text(status.rawValue)])
        guard let handle else { throw DatabaseError.sqlite(message: "Database is closed.") }
        return sqlite3_last_insert_rowid(handle)
    }

    func insertProviderRun(sessionID: Int64, result: ProviderRefreshResult) throws {
        try run("INSERT INTO provider_runs (refresh_session_id, provider, started_at, finished_at, status, error_message, warning_count, data_as_of) VALUES (?, ?, ?, ?, ?, ?, ?, ?);", bindings: [.int64(sessionID), .text(result.provider.rawValue), .double(result.startedAt.timeIntervalSince1970), .double(result.finishedAt.timeIntervalSince1970), .text(result.status.rawValue), .optionalText(result.message.map { String($0.prefix(4_096)) }), .int(Int32(result.warningCount)), .optionalDouble(result.dataAsOf?.timeIntervalSince1970)])
    }

    func refreshStatus(_ status: ProviderRefreshStatus) -> RefreshStatus {
        switch status {
        case .never: .failure
        case .success: .success
        case .partial: .partial
        case .failure: .failure
        }
    }

    func aggregateRefreshStatus(_ statuses: [ProviderRefreshStatus]) -> RefreshStatus {
        if statuses.allSatisfy({ $0 == .success }) { return .success }
        if statuses.contains(where: { $0 == .success || $0 == .partial }) { return .partial }
        return .failure
    }

    func resolutionCounts<T: Collection>(_ results: T) -> (resolved: Int, unsupported: Int, failed: Int) where T.Element: HomebrewResolutionSummarizable {
        results.reduce(into: (0, 0, 0)) { counts, result in
            switch result.resolutionBucket {
            case .resolved: counts.0 += 1
            case .unsupported: counts.1 += 1
            case .transientFailure: counts.2 += 1
            case .unavailable: break
            }
        }
    }

    /// A single vocabulary for every bound parameter in this file: `bind` applies a `[Binding]` to a
    /// prepared statement in order, and `run`/`scalarInt` build on it so call sites read as data
    /// rather than repeating a `guard sqlite3_bind_* == SQLITE_OK, ...` chain per statement.
    enum Binding {
        case text(String)
        case optionalText(String?)
        case int(Int32)
        case int64(Int64)
        case double(TimeInterval)
        case optionalDouble(TimeInterval?)
        case blob(Data?)
    }

    func bind(_ statement: OpaquePointer, _ bindings: [Binding]) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case let .text(value): result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            case let .optionalText(value): result = value.map { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) } ?? sqlite3_bind_null(statement, index)
            case let .int(value): result = sqlite3_bind_int(statement, index, value)
            case let .int64(value): result = sqlite3_bind_int64(statement, index, value)
            case let .double(value): result = sqlite3_bind_double(statement, index, value)
            case let .optionalDouble(value): result = value.map { sqlite3_bind_double(statement, index, $0) } ?? sqlite3_bind_null(statement, index)
            case let .blob(value):
                if let value {
                    result = value.isEmpty ? sqlite3_bind_zeroblob(statement, index, 0) : sqlite3_bind_blob(statement, index, (value as NSData).bytes, Int32(value.count), sqliteTransient)
                } else {
                    result = sqlite3_bind_null(statement, index)
                }
            }
            guard result == SQLITE_OK else { throw errorFromHandle() }
        }
    }

    /// Runs an INSERT/UPDATE/DELETE that doesn't read rows back.
    func run(_ sql: String, bindings: [Binding] = []) throws {
        try withStatement(sql) { statement in
            try bind(statement, bindings)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw errorFromHandle() }
        }
    }

    func scalarInt(_ sql: String, bindings: [Binding] = []) throws -> Int {
        var value = 0
        try withStatement(sql) { statement in
            try bind(statement, bindings)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw errorFromHandle() }
            value = Int(sqlite3_column_int64(statement, 0))
        }
        return value
    }

    func execute(_ sql: String) throws {
        guard let handle else { throw DatabaseError.sqlite(message: "Database is closed.") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else { throw DatabaseError.sqlite(message: errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))) }
    }

    func withStatement(_ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
        guard let handle else { throw DatabaseError.sqlite(message: "Database is closed.") }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { sqlite3_finalize(statement); throw errorFromHandle() }
        defer { sqlite3_finalize(statement) }
        try body(statement)
    }

    func stepRow(_ statement: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw errorFromHandle()
    }

    func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL, let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    func selectID(_ sql: String, text: String) throws -> Int64? {
        try selectID(sql, bindings: [.text(text)])
    }

    func selectID(_ sql: String, bindings: [Binding]) throws -> Int64? {
        var id: Int64?
        try withStatement(sql) { statement in
            try bind(statement, bindings)
            if try stepRow(statement) { id = sqlite3_column_int64(statement, 0) }
        }
        return id
    }

    func errorFromHandle() -> DatabaseError {
        guard let handle else { return .sqlite(message: "Database is closed.") }
        return .sqlite(message: String(cString: sqlite3_errmsg(handle)))
    }
}
