import Foundation

public struct RefreshCoordinator: Sendable {
    private let database: Database
    private let nativeProvider: NativeApplicationProvider
    private let homebrewProvider: HomebrewProvider
    private let npmGlobalProvider: NPMGlobalProvider
    private let uvToolProvider: UVToolProvider
    private let steamProvider: SteamProvider
    private let macPortsProvider: MacPortsProvider
    private let cargoProvider: CargoProvider
    private let metadataClient: MetadataHTTPClient
    private let releaseNotes: any HomebrewReleaseNotesResolving
    private let nativeUpdates: any NativeUpdateResolving

    public init(
        database: Database, nativeProvider: NativeApplicationProvider = NativeApplicationProvider(), homebrewProvider: HomebrewProvider = HomebrewProvider(),
        npmGlobalProvider: NPMGlobalProvider = NPMGlobalProvider(), uvToolProvider: UVToolProvider = UVToolProvider(),
        steamProvider: SteamProvider = SteamProvider(), macPortsProvider: MacPortsProvider = MacPortsProvider(), cargoProvider: CargoProvider = CargoProvider(),
        releaseNotes: (any HomebrewReleaseNotesResolving)? = nil, nativeUpdates: (any NativeUpdateResolving)? = nil
    ) {
        self.database = database
        self.nativeProvider = nativeProvider
        self.homebrewProvider = homebrewProvider
        self.npmGlobalProvider = npmGlobalProvider
        self.uvToolProvider = uvToolProvider
        self.steamProvider = steamProvider
        self.macPortsProvider = macPortsProvider
        self.cargoProvider = cargoProvider
        let metadataClient = MetadataHTTPClient(database: database)
        self.metadataClient = metadataClient
        self.releaseNotes = releaseNotes ?? ReleaseNotesResolver(metadataClient: metadataClient)
        self.nativeUpdates = nativeUpdates ?? NativeUpdateResolver(metadataClient: metadataClient)
    }

    public func refresh(now: Date = .now, homebrewUpdate: HomebrewUpdatePolicy = .never, progress: (@Sendable (String) -> Void)? = nil) throws -> RefreshSummary
    {
        let clock = RefreshClock(start: now)
        // Providers share no state, so they run concurrently: a refresh takes as long as the slowest
        // provider rather than the sum of all of them. Each one is still internally sequential.
        let native = Concurrent { nativePhase(clock: clock) }
        let homebrew = Concurrent { homebrewPhase(clock: clock, update: homebrewUpdate, progress: progress) }
        let npm = Concurrent { npmPhase(clock: clock) }
        let uv = Concurrent { uvPhase(clock: clock) }
        let steam = Concurrent { steamPhase(clock: clock) }
        let macPorts = Concurrent { macPortsPhase(clock: clock) }
        let cargo = Concurrent { cargoPhase(clock: clock) }
        // The cask catalog takes a quarter second to index; do it while Homebrew is still running,
        // once the scan shows there are applications to check.
        let resolver = nativeUpdates
        let prepared = Concurrent {
            if native.value.inventory.applications.contains(where: { $0.classification == .user }) { resolver.prepare() }
        }

        let homebrewInventory = attributingLinkedApplications(homebrew.value, applications: native.value.inventory.applications)
        // Release notes and native update checks both start once the Homebrew inventory is known:
        // apps a package manager installed are reported by that package manager, not checked again.
        let notes = Concurrent { homebrewNotesPhase(clock: clock, inventory: homebrewInventory) }
        let packageOwnedPaths = Set(
            homebrewInventory.inventory.packages.flatMap(\.artifactPaths)
                + (macPorts.value.inventory?.scopes ?? []).flatMap(\.packages).flatMap(\.applicationPaths))
        prepared.wait()
        let updates = nativeUpdatesPhase(clock: clock, applications: native.value.inventory.applications, excluding: packageOwnedPaths)
        let homebrewResult = notes.value
        let managed = [npm.value, uv.value, steam.value, macPorts.value, cargo.value]
        return try database.applyRefresh(
            RefreshPersistenceInput(
                startedAt: now,
                finishedAt: clock.now(),
                nativeInventory: native.value.inventory,
                homebrewInventory: homebrewResult.inventory,
                targetResults: homebrewResult.targets,
                releaseNoteResults: homebrewResult.notes,
                managedPackageInventories: managed.compactMap(\.inventory),
                nativeUpdateChecks: updates.checks,
                providerResults: [native.value.result] + homebrewResult.results + managed.map(\.result) + [updates.result]
            ))
    }

