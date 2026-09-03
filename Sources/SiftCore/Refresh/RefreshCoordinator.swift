import Foundation

public struct RefreshCoordinator {
    private let database: Database
    private let nativeProvider: NativeApplicationProvider
    private let homebrewProvider: HomebrewProvider
    private let npmGlobalProvider: NPMGlobalProvider
    private let uvToolProvider: UVToolProvider
    private let releaseNotes: any HomebrewReleaseNotesResolving

    public init(database: Database, nativeProvider: NativeApplicationProvider = NativeApplicationProvider(), homebrewProvider: HomebrewProvider = HomebrewProvider(), npmGlobalProvider: NPMGlobalProvider = NPMGlobalProvider(), uvToolProvider: UVToolProvider = UVToolProvider(), releaseNotes: (any HomebrewReleaseNotesResolving)? = nil) {
        self.database = database
        self.nativeProvider = nativeProvider
        self.homebrewProvider = homebrewProvider
        self.npmGlobalProvider = npmGlobalProvider
        self.uvToolProvider = uvToolProvider
        let metadataClient = MetadataHTTPClient(database: database)
        self.releaseNotes = releaseNotes ?? ReleaseNotesResolver(metadataClient: metadataClient)
    }

    public func refresh(now: Date = .now, updateHomebrew: Bool = false) throws -> RefreshSummary {
        let nativeStartedAt = now
        let native = nativeProvider.discover()
        let nativeFinishedAt = now

        let homebrewStartedAt = Date.now
        if updateHomebrew { try homebrewProvider.update() }
        let homebrew = homebrewProvider.discover()
        let homebrewFinishedAt = Date.now
        let hasActiveHomebrewPackages = try database.hasActiveHomebrewPackages()
        let retainedHomebrewData = homebrew.availability == .absent && hasActiveHomebrewPackages
        let packages = homebrew.availability == .detected ? homebrew.packages : []

        let targetStartedAt = Date.now
        var targetResults: [HomebrewPackageKey: HomebrewTargetResolution] = [:]
        for package in packages {
            let candidate = homebrew.prefixes.first(where: { $0.prefix == package.prefix })?.outdatedCandidates.first {
                $0.kind == package.kind && $0.name == package.name && $0.installedVersion == package.installedVersion
            }
            if let candidate {
                targetResults[HomebrewPackageKey(package)] = .resolved(HomebrewTarget(version: candidate.availableVersion, sourceURL: package.sourceURL))
            } else {
                targetResults[HomebrewPackageKey(package)] = .unavailable("Homebrew does not report this package as outdated.")
            }
        }
        let targetFinishedAt = Date.now

        let notesStartedAt = Date.now
        var noteResults: [HomebrewPackageKey: HomebrewReleaseNotesResolution] = [:]
        for package in packages {
            let key = HomebrewPackageKey(package)
            guard case let .resolved(target)? = targetResults[key], target.version != package.installedVersion else { continue }
            if package.kind == .formula,
               target.upstreamVersion == HomebrewVersion.upstreamVersion(from: package.installedVersion) {
                noteResults[key] = .unavailable("This update changes only Homebrew's packaging revision.")
                continue
            }
            if try database.homebrewReleaseNotes(prefix: package.prefix, kind: package.kind, fullName: package.fullName, installedVersion: package.installedVersion, availableVersion: target.version) == nil {
                noteResults[key] = releaseNotes.resolveReleaseNotes(for: package, target: target)
            }
        }
        let notesFinishedAt = Date.now

        let npmStartedAt = Date.now
        let npmInventory: ManagedPackageInventory?
        let npmResult: ProviderRefreshResult
        do {
            let discovered = try npmGlobalProvider.discover()
            npmInventory = ManagedPackageInventory(provider: .npmGlobal, scopes: discovered.prefixes.map { prefix in
                let updates = Dictionary(uniqueKeysWithValues: prefix.updateCandidates.map { ($0.name, $0.latestVersion) })
                // npm is its own runtime, not a user-installed global tool.
                return ManagedPackageScope(scope: prefix.prefix, packages: prefix.packages.filter { $0.name != "npm" }.map { ManagedPackage(name: $0.name, installedVersion: $0.installedVersion, availableVersion: updates[$0.name]) })
            })
            let finishedAt = Date.now
            npmResult = ProviderRefreshResult(provider: .npmGlobal, status: .success, startedAt: npmStartedAt, finishedAt: finishedAt, dataAsOf: finishedAt)
        } catch {
            npmInventory = nil
            let finishedAt = Date.now
            npmResult = ProviderRefreshResult(provider: .npmGlobal, status: .failure, message: error.localizedDescription, warningCount: 1, startedAt: npmStartedAt, finishedAt: finishedAt)
        }

        let uvStartedAt = Date.now
        let uvInventory: ManagedPackageInventory?
        let uvResult: ProviderRefreshResult
        do {
            let discovered = try uvToolProvider.discover()
            uvInventory = ManagedPackageInventory(provider: .uvTools, scopes: discovered.installations.map { installation in
                let updates = Dictionary(uniqueKeysWithValues: installation.outdatedTools.compactMap { tool in tool.latestVersion.map { (tool.name, $0) } })
                return ManagedPackageScope(scope: installation.toolDirectory, packages: installation.tools.map { ManagedPackage(name: $0.name, installedVersion: $0.installedVersion, availableVersion: updates[$0.name]) })
            })
            let finishedAt = Date.now
            uvResult = ProviderRefreshResult(provider: .uvTools, status: .success, startedAt: uvStartedAt, finishedAt: finishedAt, dataAsOf: finishedAt)
        } catch {
            uvInventory = nil
            let finishedAt = Date.now
            uvResult = ProviderRefreshResult(provider: .uvTools, status: .failure, message: error.localizedDescription, warningCount: 1, startedAt: uvStartedAt, finishedAt: finishedAt)
        }

        let providerResults = [
            ProviderRefreshResult(provider: .nativeApplications, status: native.complete ? .success : .partial, message: native.warnings.nonEmptyJoined, warningCount: native.warnings.count, startedAt: nativeStartedAt, finishedAt: nativeFinishedAt, dataAsOf: native.complete ? nativeFinishedAt : nil),
            ProviderRefreshResult(provider: .homebrewInventory, status: inventoryStatus(homebrew, retainedData: retainedHomebrewData), message: homebrewMessage(homebrew, retainedData: retainedHomebrewData), warningCount: homebrew.warnings.count + (homebrew.availability == .absent ? 1 : 0), startedAt: homebrewStartedAt, finishedAt: homebrewFinishedAt, dataAsOf: homebrew.availability == .absent ? (retainedHomebrewData ? nil : homebrewFinishedAt) : homebrew.prefixes.allSatisfy(\.complete) ? homebrewFinishedAt : nil),
            ProviderRefreshResult(provider: .homebrewTargets, status: retainedHomebrewData || homebrew.prefixes.contains(where: { !$0.outdatedComplete }) ? .partial : resolutionStatus(targetResults.values), message: retainedHomebrewData ? "Cached Homebrew target data was retained because Homebrew is not available." : homebrew.prefixes.contains(where: { !$0.outdatedComplete }) ? "Homebrew did not return a complete outdated-package snapshot." : transientMessages(targetResults.values), warningCount: retainedHomebrewData ? 1 : homebrew.prefixes.contains(where: { !$0.outdatedComplete }) ? 1 : transientCount(targetResults.values), startedAt: targetStartedAt, finishedAt: targetFinishedAt, dataAsOf: retainedHomebrewData || homebrew.prefixes.contains(where: { !$0.outdatedComplete }) ? nil : targetFinishedAt),
            ProviderRefreshResult(provider: .homebrewReleaseNotes, status: retainedHomebrewData ? .partial : resolutionStatus(noteResults.values), message: retainedHomebrewData ? "Cached Homebrew release notes were retained because Homebrew is not available." : transientMessages(noteResults.values), warningCount: retainedHomebrewData ? 1 : transientCount(noteResults.values), startedAt: notesStartedAt, finishedAt: notesFinishedAt, dataAsOf: retainedHomebrewData ? nil : noteResults.values.contains { if case .transientFailure = $0 { true } else { false } } ? nil : notesFinishedAt),
            npmResult,
            uvResult,
        ]
        return try database.applyRefresh(RefreshPersistenceInput(startedAt: now, finishedAt: max(notesFinishedAt, max(npmResult.finishedAt, uvResult.finishedAt)), nativeInventory: native, homebrewInventory: homebrew, targetResults: targetResults, releaseNoteResults: noteResults, managedPackageInventories: [npmInventory, uvInventory].compactMap { $0 }, providerResults: providerResults))
    }

