import CSQLite
import Foundation

/// Cache-only reads behind the dashboard, `sift updates`, and the catalog.
extension Database {
    public func dashboard(now: Date = .now, staleAfter: TimeInterval = 24 * 60 * 60) throws -> Dashboard {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN DEFERRED TRANSACTION;")
        do {
            let session = try latestSession()
            let providerResults = try providerRefreshResults()
            // Freshness is per-provider: a provider that has never succeeded (or is currently
            // failing) does not blank out data from providers that have. dataAsOf is the newest
            // successfully collected provider data that's actually available, or nil if none is.
            let dataAsOf = providerResults.compactMap(\.dataAsOf).max()
            let nativeAvailableUpdateCount = try scalarInt("SELECT COUNT(*) FROM (\(Self.currentNativeUpdatesSQL));")
            // Auto-updating casks are reported separately (informationalUpdateCount): the user
            // doesn't need to act on them, so they must not inflate the main "needs attention" count.
            // Both counts share every condition except auto_updates, so one grouped scan replaces
            // what would otherwise be the same WHERE clause duplicated and liable to drift.
            //
            // target_for_installed_version = installed_version, not just target_status = 'resolved':
            // a transient info/outdated mismatch preserves the *previous* round's resolved target_status
            // (and target_for_installed_version/available_version with it) rather than writing the
            // literal string 'transientFailure' — see applyTargetResults' preserveStatus. If Homebrew's
            // installed_version has since moved (another process upgraded it) while that stale target
            // was preserved, available_version no longer corresponds to the package's current installed
            // version at all; target_for_installed_version records which installed_version it was
            // actually resolved against, so comparing it against the current installed_version is what
            // actually distinguishes a trustworthy resolved target from a stale, carried-over one.
            // Dependency-only formulae (pulled in solely to satisfy another formula's requirement,
            // never requested directly) are stored and inventoried like everything else, but PROJECT.md's
            // scope explicitly "defaults dashboard output to requested formulae": a user can't act on
            // `readline` or `openssl@3` having an update independent of what depends on it, so it must
            // not inflate the count they see as needing their attention.
            var homebrewAvailableUpdateCount = 0
            var informationalUpdateCount = 0
            try withStatement(
                """
                SELECT SUM(CASE WHEN auto_updates = 0 THEN 1 ELSE 0 END), SUM(CASE WHEN auto_updates = 1 THEN 1 ELSE 0 END)
                FROM homebrew_packages
                WHERE active = 1
                  AND available_version IS NOT NULL
                  AND available_version != installed_version
                  AND target_status = 'resolved'
                  AND target_for_installed_version = installed_version
                  AND ownership IN ('explicitlyRequested', 'installedCask');
                """
            ) { statement in
                guard sqlite3_step(statement) == SQLITE_ROW else { throw errorFromHandle() }
                homebrewAvailableUpdateCount = Int(sqlite3_column_int64(statement, 0))
                informationalUpdateCount = Int(sqlite3_column_int64(statement, 1))
            }
            let managedCondition = "active = 1 AND requested = 1 AND available_version IS NOT NULL AND available_version != installed_version"
            let managedAvailableUpdateCount = try scalarInt("SELECT COUNT(*) FROM managed_packages WHERE \(managedCondition) AND self_updating = 0;")
            informationalUpdateCount += try scalarInt("SELECT COUNT(*) FROM managed_packages WHERE \(managedCondition) AND self_updating = 1;")
            let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60).timeIntervalSince1970
            let recentTransitionCount = try scalarInt(
                "SELECT COUNT(DISTINCT installation_id) FROM version_transitions WHERE observed_at >= ? AND observed_at <= ?;",
                bindings: [.double(cutoff), .double(now.timeIntervalSince1970)]
            )
            let failedProviderCount =
                if let session {
                    try scalarInt("SELECT COUNT(*) FROM provider_runs WHERE refresh_session_id = ? AND status = 'failure';", bindings: [.int64(session.id)])
                } else {
                    0
                }
            let partialProviderCount =
                if let session {
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
                data: DashboardData(
                    availableUpdateCount: nativeAvailableUpdateCount + homebrewAvailableUpdateCount + managedAvailableUpdateCount,
                    informationalUpdateCount: informationalUpdateCount, recentTransitionCount: recentTransitionCount,
                    partialProviderCount: partialProviderCount, failedProviderCount: failedProviderCount, providerResults: providerResults)
            )
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func catalogItems(includeAll: Bool = false) throws -> [CatalogItem] {
        lock.lock()
        defer { lock.unlock() }
        var items = try nativeApplicationCatalogItems(includeAll: includeAll, excludeCaskOwnedApps: true, includeSystemClassification: false)
        // available_version is only surfaced when target_for_installed_version still matches the
        // package's current installed_version — same reasoning as homebrewUpdates()/the dashboard
        // count: a transient info/outdated mismatch can preserve a target resolved against a since-
        // superseded installed_version, and that stale pairing must not be shown as this package's
        // current available update.
        try withStatement(
            """
            SELECT kind, name, full_name, prefix, tap, ownership, installed_version,
                   CASE WHEN target_for_installed_version = installed_version THEN available_version ELSE NULL END,
                   auto_updates, active, observed_at
            FROM homebrew_packages
            WHERE (? = 1 OR (active = 1 AND ownership IN ('explicitlyRequested', 'installedCask')));
            """
        ) { statement in
            try bind(statement, [.int(includeAll ? 1 : 0)])
            while try stepRow(statement) {
                let kind = HomebrewPackageKind(rawValue: String(cString: sqlite3_column_text(statement, 0))) ?? .formula
                let name = String(cString: sqlite3_column_text(statement, 1))
                let fullName = String(cString: sqlite3_column_text(statement, 2))
                let prefix = String(cString: sqlite3_column_text(statement, 3))
                let selector = "\(kind == .formula ? "formula" : "cask"):\(name)"
                items.append(
                    CatalogItem(
                        selector: selector, aliases: [name, fullName], kind: kind == .formula ? .homebrewFormula : .homebrewCask, name: name,
                        fullName: fullName, installedVersion: String(cString: sqlite3_column_text(statement, 6)),
                        availableVersion: optionalText(statement, column: 7), active: sqlite3_column_int(statement, 9) == 1, bundleIdentifier: nil, path: nil,
                        prefix: prefix, tap: optionalText(statement, column: 4), ownership: String(cString: sqlite3_column_text(statement, 5)),
                        autoUpdates: sqlite3_column_int(statement, 8) == 1, observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                        updateSource: "homebrew"))
            }
        }
        // npm, uv, cargo, MacPorts, and Steam packages; dependency-only ports only with includeAll.
        try withStatement(
            "SELECT provider, scope, name, installed_version, available_version, active, observed_at, self_updating, requested, identifier FROM managed_packages WHERE (? = 1 OR (active = 1 AND requested = 1));"
        ) { statement in
            try bind(statement, [.int(includeAll ? 1 : 0)])
            while try stepRow(statement) {
                let provider = String(cString: sqlite3_column_text(statement, 0))
                let scope = String(cString: sqlite3_column_text(statement, 1))
                let name = String(cString: sqlite3_column_text(statement, 2))
                let identifier = optionalText(statement, column: 9)
                items.append(
                    CatalogItem(
                        selector: "\(Self.packageSelectorPrefix(provider)):\(name)", aliases: [name] + (identifier.map { [$0] } ?? []), kind: .package,
                        name: name, fullName: nil, installedVersion: String(cString: sqlite3_column_text(statement, 3)),
                        availableVersion: optionalText(statement, column: 4), active: sqlite3_column_int(statement, 5) == 1, bundleIdentifier: nil, path: nil,
                        prefix: scope, tap: nil, ownership: sqlite3_column_int(statement, 8) == 1 ? "requested" : "dependency",
                        autoUpdates: sqlite3_column_int(statement, 7) == 1, observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                        updateSource: provider, identifier: identifier))
            }
        }
        let collisions = Dictionary(grouping: items, by: \CatalogItem.selector)
        return items.map { item in
            guard (collisions[item.selector]?.count ?? 0) > 1 else { return item }
            guard let disambiguator = item.prefix ?? item.path else { return item }
            return item.disambiguatingSelector(with: disambiguator)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The selector prefix for a managed package: `npm:`, `uv:`, `cargo:`, `port:`, `steam:`.
    static func packageSelectorPrefix(_ provider: String) -> String {
        switch provider {
        case RefreshProvider.npmGlobal.rawValue: "npm"
        case RefreshProvider.uvTools.rawValue: "uv"
        case RefreshProvider.macPorts.rawValue: "port"
        case RefreshProvider.steamGames.rawValue: "steam"
        default: provider
        }
    }

    public func resolveCatalogItem(_ selector: String, includeAll: Bool = false) throws -> CatalogResolution {
        try catalogItems(includeAll: includeAll).resolveCatalogItem(selector)
    }

    public func updates(includeAll: Bool = false, now: Date = .now, staleAfter: TimeInterval = 24 * 60 * 60) throws -> [UnifiedUpdate] {
        let homebrew = try homebrewUpdates(includeAll: includeAll, now: now, staleAfter: staleAfter).map {
            UnifiedUpdate(
                provider: "homebrew", scope: $0.prefix, name: $0.name, installedVersion: $0.installedVersion, availableVersion: $0.availableVersion,
                freshness: $0.freshness, dataAsOf: $0.dataAsOf, selfUpdating: $0.autoUpdates)
        }
        lock.lock()
        defer { lock.unlock() }
        var managed: [UnifiedUpdate] = []
        let nativeStatus = try providerStatuses(for: [.nativeUpdates])[.nativeUpdates] ?? .never
        try withStatement("\(Self.currentNativeUpdatesSQL) ORDER BY 2 COLLATE NOCASE;") { statement in
            while try stepRow(statement) {
                let dataAsOf = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                let freshness: Freshness = nativeStatus == .success && now.timeIntervalSince(dataAsOf) < staleAfter ? .current : .stale
                let authority = NativeUpdateAuthority(rawValue: String(cString: sqlite3_column_text(statement, 3)))
                let provider =
                    switch authority {
                    case .appStore: "app-store";
                    case .homebrewCatalog: "homebrew-catalog";
                    default: authority?.rawValue ?? "native"
                    }
                managed.append(
                    UnifiedUpdate(
                        provider: provider, scope: optionalText(statement, column: 2) ?? "", name: String(cString: sqlite3_column_text(statement, 1)),
                        installedVersion: String(cString: sqlite3_column_text(statement, 6)), availableVersion: optionalText(statement, column: 4) ?? "",
                        freshness: freshness, dataAsOf: dataAsOf))
            }
        }
        let providerStatuses = try managedProviderStatuses()
        // Dependency-only packages (MacPorts ports nobody requested) are hidden unless includeAll.
        try withStatement(
            "SELECT provider, scope, name, installed_version, available_version, last_seen_at, self_updating FROM managed_packages WHERE active = 1 AND available_version IS NOT NULL AND available_version != installed_version AND (? = 1 OR requested = 1) ORDER BY name COLLATE NOCASE, provider, scope;"
        ) { statement in
            try bind(statement, [.int(includeAll ? 1 : 0)])
            while try stepRow(statement) {
                let dataAsOf = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                let provider = String(cString: sqlite3_column_text(statement, 0))
                let freshness: Freshness = providerStatuses[provider] == .success && now.timeIntervalSince(dataAsOf) < staleAfter ? .current : .stale
                managed.append(
                    UnifiedUpdate(
                        provider: provider, scope: String(cString: sqlite3_column_text(statement, 1)), name: String(cString: sqlite3_column_text(statement, 2)),
                        installedVersion: String(cString: sqlite3_column_text(statement, 3)),
                        availableVersion: String(cString: sqlite3_column_text(statement, 4)), freshness: freshness, dataAsOf: dataAsOf,
                        selfUpdating: sqlite3_column_int(statement, 6) == 1))
            }
        }
        return (homebrew + managed).sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.provider < $1.provider : comparison == .orderedAscending
        }
    }

    func managedProviderStatuses() throws -> [String: ProviderRefreshStatus] {
        let states = try providerStatuses(for: RefreshProvider.managedPackageProviders.sorted { $0.rawValue < $1.rawValue })
        return Dictionary(uniqueKeysWithValues: states.map { ($0.key.rawValue, $0.value) })
    }

    func providerStatuses(for providers: [RefreshProvider]) throws -> [RefreshProvider: ProviderRefreshStatus] {
        var states: [RefreshProvider: ProviderRefreshStatus] = [:]
        let placeholders = providers.map { _ in "?" }.joined(separator: ", ")
        try withStatement("SELECT provider, latest_status FROM provider_state WHERE provider IN (\(placeholders));") { statement in
            try bind(statement, providers.map { .text($0.rawValue) })
            while try stepRow(statement) {
                guard let providerText = sqlite3_column_text(statement, 0),
                    let provider = RefreshProvider(rawValue: String(cString: providerText)),
                    let statusText = sqlite3_column_text(statement, 1),
                    let status = ProviderRefreshStatus(rawValue: String(cString: statusText))
                else { continue }
                states[provider] = status
            }
        }
        return states
    }

    func providerRefreshResults() throws -> [ProviderRefreshResult] {
        var states: [String: ProviderRefreshResult] = [:]
        // provider_state carries status and freshness across refreshes; timing, message, and warning
        // count come from that provider's most recent run.
        try withStatement(
            """
            SELECT state.provider, state.last_attempt_at, state.latest_status, state.data_as_of, run.started_at, run.finished_at, run.error_message, run.warning_count
            FROM provider_state AS state
            LEFT JOIN provider_runs AS run ON run.id = (SELECT MAX(id) FROM provider_runs WHERE provider = state.provider);
            """
        ) { statement in
            while try stepRow(statement) {
                guard let providerText = sqlite3_column_text(statement, 0),
                    let provider = RefreshProvider(rawValue: String(cString: providerText)),
                    let statusText = sqlite3_column_text(statement, 2),
                    let status = ProviderRefreshStatus(rawValue: String(cString: statusText))
                else { continue }
                let attempt =
                    sqlite3_column_type(statement, 1) == SQLITE_NULL
                    ? Date(timeIntervalSince1970: 0) : Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                let dataAsOf = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                let hasRun = sqlite3_column_type(statement, 4) != SQLITE_NULL
                let startedAt = hasRun ? Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)) : attempt
                let finishedAt = hasRun ? Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)) : attempt
                states[provider.rawValue] = ProviderRefreshResult(
                    provider: provider, status: status, message: optionalText(statement, column: 6),
                    warningCount: hasRun ? Int(sqlite3_column_int(statement, 7)) : 0, startedAt: startedAt, finishedAt: finishedAt, dataAsOf: dataAsOf)
            }
        }
        return RefreshProvider.allCases.map { provider in
            states[provider.rawValue]
                ?? ProviderRefreshResult(
                    provider: provider, status: .never, startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 0))
        }
    }
}
