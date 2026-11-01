import CSQLite
import Foundation

/// Native application inventory, version observations, and update checks.
extension Database {
    func applyNativeInventoryLocked(_ inventory: NativeInventoryResult, sessionID: Int64, observedAt: Date) throws -> (
        added: Int, changed: Int, unchanged: Int, inactive: Int
    ) {
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
            for (id, nativeID) in try activeInstallations(provider: NativeApplicationProvider.identifier, roots: inventory.scannedRoots)
            where !seenIDs.contains(String(nativeID.dropFirst(5))) {
                try deactivateInstallation(id: id)
                inactive += 1
            }
        }
        // Apps discovered only by Spotlight outside every configured root are recorded under
        // discovery_root "/", which is deliberately never in scannedRoots since Spotlight's own
        // coverage can never be proven complete. Their continued existence can still be checked
        // directly on disk, independent of Spotlight, so they aren't ghosts forever — but "exists on
        // disk" alone isn't enough: a path can genuinely still exist while no longer (or never having
        // been) a plausible trackable application, e.g. a policy tightening excludes it after the
        // fact, so this uses the same isPlausibleNativeApplicationBundle check discovery itself uses.
        for (id, nativeID) in try activeInstallations(provider: NativeApplicationProvider.identifier, roots: ["/"])
        where !seenIDs.contains(String(nativeID.dropFirst(5))) {
            guard !isPlausibleNativeApplicationBundle(URL(filePath: String(nativeID.dropFirst(5)))) else { continue }
            try deactivateInstallation(id: id)
            inactive += 1
        }
        return (added, changed, unchanged, inactive)
    }

    func deactivateInstallation(id: Int64) throws {
        try run("UPDATE installations SET active = 0 WHERE id = ?;", bindings: [.int64(id)])
    }

    public func nativeApplicationItems(includeAll: Bool = false) throws -> [CatalogItem] {
        lock.lock()
        defer { lock.unlock() }
        // System-classified apps (everything under /System/Applications, etc.) are only included
        // alongside --all, matching README's documented contract ("sift apps --all includes
        // internal, CoreServices, inactive, and other non-default application records") — this was
        // previously hardcoded to always include them, showing system apps in plain `sift apps` too.
        let items = try nativeApplicationCatalogItems(includeAll: includeAll, excludeCaskOwnedApps: false, includeSystemClassification: includeAll)
        let collisions = Dictionary(grouping: items, by: \CatalogItem.selector)
        return items.map { item in
            guard (collisions[item.selector]?.count ?? 0) > 1, let path = item.path else { return item }
            return item.disambiguatingSelector(with: path)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Shared native-app row query/mapping for `catalogItems` and `nativeApplicationItems`, which differ only in
    /// whether cask-owned apps are excluded and whether system apps are included.
    func nativeApplicationCatalogItems(includeAll: Bool, excludeCaskOwnedApps: Bool, includeSystemClassification: Bool) throws -> [CatalogItem] {
        var items: [CatalogItem] = []
        let classificationCondition =
            includeSystemClassification ? "installations.classification IN ('user', 'system')" : "installations.classification = 'user'"
        // The catalog lists a cask in place of the app it installed; other owners have no catalog entry.
        let caskExclusion = excludeCaskOwnedApps ? "AND COALESCE((\(Self.installationOwnerSQL)), '') != 'homebrew'" : ""
        // The latest update check only counts while it was made against the installed version.
        try withStatement(
            """
            SELECT COALESCE(installations.display_name, software.display_name), software.bundle_identifier, installations.normalized_path,
                   observations.short_version, observations.build_version, installations.active, observations.observed_at,
                   installations.update_authority, \(Self.installationOwnerSQL),
                   CASE WHEN availability.installed_version_key = \(Self.observationVersionKeySQL) THEN availability.available_version END,
                   CASE WHEN availability.installed_version_key = \(Self.observationVersionKeySQL) THEN availability.detail END,
                   CASE WHEN availability.installed_version_key = \(Self.observationVersionKeySQL) THEN availability.authority END
            FROM installations JOIN software ON software.id = installations.software_id
            JOIN observations ON observations.id = (SELECT id FROM observations WHERE installation_id = installations.id ORDER BY observed_at DESC, id DESC LIMIT 1)
            LEFT JOIN update_availability AS availability ON availability.id = (SELECT id FROM update_availability WHERE installation_id = installations.id ORDER BY observed_at DESC, id DESC LIMIT 1)
            WHERE installations.provider = 'native-apps'
            \(caskExclusion)
              AND (? = 1 OR (installations.active = 1 AND \(classificationCondition)));
            """
        ) { statement in
            try bind(statement, [.int(includeAll ? 1 : 0)])
            while try stepRow(statement) {
                let name = String(cString: sqlite3_column_text(statement, 0))
                let bundleID = optionalText(statement, column: 1)
                let path = optionalText(statement, column: 2)
                let selector = bundleID.map { "app:\($0)" } ?? "app:\(path ?? name)"
                let version = optionalText(statement, column: 3) ?? optionalText(statement, column: 4)
                let owner = optionalText(statement, column: 8)
                let caskOwned = owner != nil
                // A version found through the cask catalog is credited to it, not to the bundle's updater.
                let checkedVia = optionalText(statement, column: 11)
                let creditedToCheck: Set<String> = [
                    NativeUpdateAuthority.homebrewCatalog.rawValue, NativeUpdateAuthority.bundled.rawValue, NativeUpdateAuthority.githubReleases.rawValue
                ]
                let source = caskOwned ? owner : checkedVia.flatMap { creditedToCheck.contains($0) ? $0 : nil } ?? optionalText(statement, column: 7)
                items.append(
                    CatalogItem(
                        selector: selector, aliases: [name] + (bundleID.map { [$0] } ?? []), kind: .nativeApp, name: name, fullName: nil,
                        installedVersion: version, availableVersion: caskOwned ? nil : optionalText(statement, column: 9),
                        active: sqlite3_column_int(statement, 5) == 1, bundleIdentifier: bundleID, path: path, prefix: nil, tap: nil, ownership: nil,
                        autoUpdates: false, observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)), updateSource: source,
                        updateDetail: caskOwned ? nil : optionalText(statement, column: 10)))
            }
        }
        return items
    }

    public func nativeVersionTransitions(includeAll: Bool = false) throws -> [NativeVersionTransition] {
        lock.lock()
        defer { lock.unlock() }
        var changes: [NativeVersionTransition] = []
        try withStatement(
            """
            SELECT COALESCE(installations.display_name, software.display_name), software.bundle_identifier, installations.normalized_path,
                   version_transitions.from_version, version_transitions.to_version, version_transitions.observed_at
            FROM version_transitions
            JOIN installations ON installations.id = version_transitions.installation_id
            JOIN software ON software.id = installations.software_id
            WHERE installations.provider = 'native-apps'
              AND (? = 1 OR (installations.active = 1 AND installations.classification IN ('user', 'system')))
            ORDER BY version_transitions.observed_at DESC, version_transitions.id DESC;
            """
        ) { statement in
            try bind(statement, [.int(includeAll ? 1 : 0)])
            while try stepRow(statement) {
                let name = String(cString: sqlite3_column_text(statement, 0))
                let bundleID = optionalText(statement, column: 1)
                // normalized_path was added by an ALTER TABLE with no NOT NULL constraint; read it
                // defensively like the sibling catalog query does, rather than trapping on NULL.
                let path = optionalText(statement, column: 2) ?? name
                changes.append(
                    NativeVersionTransition(
                        selector: bundleID.map { "app:\($0)" } ?? "app:\(path)", name: name, path: path,
                        fromVersion: String(cString: sqlite3_column_text(statement, 3)), toVersion: String(cString: sqlite3_column_text(statement, 4)),
                        observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))))
            }
        }
        return changes
    }

    /// The installed-version identity a native update check was made against; see NativeUpdateCheck.
    static func versionKey(short: String?, build: String?) -> String {
        "\(short ?? "")\u{1F}\(build ?? "")"
    }

    static let observationVersionKeySQL = "COALESCE(observations.short_version, '') || char(31) || COALESCE(observations.build_version, '')"

    /// The package manager that installed this application bundle ("homebrew", "macports"), or
    /// NULL; that provider reports the app's updates.
    static let installationOwnerSQL = """
        COALESCE(
            (SELECT 'homebrew' FROM cask_artifacts
             JOIN homebrew_packages ON homebrew_packages.id = cask_artifacts.homebrew_package_id
             WHERE cask_artifacts.active = 1
               AND homebrew_packages.active = 1
               AND cask_artifacts.normalized_path = installations.normalized_path
             LIMIT 1),
            (SELECT managed_packages.provider FROM managed_artifacts
             JOIN managed_packages ON managed_packages.id = managed_artifacts.managed_package_id
             WHERE managed_packages.active = 1 AND managed_artifacts.normalized_path = installations.normalized_path
             LIMIT 1)
        )
        """

    static let managedInstallationSQL = "(\(installationOwnerSQL)) IS NOT NULL"

    /// One row per active user application whose most recent update check found a newer version
    /// and was made against the version still installed: an app updated since that check has no
    /// pending update until the next check says so.
    static let currentNativeUpdatesSQL = """
        SELECT installations.id, COALESCE(installations.display_name, software.display_name), installations.normalized_path,
               availability.authority, availability.available_version, availability.observed_at,
               COALESCE(observations.short_version, observations.build_version, '')
        FROM installations
        JOIN software ON software.id = installations.software_id
        JOIN observations ON observations.id = (SELECT id FROM observations WHERE installation_id = installations.id ORDER BY observed_at DESC, id DESC LIMIT 1)
        JOIN update_availability AS availability ON availability.id = (SELECT id FROM update_availability WHERE installation_id = installations.id ORDER BY observed_at DESC, id DESC LIMIT 1)
        WHERE installations.provider = 'native-apps'
          AND installations.active = 1
          AND installations.classification = 'user'
          AND availability.is_available = 1
          AND availability.installed_version_key = \(observationVersionKeySQL)
          AND NOT \(managedInstallationSQL)
        """

    /// A failed check writes nothing, so the previous answer stands until a check succeeds.
    func applyNativeUpdateChecksLocked(_ checks: [NativeUpdateCheck], sessionID: Int64, observedAt: Date) throws {
        for check in checks {
            let available: (version: String, notes: NativeReleaseNotes?)?
            let detail: String?
            switch check.outcome {
            case let .available(version, notes): (available, detail) = ((version, notes), check.note)
            case .upToDate: (available, detail) = (nil, check.note)
            case let .unchecked(reason): (available, detail) = (nil, reason)
            case .failed: continue
            }
            guard
                let installationID = try selectID("SELECT id FROM installations WHERE provider = 'native-apps' AND native_id = ?;", text: "path:\(check.path)")
            else { continue }
            try run(
                "INSERT INTO update_availability (refresh_session_id, installation_id, authority, available_version, is_available, observed_at, installed_version_key, detail) VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
                bindings: [
                    .int64(sessionID), .int64(installationID), .text(check.authority.rawValue), .optionalText(available?.version),
                    .int(available == nil ? 0 : 1), .double(observedAt.timeIntervalSince1970), .text(check.installedVersionKey), .optionalText(detail)
                ])
            if let available, let notes = available.notes {
                try run(
                    """
                    INSERT INTO release_notes (software_id, target_version, source, confidence, source_url, content, fetched_at)
                    SELECT software_id, ?, ?, 'exact', ?, ?, ? FROM installations WHERE id = ?
                    ON CONFLICT(software_id, target_version, source) DO UPDATE SET source_url = excluded.source_url, content = excluded.content, fetched_at = excluded.fetched_at;
                    """,
                    bindings: [
                        .text(available.version), .text(check.authority.rawValue), .optionalText(notes.sourceURL), .optionalText(notes.content),
                        .double(observedAt.timeIntervalSince1970), .int64(installationID)
                    ])
            }
        }
    }

    /// Release notes stored for a native application's pending update, if any.
    public func nativeReleaseNotes(path: String, targetVersion: String) throws -> NativeReleaseNotes? {
        lock.lock(); defer { lock.unlock() }
        var notes: NativeReleaseNotes?
        try withStatement(
            """
            SELECT release_notes.content, release_notes.source_url FROM release_notes
            JOIN installations ON installations.software_id = release_notes.software_id
            WHERE installations.provider = 'native-apps' AND installations.normalized_path = ? AND release_notes.target_version = ?
            ORDER BY release_notes.fetched_at DESC LIMIT 1;
            """
        ) { statement in
            try bind(statement, [.text(path), .text(targetVersion)])
            if try stepRow(statement) { notes = NativeReleaseNotes(content: optionalText(statement, column: 0), sourceURL: optionalText(statement, column: 1)) }
        }
        return notes
    }

    func resolveSoftware(_ application: NativeApplication, createdAt: Date) throws -> Int64 {
        if let bundleIdentifier = application.bundleIdentifier,
            let id = try selectID("SELECT id FROM software WHERE bundle_identifier = ?;", text: bundleIdentifier)
        {
            return id
        }
        if application.bundleIdentifier == nil,
            let id = try existingNativeSoftwareID(path: application.path)
        {
            return id
        }
        try run(
            "INSERT INTO software (display_name, bundle_identifier, created_at) VALUES (?, ?, ?);",
            bindings: [.text(application.displayName), .optionalText(application.bundleIdentifier), .double(createdAt.timeIntervalSince1970)])
        guard let handle else { throw DatabaseError.sqlite(message: "Database is closed.") }
        return sqlite3_last_insert_rowid(handle)
    }

    func existingNativeSoftwareID(path: String) throws -> Int64? {
        var id: Int64?
        try withStatement("SELECT software_id FROM installations WHERE provider = 'native-apps' AND native_id = ? LIMIT 1;") { statement in
            try bind(statement, [.text("path:\(path)")])
            if try stepRow(statement) { id = sqlite3_column_int64(statement, 0) }
        }
        return id
    }

    func resolveInstallation(_ application: NativeApplication, softwareID: Int64, observedAt: Date) throws -> (id: Int64, isNew: Bool) {
        let nativeID = "path:\(application.path)"
        if let id = try selectID("SELECT id FROM installations WHERE provider = 'native-apps' AND native_id = ?;", text: nativeID) {
            // display_name is refreshed on every observation (not just first insert) so a legitimate
            // rename is picked up, and so two installations that happen to share a software_id (e.g.
            // Xcode.app and Xcode-beta.app, which commonly share one bundle identifier) each keep
            // their own name instead of inheriting whichever one wrote software.display_name first.
            try run(
                "UPDATE installations SET software_id = ?, path = ?, normalized_path = ?, classification = ?, discovery_root = ?, active = 1, last_seen_at = ?, display_name = ?, update_authority = ? WHERE id = ?;",
                bindings: [
                    .int64(softwareID), .text(application.path), .text(application.path), .text(application.classification.rawValue),
                    .text(application.discoveryRoot), .double(observedAt.timeIntervalSince1970), .text(application.displayName),
                    .text(application.updateAuthority.rawValue), .int64(id)
                ])
            return (id, false)
        }
        try run(
            "INSERT INTO installations (software_id, provider, native_id, path, normalized_path, management_context, created_at, active, last_seen_at, classification, discovery_root, display_name, update_authority) VALUES (?, 'native-apps', ?, ?, ?, 'native', ?, 1, ?, ?, ?, ?, ?);",
            bindings: [
                .int64(softwareID), .text(nativeID), .text(application.path), .text(application.path), .double(observedAt.timeIntervalSince1970),
                .double(observedAt.timeIntervalSince1970), .text(application.classification.rawValue), .text(application.discoveryRoot),
                .text(application.displayName), .text(application.updateAuthority.rawValue)
            ])
        guard let handle else { throw DatabaseError.sqlite(message: "Database is closed.") }
        return (sqlite3_last_insert_rowid(handle), true)
    }

    func latestObservation(for installationID: Int64) throws -> (shortVersion: String?, buildVersion: String?, providerVersion: String?, observedAt: Date)? {
        var result: (String?, String?, String?, Date)?
        try withStatement(
            "SELECT short_version, build_version, provider_version, observed_at FROM observations WHERE installation_id = ? ORDER BY observed_at DESC, id DESC LIMIT 1;"
        ) { statement in
            try bind(statement, [.int64(installationID)])
            if try stepRow(statement) {
                result = (
                    optionalText(statement, column: 0), optionalText(statement, column: 1), optionalText(statement, column: 2),
                    Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                )
            }
        }
        return result
    }

    func insertObservation(sessionID: Int64, installationID: Int64, application: NativeApplication, observedAt: Date) throws {
        try run(
            "INSERT INTO observations (refresh_session_id, installation_id, observed_at, short_version, build_version, provider_version) VALUES (?, ?, ?, ?, ?, NULL);",
            bindings: [
                .int64(sessionID), .int64(installationID), .double(observedAt.timeIntervalSince1970), .optionalText(application.shortVersion),
                .optionalText(application.buildVersion)
            ])
    }

    func versionsDiffer(
        _ previous: (shortVersion: String?, buildVersion: String?, providerVersion: String?, observedAt: Date), _ application: NativeApplication
    ) -> Bool {
        previous.shortVersion != application.shortVersion || previous.buildVersion != application.buildVersion
    }

    func insertTransition(
        installationID: Int64, previous: (shortVersion: String?, buildVersion: String?, providerVersion: String?, observedAt: Date),
        application: NativeApplication, observedAt: Date
    ) throws {
        let from = versionText(short: previous.shortVersion, build: previous.buildVersion)
        let to = versionText(short: application.shortVersion, build: application.buildVersion)
        try run(
            "INSERT INTO version_transitions (installation_id, from_version, to_version, first_observed_at, observed_at) VALUES (?, ?, ?, ?, ?);",
            bindings: [
                .int64(installationID), .text(from.isEmpty ? "unknown" : from), .text(to.isEmpty ? "unknown" : to),
                .double(previous.observedAt.timeIntervalSince1970), .double(observedAt.timeIntervalSince1970)
            ])
    }

    func versionText(short: String?, build: String?) -> String {
        guard let short else { return build ?? "" }
        return build.map { "\(short) (\($0))" } ?? short
    }

    func activeInstallations(provider: String, roots: [String]) throws -> [(Int64, String)] {
        var result: [(Int64, String)] = []
        guard !roots.isEmpty else { return result }
        let placeholders = Array(repeating: "?", count: roots.count).joined(separator: ",")
        try withStatement("SELECT id, native_id FROM installations WHERE provider = ? AND active = 1 AND discovery_root IN (\(placeholders));") { statement in
            try bind(statement, [.text(provider)] + roots.map { .text($0) })
            while try stepRow(statement) { result.append((sqlite3_column_int64(statement, 0), String(cString: sqlite3_column_text(statement, 1)))) }
        }
        return result
    }
}