    // MARK: - Native applications

    private func nativePhase(clock: RefreshClock) -> (inventory: NativeInventoryResult, result: ProviderRefreshResult) {
        let startedAt = clock.now()
        let native = nativeProvider.discover()
        let finishedAt = clock.now()
        let result = ProviderRefreshResult(
            provider: .nativeApplications, status: native.complete ? .success : .partial, message: native.warnings.nonEmptyJoined,
            warningCount: native.warnings.count, startedAt: startedAt, finishedAt: finishedAt, dataAsOf: native.complete ? finishedAt : nil)
        return (native, result)
    }

    /// Asks each user application's updater (Sparkle feed, App Store listing, or Homebrew's cask
    /// catalog as a fallback) for its latest version. Steam games are reported by Steam.
    private func nativeUpdatesPhase(clock: RefreshClock, applications: [NativeApplication], excluding caskOwnedPaths: Set<String>) -> (
        checks: [NativeUpdateCheck], result: ProviderRefreshResult
    ) {
        let startedAt = clock.now()
        let resolver = nativeUpdates
        let candidates = applications.filter { application in
            application.classification == .user && !caskOwnedPaths.contains(application.path) && application.updateAuthority != .steam
        }
        let pending = candidates.map { application in Concurrent { resolver.resolve(application) } }
        let checks = attributingBundledApplications(pending.map(\.value), applications: candidates)
        let finishedAt = clock.now()
        let failures = checks.compactMap { check -> String? in
            if case let .failed(message) = check.outcome { message } else { nil }
        }
        let status: ProviderRefreshStatus = failures.isEmpty ? .success : failures.count == checks.count ? .failure : .partial
        let result = ProviderRefreshResult(
            provider: .nativeUpdates, status: status, message: failures.nonEmptyJoined, warningCount: failures.count, startedAt: startedAt,
            finishedAt: finishedAt, dataAsOf: status == .success ? finishedAt : nil)
        return (checks, result)
    }

    /// Apps left without an answer are credited to a checked app from the same vendor (the first
    /// two bundle-identifier components) when both came from the same installer package, per
    /// macOS's receipts, or sit in the same product folder. Resolve's installer drops its
    /// utilities into /Applications/DaVinci Resolve; Proxy Generator Lite lands in /Applications
    /// but shares Resolve's package.
    private func attributingBundledApplications(_ checks: [NativeUpdateCheck], applications: [NativeApplication]) -> [NativeUpdateCheck] {
        let byPath = Dictionary(uniqueKeysWithValues: applications.map { ($0.path, $0) })
        func vendor(_ application: NativeApplication) -> String? {
            guard let parts = application.bundleIdentifier?.lowercased().split(separator: "."), parts.count >= 3 else { return nil }
            return parts.prefix(2).joined(separator: ".")
        }
        func isAnswered(_ check: NativeUpdateCheck) -> Bool {
            switch check.outcome {
            case .available, .upToDate: true;
            default: false
            }
        }
        let answered = checks.filter(isAnswered).compactMap { check in byPath[check.path].map { (application: $0, check: check) } }
        let unanswered = checks.filter { check in
            guard case .unchecked = check.outcome, check.authority == .unknown, let application = byPath[check.path] else { return false }
            return vendor(application) != nil
        }
        guard !unanswered.isEmpty, !answered.isEmpty else { return checks }
        let receipts = InstallerReceipts(runner: CommandRunner(), database: database)
        // Receipt lookups each run pkgutil; issue every one that might be needed at once.
        let needsReceipt = unanswered.compactMap { byPath[$0.path] }.filter { application in
            ["/Applications", homeApplicationsPath].contains((application.path as NSString).deletingLastPathComponent)
        }
        let lookups = Set(
            needsReceipt.map(\.path) + answered.filter { pair in needsReceipt.contains { vendor($0) == vendor(pair.application) } }.map(\.application.path))
        lookups.map { path in Concurrent { receipts.package(for: path) } }.forEach { $0.wait() }
        var replacements: [String: NativeUpdateCheck] = [:]
        for check in unanswered {
            let application = byPath[check.path]!
            let siblings = answered.filter { vendor($0.application) == vendor(application) }
            guard !siblings.isEmpty else { continue }
            let folder = (application.path as NSString).deletingLastPathComponent
            let isProductFolder = !["/Applications", homeApplicationsPath].contains(folder)
            let sibling =
                (isProductFolder ? siblings.first { ($0.application.path as NSString).deletingLastPathComponent == folder } : nil)
                ?? receipts.package(for: application.path).flatMap { package in siblings.first { receipts.package(for: $0.application.path) == package } }
            guard let sibling else { continue }
            let name = sibling.application.displayName
            var reason = "Installed and updated with \(name)."
            if case let .available(version, _) = sibling.check.outcome { reason += " \(name) \(version) is available." }
            replacements[check.path] = NativeUpdateCheck(
                path: check.path, authority: .bundled, installedVersionKey: check.installedVersionKey, outcome: .unchecked(reason))
        }
        return checks.map { replacements[$0.path] ?? $0 }
    }