    private func inventoryStatus(_ inventory: HomebrewInventory, retainedData: Bool) -> ProviderRefreshStatus {
        if inventory.availability == .absent { return retainedData ? .partial : .success }
        guard !inventory.prefixes.isEmpty else { return .success }
        if inventory.prefixes.allSatisfy(\.complete) { return .success }
        return inventory.prefixes.contains(where: \.complete) ? .partial : .failure
    }

    private func homebrewMessage(_ inventory: HomebrewInventory, retainedData: Bool) -> String? {
        if inventory.availability == .absent { return retainedData ? "No Homebrew executable was found; cached Homebrew data was retained." : "No Homebrew executable was found." }
        return inventory.warnings.nonEmptyJoined
    }

    private func resolutionStatus<T>(_ results: T) -> ProviderRefreshStatus where T: Collection, T.Element == HomebrewTargetResolution {
        let values = Array(results)
        guard !values.isEmpty else { return .success }
        let failures = values.filter { if case .transientFailure = $0 { true } else { false } }
        return failures.isEmpty ? .success : failures.count == values.count ? .failure : .partial
    }

    private func resolutionStatus<T>(_ results: T) -> ProviderRefreshStatus where T: Collection, T.Element == HomebrewReleaseNotesResolution {
        let values = Array(results)
        guard !values.isEmpty else { return .success }
        let failures = values.filter { if case .transientFailure = $0 { true } else { false } }
        return failures.isEmpty ? .success : failures.count == values.count ? .failure : .partial
    }

    private func transientCount<T>(_ results: T) -> Int where T: Collection, T.Element == HomebrewTargetResolution {
        results.filter { if case .transientFailure = $0 { true } else { false } }.count
    }

    private func transientCount<T>(_ results: T) -> Int where T: Collection, T.Element == HomebrewReleaseNotesResolution {
        results.filter { if case .transientFailure = $0 { true } else { false } }.count
    }

    private func transientMessages<T>(_ results: T) -> String? where T: Collection, T.Element == HomebrewTargetResolution {
        results.compactMap { if case let .transientFailure(message) = $0 { message } else { nil } }.joined(separator: "\n").nonEmpty
    }

    private func transientMessages<T>(_ results: T) -> String? where T: Collection, T.Element == HomebrewReleaseNotesResolution {
        results.compactMap { if case let .transientFailure(message) = $0 { message } else { nil } }.joined(separator: "\n").nonEmpty
    }

}

private extension Array where Element == String {
    var nonEmptyJoined: String? { joined(separator: "\n").nonEmpty }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
