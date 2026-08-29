import Foundation

public struct RefreshCoordinator {
    private let database: Database
    private let nativeProvider: NativeApplicationProvider
    private let homebrewProvider: HomebrewProvider
    private let homebrewAPI: any HomebrewTargetResolving
    private let releaseNotes: any HomebrewReleaseNotesResolving

    public init(database: Database, nativeProvider: NativeApplicationProvider = NativeApplicationProvider(), homebrewProvider: HomebrewProvider = HomebrewProvider(), homebrewAPI: (any HomebrewTargetResolving)? = nil, releaseNotes: (any HomebrewReleaseNotesResolving)? = nil) {
        self.database = database
        self.nativeProvider = nativeProvider
        self.homebrewProvider = homebrewProvider
        let metadataClient = MetadataHTTPClient(database: database)
        self.homebrewAPI = homebrewAPI ?? HomebrewAPI(metadataClient: metadataClient)
        self.releaseNotes = releaseNotes ?? ReleaseNotesResolver(metadataClient: metadataClient)
    }

    public func refresh(now: Date = .now) throws -> RefreshSummary {
        let nativeStartedAt = now
        let native = nativeProvider.discover()
        let nativeFinishedAt = now

        let homebrewStartedAt = now
        let homebrew = homebrewProvider.discover()
        let homebrewFinishedAt = now
        let hasActiveHomebrewPackages = try database.hasActiveHomebrewPackages()
        let retainedHomebrewData = homebrew.availability == .absent && hasActiveHomebrewPackages
        let actionablePackages = homebrew.availability == .detected ? homebrew.packages.filter { $0.ownership != .dependency } : []

        let targetStartedAt = now
        var targetResults: [HomebrewPackageKey: HomebrewTargetResolution] = [:]
        for package in actionablePackages {
            targetResults[HomebrewPackageKey(package)] = homebrewAPI.resolveTarget(for: package)
        }
        let targetFinishedAt = now

        let notesStartedAt = now
        var noteResults: [HomebrewPackageKey: HomebrewReleaseNotesResolution] = [:]
        for package in actionablePackages {
            let key = HomebrewPackageKey(package)
            guard case let .resolved(target)? = targetResults[key], target.version != package.installedVersion else { continue }
            if package.kind == .formula,
               target.upstreamVersion == HomebrewVersion.upstreamVersion(from: package.installedVersion) {
                noteResults[key] = .unavailable("This update changes only Homebrew's packaging revision.")
                continue
            }
            noteResults[key] = releaseNotes.resolveReleaseNotes(for: package, target: target)
        }
        let notesFinishedAt = now

        let providerResults = [
            ProviderRefreshResult(provider: .nativeApplications, status: native.complete ? .success : .partial, message: native.warnings.nonEmptyJoined, warningCount: native.warnings.count, startedAt: nativeStartedAt, finishedAt: nativeFinishedAt, dataAsOf: native.complete ? nativeFinishedAt : nil),
            ProviderRefreshResult(provider: .homebrewInventory, status: inventoryStatus(homebrew, retainedData: retainedHomebrewData), message: homebrewMessage(homebrew, retainedData: retainedHomebrewData), warningCount: homebrew.warnings.count + (homebrew.availability == .absent ? 1 : 0), startedAt: homebrewStartedAt, finishedAt: homebrewFinishedAt, dataAsOf: homebrew.availability == .absent ? (retainedHomebrewData ? nil : homebrewFinishedAt) : homebrew.prefixes.allSatisfy(\.complete) ? homebrewFinishedAt : nil),
            ProviderRefreshResult(provider: .homebrewTargets, status: retainedHomebrewData ? .partial : resolutionStatus(targetResults.values), message: retainedHomebrewData ? "Cached Homebrew target data was retained because Homebrew is not available." : transientMessages(targetResults.values), warningCount: retainedHomebrewData ? 1 : transientCount(targetResults.values), startedAt: targetStartedAt, finishedAt: targetFinishedAt, dataAsOf: retainedHomebrewData ? nil : targetResults.values.contains { if case .transientFailure = $0 { true } else { false } } ? nil : targetFinishedAt),
            ProviderRefreshResult(provider: .homebrewReleaseNotes, status: retainedHomebrewData ? .partial : resolutionStatus(noteResults.values), message: retainedHomebrewData ? "Cached Homebrew release notes were retained because Homebrew is not available." : transientMessages(noteResults.values), warningCount: retainedHomebrewData ? 1 : transientCount(noteResults.values), startedAt: notesStartedAt, finishedAt: notesFinishedAt, dataAsOf: retainedHomebrewData ? nil : noteResults.values.contains { if case .transientFailure = $0 { true } else { false } } ? nil : notesFinishedAt),
        ]
        return try database.applyRefresh(RefreshPersistenceInput(startedAt: now, finishedAt: notesFinishedAt, nativeInventory: native, homebrewInventory: homebrew, targetResults: targetResults, releaseNoteResults: noteResults, providerResults: providerResults))
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