    private var homeApplicationsPath: String { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications").path }

    // MARK: - Homebrew

    private struct HomebrewInventoryPhase: Sendable {
        let inventory: HomebrewInventory
        let packages: [HomebrewPackage]
        let retained: Bool
        let targets: [HomebrewPackageKey: HomebrewTargetResolution]
        let results: [ProviderRefreshResult]
    }

    private struct HomebrewPhase: Sendable {
        let inventory: HomebrewInventory
        let targets: [HomebrewPackageKey: HomebrewTargetResolution]
        let notes: [HomebrewPackageKey: HomebrewReleaseNotesResolution]
        let results: [ProviderRefreshResult]
    }

    private func homebrewPhase(clock: RefreshClock, update: HomebrewUpdatePolicy, progress: (@Sendable (String) -> Void)?) -> HomebrewInventoryPhase {
        let inventoryStartedAt = clock.now()
        let inventory = homebrewProvider.discover(update: update, now: inventoryStartedAt, snapshots: database, progress: progress)
        let inventoryFinishedAt = clock.now()
        // A transient local read failure here (lock contention, a momentary I/O error) shouldn't
        // discard all the discovery work already done this run; fall back to "not known to be
        // retained" and let the rest of the refresh proceed and persist normally.
        let retained = inventory.availability == .absent && ((try? database.hasActiveHomebrewPackages()) ?? false)
        let packages = inventory.availability == .detected ? inventory.packages : []

        let targetsStartedAt = clock.now()
        let targets = resolveTargets(packages: packages, inventory: inventory)
        let targetsFinishedAt = clock.now()

        let results = [
            homebrewInventoryResult(inventory, retained: retained, startedAt: inventoryStartedAt, finishedAt: inventoryFinishedAt),
            homebrewTargetsResult(inventory, targets: targets, retained: retained, startedAt: targetsStartedAt, finishedAt: targetsFinishedAt)
        ]
        return HomebrewInventoryPhase(inventory: inventory, packages: packages, retained: retained, targets: targets, results: results)
    }

    /// An app whose bundle or executable is a symlink into `<prefix>/Caskroom/<token>/` or
    /// `<prefix>/Cellar/<formula>/` was installed by that package (Claude Code's URL handler links
    /// its executable into the claude-code cask), so the package owns it like a cask artifact.
    private func attributingLinkedApplications(_ phase: HomebrewInventoryPhase, applications: [NativeApplication]) -> HomebrewInventoryPhase {
        let linked = applications.filter { !$0.linkTargets.isEmpty }
        guard !linked.isEmpty else { return phase }
        func owned(by package: HomebrewPackage) -> [String] {
            let directory = "\(package.prefix)/\(package.kind == .cask ? "Caskroom" : "Cellar")/\(package.name)/"
            return linked.filter { $0.linkTargets.contains { $0.hasPrefix(directory) } }.map(\.path)
        }
        let prefixes = phase.inventory.prefixes.map { prefix in
            HomebrewPrefixInventory(
                prefix: prefix.prefix,
                packages: prefix.packages.map { package in
                    let paths = owned(by: package)
                    return paths.isEmpty ? package : package.addingArtifacts(paths)
                }, complete: prefix.complete, outdatedCandidates: prefix.outdatedCandidates, outdatedComplete: prefix.outdatedComplete,
                warnings: prefix.warnings)
        }
        let inventory = HomebrewInventory(availability: phase.inventory.availability, prefixes: prefixes)
        return HomebrewInventoryPhase(
            inventory: inventory, packages: inventory.availability == .detected ? inventory.packages : [], retained: phase.retained, targets: phase.targets,
            results: phase.results)
    }

    private func homebrewNotesPhase(clock: RefreshClock, inventory phase: HomebrewInventoryPhase) -> HomebrewPhase {
        let startedAt = clock.now()
        let notes = resolveReleaseNotes(packages: phase.packages, targets: phase.targets)
        let result = homebrewNotesResult(notes, retained: phase.retained, startedAt: startedAt, finishedAt: clock.now())
        return HomebrewPhase(inventory: phase.inventory, targets: phase.targets, notes: notes, results: phase.results + [result])
    }

    private func resolveTargets(packages: [HomebrewPackage], inventory: HomebrewInventory) -> [HomebrewPackageKey: HomebrewTargetResolution] {
        var targets: [HomebrewPackageKey: HomebrewTargetResolution] = [:]
        for package in packages {
            // `brew outdated --json=v2` does not report a tap-qualified full name, only the short
            // name, so candidates are matched on short name; Homebrew enforces name uniqueness per
            // prefix, so a genuine cross-tap collision is the one case this can't disambiguate, and
            // it surfaces as "not reported as outdated" rather than a guess.
            let outdatedCandidates = inventory.prefixes.first(where: { $0.prefix == package.prefix })?.outdatedCandidates ?? []
            let sameFormula = outdatedCandidates.filter { $0.kind == package.kind && $0.name == package.name }
            let key = HomebrewPackageKey(package)
            if let candidate = sameFormula.first(where: { $0.installedVersions.contains(package.installedVersion) }) {
                if package.autoUpdates, bundlesAlreadyUpdated(package, to: candidate.availableVersion) {
                    targets[key] = .unavailable("The application has already updated itself to the latest version.")
                } else {
                    targets[key] = .resolved(HomebrewTarget(version: candidate.availableVersion, sourceURL: package.sourceURL))
                }
            } else if !sameFormula.isEmpty {
                // `info --installed` and `outdated` are separate `brew` invocations; Homebrew reports
                // this package as outdated but for a different installed version than `info` just
                // reported (e.g. another process upgraded it mid-refresh). That inconsistency makes
                // this round's target untrustworthy, not "confirmed no update" — treat it like a
                // transient failure so the previously cached target/available version survives.
                targets[key] = .transientFailure("Homebrew's info and outdated snapshots reported different installed versions for this package.")
            } else {
                targets[key] = .unavailable("Homebrew does not report this package as outdated.")
            }
        }
        return targets
    }

    /// A self-updating cask's recorded version goes stale as soon as the app updates itself, so
    /// Homebrew reports it as outdated indefinitely. The installed bundles are the authority: when
    /// every app artifact already carries the cask's latest version, or a newer user-facing version
    /// (the catalog can lag the vendor), there is nothing to update. Build numbers only count when
    /// equal: they're on a different scale from the cask's version. Casks without app artifacts
    /// (pkg installers) can't be checked and keep Homebrew's answer.
    private func bundlesAlreadyUpdated(_ package: HomebrewPackage, to availableVersion: String) -> Bool {
        guard !package.artifactPaths.isEmpty else { return false }
        let upstream = HomebrewVersion.caskUpstreamVersion(from: availableVersion)
        let latest: Set = [availableVersion, upstream]
        return package.artifactPaths.allSatisfy { path in
            let (short, build) = bundleVersions(at: path)
            if [short, build].contains(where: { $0.map(latest.contains) == true }) { return true }
            return short.map { SparkleVersion.compare($0, upstream) == .orderedDescending } == true
        }
    }

    private func bundleVersions(at path: String) -> (short: String?, build: String?) {
        let plistURL = URL(filePath: path).appending(path: "Contents/Info.plist")
        guard let values = try? plistURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
            (values.fileSize ?? .max) <= 1_048_576,
            let data = try? Data(contentsOf: plistURL),
            let metadata = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return (nil, nil) }
        return ((metadata["CFBundleShortVersionString"] as? String)?.nonEmpty, (metadata["CFBundleVersion"] as? String)?.nonEmpty)
    }

    private func resolveReleaseNotes(packages: [HomebrewPackage], targets: [HomebrewPackageKey: HomebrewTargetResolution]) -> [HomebrewPackageKey:
        HomebrewReleaseNotesResolution]
    {
        var notes: [HomebrewPackageKey: HomebrewReleaseNotesResolution] = [:]
        var pending: [(key: HomebrewPackageKey, package: HomebrewPackage, target: HomebrewTarget)] = []
        for package in packages {
            let key = HomebrewPackageKey(package)
            guard case let .resolved(target)? = targets[key], target.version != package.installedVersion else { continue }
            if package.kind == .formula, target.upstreamVersion == HomebrewVersion.upstreamVersion(from: package.installedVersion) {
                notes[key] = .unavailable("This update changes only Homebrew's packaging revision.")
                continue
            }
            // If this cache lookup fails, treat it as "no cached notes found" rather than aborting
            // the whole refresh — worst case is one redundant fetch, not lost work.
            let cached = try? database.homebrewReleaseNotes(
                prefix: package.prefix, kind: package.kind, fullName: package.fullName, installedVersion: package.installedVersion,
                availableVersion: target.version)
            if (cached ?? nil) == nil { pending.append((key, package, target)) }
        }
        // Each fetch is an independent round-trip dominated by network latency; MetadataHTTPClient's
        // own GitHub semaphore bounds how many requests are actually in flight at once.
        let resolver = releaseNotes
        let fetched = pending.map { item in Concurrent { (item.key, resolver.resolveReleaseNotes(for: item.package, target: item.target)) } }
        for result in fetched { notes[result.value.0] = result.value.1 }
        return notes
    }

    private func homebrewInventoryResult(_ inventory: HomebrewInventory, retained: Bool, startedAt: Date, finishedAt: Date) -> ProviderRefreshResult {
        let status: ProviderRefreshStatus
        let message: String?
        let dataAsOf: Date?
        switch inventory.availability {
        case .absent:
            status = retained ? .partial : .success
            message = retained ? "No Homebrew executable was found; cached Homebrew data was retained." : "No Homebrew executable was found."
            dataAsOf = retained ? nil : finishedAt
        case .detected:
            let completePrefixes = inventory.prefixes.filter(\.complete).count
            status = completePrefixes == inventory.prefixes.count ? .success : completePrefixes > 0 ? .partial : .failure
            message = inventory.warnings.nonEmptyJoined
            dataAsOf = completePrefixes == inventory.prefixes.count ? finishedAt : nil
        }
        let warningCount = inventory.warnings.count + (inventory.availability == .absent ? 1 : 0)
        return ProviderRefreshResult(
            provider: .homebrewInventory, status: status, message: message, warningCount: warningCount, startedAt: startedAt, finishedAt: finishedAt,
            dataAsOf: dataAsOf)
    }

    private func homebrewTargetsResult(
        _ inventory: HomebrewInventory, targets: [HomebrewPackageKey: HomebrewTargetResolution], retained: Bool, startedAt: Date, finishedAt: Date
    ) -> ProviderRefreshResult {
        if retained {
            return ProviderRefreshResult(
                provider: .homebrewTargets, status: .partial, message: "Cached Homebrew target data was retained because Homebrew is not available.",
                warningCount: 1, startedAt: startedAt, finishedAt: finishedAt, dataAsOf: nil)
        }
        if inventory.prefixes.contains(where: { !$0.outdatedComplete }) {
            return ProviderRefreshResult(
                provider: .homebrewTargets, status: .partial, message: "Homebrew did not return a complete outdated-package snapshot.", warningCount: 1,
                startedAt: startedAt, finishedAt: finishedAt, dataAsOf: nil)
        }
        return resolutionResult(provider: .homebrewTargets, targets.values, startedAt: startedAt, finishedAt: finishedAt)
    }

    private func homebrewNotesResult(_ notes: [HomebrewPackageKey: HomebrewReleaseNotesResolution], retained: Bool, startedAt: Date, finishedAt: Date)
        -> ProviderRefreshResult
    {
        if retained {
            return ProviderRefreshResult(
                provider: .homebrewReleaseNotes, status: .partial, message: "Cached Homebrew release notes were retained because Homebrew is not available.",
                warningCount: 1, startedAt: startedAt, finishedAt: finishedAt, dataAsOf: nil)
        }
        return resolutionResult(provider: .homebrewReleaseNotes, notes.values, startedAt: startedAt, finishedAt: finishedAt)
    }

    /// Success when nothing failed transiently, failure when everything did, partial otherwise.
    private func resolutionResult<T>(provider: RefreshProvider, _ values: T, startedAt: Date, finishedAt: Date) -> ProviderRefreshResult
    where T: Collection, T.Element: HomebrewResolutionSummarizable {
        let failures = values.compactMap(\.resolutionBucket.transientFailureMessage)
        let status: ProviderRefreshStatus = failures.isEmpty ? .success : failures.count == values.count ? .failure : .partial
        return ProviderRefreshResult(
            provider: provider, status: status, message: failures.nonEmptyJoined, warningCount: failures.count, startedAt: startedAt, finishedAt: finishedAt,
            dataAsOf: failures.isEmpty ? finishedAt : nil)
    }

    // MARK: - npm and uv

    private typealias ManagedPhase = (inventory: ManagedPackageInventory?, result: ProviderRefreshResult)

    private func npmPhase(clock: RefreshClock) -> ManagedPhase {
        let startedAt = clock.now()
        let discovered = npmGlobalProvider.discover()
        let scopes = discovered.prefixes.map { prefix in
            ManagedPackageScope(
                scope: prefix.prefix,
                packages: managedPackages(
                    prefix.packages.map { ($0.name, $0.installedVersion) },
                    candidates: prefix.updateCandidates.map { ($0.name, $0.installedVersion, $0.latestVersion) }), outdatedDataComplete: prefix.outdatedComplete
            )
        }
        return managedPhase(
            provider: .npmGlobal, scopes: scopes, warnings: discovered.warnings,
            retainedMessage: "No npm executable was found; cached npm-global data was retained.", startedAt: startedAt, finishedAt: clock.now())
    }

    private func uvPhase(clock: RefreshClock) -> ManagedPhase {
        let startedAt = clock.now()
        let discovered = uvToolProvider.discover()
        let scopes = discovered.installations.map { installation in
            ManagedPackageScope(
                scope: installation.toolDirectory,
                packages: managedPackages(
                    installation.tools.map { ($0.name, $0.installedVersion) },
                    candidates: installation.outdatedTools.map { ($0.name, $0.installedVersion, $0.latestVersion) }),
                outdatedDataComplete: installation.outdatedComplete)
        }
        return managedPhase(
            provider: .uvTools, scopes: scopes, warnings: discovered.warnings, retainedMessage: "No uv executable was found; cached uv-tool data was retained.",
            startedAt: startedAt, finishedAt: clock.now())
    }

    private func steamPhase(clock: RefreshClock) -> ManagedPhase {
        let startedAt = clock.now()
        let discovered = steamProvider.discover()
        let scopes = discovered.libraries.map { library in
            ManagedPackageScope(
                scope: library.path,
                packages: library.games.map { game in
                    ManagedPackage(
                        name: game.name, installedVersion: game.buildID, availableVersion: game.pendingBuildID, selfUpdating: true, identifier: game.appID)
                })
        }
        return managedPhase(
            provider: .steamGames, scopes: discovered.detected ? scopes : [], warnings: discovered.warnings,
            retainedMessage: "Steam was not found; cached Steam data was retained.", startedAt: startedAt, finishedAt: clock.now())
    }

    private func macPortsPhase(clock: RefreshClock) -> ManagedPhase {
        let startedAt = clock.now()
        let discovered = macPortsProvider.discover()
        var warnings = discovered.warnings
        var notes: [String] = []
        // A local index more than a week old (MacPorts can't sync after a macOS upgrade until it's
        // reinstalled) misses every update since: the online port database answers instead.
        var online: [String: MacPortsIndexEntry] = [:]
        let stale = discovered.indexDate.map { clock.now().timeIntervalSince($0) > 7 * 24 * 60 * 60 } ?? true
        if discovered.prefix != nil, stale, !discovered.ports.isEmpty {
            let client = metadataClient
            let lookups = discovered.ports.map { port in
                Concurrent {
                    MacPortsProvider.apiURL(for: port.name).flatMap { try? client.fetch($0, resource: .macPortsPort).body }.flatMap(MacPortsProvider.apiEntry)
                }
            }
            for (port, lookup) in zip(discovered.ports, lookups) { if let entry = lookup.value { online[port.name] = entry } }
            let age = discovered.indexDate.map { " is \(Int(clock.now().timeIntervalSince($0) / 86_400)) days old" } ?? " is missing"
            // Every port answered: the data is complete, and the stale index is only worth a note.
            if online.count == discovered.ports.count {
                notes.append("MacPorts' port index\(age); checked ports.macports.org instead. Run 'sudo port selfupdate' to sync it.")
            } else {
                warnings.append(
                    "MacPorts' port index\(age); checked ports.macports.org instead (\(online.count) of \(discovered.ports.count) ports). Run 'sudo port selfupdate' to sync it."
                )
            }
        }
        let scopes =
            discovered.prefix.map { prefix in
                [
                    ManagedPackageScope(
                        scope: prefix,
                        packages: discovered.ports.map { port in
                            // The online version, with the installed revision when it's the same version (the API has no revision).
                            let fresh = online[port.name].map { entry in
                                entry.version == port.version && entry.epoch == port.epoch
                                    ? MacPortsIndexEntry(
                                        epoch: entry.epoch, version: entry.version,
                                        revision: max(port.revision, discovered.index[port.name].map { $0.version == entry.version ? $0.revision : 0 } ?? 0))
                                    : entry
                            }
                            let latest = (fresh ?? discovered.index[port.name]).flatMap {
                                MacPortsProvider.isOutdated(port, index: $0) ? $0.displayVersion : nil
                            }
                            return ManagedPackage(
                                name: port.name, installedVersion: port.displayVersion, availableVersion: latest, requested: port.requested,
                                applicationPaths: port.applicationPaths)
                        }, outdatedDataComplete: discovered.indexAvailable || !online.isEmpty)
                ]
            } ?? []
        return managedPhase(
            provider: .macPorts, scopes: scopes, warnings: warnings, notes: notes,
            retainedMessage: "MacPorts was not found; cached MacPorts data was retained.", startedAt: startedAt, finishedAt: clock.now())
    }

    /// Installed crates from cargo's own record; latest versions from crates.io's sparse index,
    /// one small cached request per crate.
    private func cargoPhase(clock: RefreshClock) -> ManagedPhase {
        let startedAt = clock.now()
        let discovered = cargoProvider.discover()
        let client = metadataClient
        let lookups = discovered.crates.map { crate in
            Concurrent { () -> Result<String?, Error> in
                guard let url = CargoProvider.indexURL(for: crate.name) else { return .success(nil) }
                return Result { CargoProvider.latestVersion(indexData: try client.fetch(url, resource: .cratesIndex).body, installed: crate.version) }
            }
        }
        var warnings = discovered.warnings
        let packages = zip(discovered.crates, lookups).map { crate, lookup -> ManagedPackage in
            switch lookup.value {
            case let .success(latest):
                let newer = latest.flatMap { SemanticVersion.compare($0, crate.version) == .orderedDescending ? $0 : nil }
                return ManagedPackage(name: crate.name, installedVersion: crate.version, availableVersion: newer)
            case let .failure(error):
                warnings.append("crates.io index for \(crate.name): \(error.localizedDescription)")
                // Unknown this round: keep the previously cached answer.
                return ManagedPackage(name: crate.name, installedVersion: crate.version, isVersionConsistent: false)
            }
        }
        let scopes = discovered.cargoHome.map { [ManagedPackageScope(scope: $0, packages: packages)] } ?? []
        return managedPhase(
            provider: .cargo, scopes: scopes, warnings: warnings, retainedMessage: "Cargo's install record was not found; cached cargo data was retained.",
            startedAt: startedAt, finishedAt: clock.now())
    }

    /// Pairs each listed package with its outdated-check candidate. Listing and the outdated check
    /// are separate subprocess calls, so if a package's installed version differs between the two
    /// (e.g. another process updated it mid-refresh), only that package's available version is
    /// untrustworthy — it's marked inconsistent so it can't block updates for the rest of the scope.
    private func managedPackages(
        _ packages: [(name: String, installedVersion: String)], candidates: [(name: String, installedVersion: String, latestVersion: String?)]
    ) -> [ManagedPackage] {
        let candidatesByName = Dictionary(candidates.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return packages.map { package in
            guard let candidate = candidatesByName[package.name] else {
                return ManagedPackage(name: package.name, installedVersion: package.installedVersion, availableVersion: nil, isVersionConsistent: true)
            }
            let isConsistent = candidate.installedVersion == package.installedVersion
            return ManagedPackage(
                name: package.name, installedVersion: package.installedVersion, availableVersion: isConsistent ? candidate.latestVersion : nil,
                isVersionConsistent: isConsistent)
        }
    }

    /// No executables and no failures means the tool isn't installed at all, distinct from
    /// "installed but found nothing"; previously cached data is then retained as `.partial` rather
    /// than discarded. A provider that fails outright contributes no inventory.
    /// `notes` are shown with the result without making it partial (the data is complete).
    private func managedPhase(
        provider: RefreshProvider, scopes: [ManagedPackageScope], warnings: [String], notes: [String] = [], retainedMessage: String, startedAt: Date,
        finishedAt: Date
    ) -> ManagedPhase {
        let absent = scopes.isEmpty && warnings.isEmpty
        let retained = absent && ((try? database.hasActiveManagedPackages(provider: provider)) ?? false)
        let status: ProviderRefreshStatus = retained ? .partial : warnings.isEmpty ? .success : scopes.isEmpty ? .failure : .partial
        let result = ProviderRefreshResult(
            provider: provider, status: status, message: retained ? retainedMessage : (warnings + notes).nonEmptyJoined,
            warningCount: retained ? 1 : warnings.count, startedAt: startedAt, finishedAt: finishedAt, dataAsOf: status == .success ? finishedAt : nil)
        return (status == .failure ? nil : ManagedPackageInventory(provider: provider, scopes: scopes), result)
    }
}

/// Every provider timestamp comes from this instead of a raw `Date.now` read: readings are
/// monotonically non-decreasing and never earlier than the refresh's start, closing off a backward
/// system-clock jump (NTP correction, sleep/wake) mid-refresh. Database.validateRefreshInput
/// requires every provider's startedAt >= the refresh's own startedAt and rejects the entire
/// refresh otherwise.
private final class RefreshClock: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Date

    init(start: Date) { latest = start }

    func now() -> Date {
        lock.withLock {
            latest = max(latest, .now)
            return latest
        }
    }
}

private extension Array where Element == String {
    var nonEmptyJoined: String? { joined(separator: "\n").nonEmpty }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
