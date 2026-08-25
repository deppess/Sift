import Foundation

public enum RefreshProvider: String, Codable, CaseIterable, Sendable {
    case nativeApplications = "native-apps"
    case homebrewInventory = "homebrew-inventory"
    case homebrewTargets = "homebrew-targets"
    case homebrewReleaseNotes = "homebrew-release-notes"
}

public enum ProviderRefreshStatus: String, Codable, Equatable, Sendable {
    case never
    case success
    case partial
    case failure
}

public struct ProviderRefreshResult: Codable, Equatable, Sendable {
    public let provider: RefreshProvider
    public let status: ProviderRefreshStatus
    public let message: String?
    public let warningCount: Int
    public let startedAt: Date
    public let finishedAt: Date
    public let dataAsOf: Date?

    public init(provider: RefreshProvider, status: ProviderRefreshStatus, message: String? = nil, warningCount: Int = 0, startedAt: Date, finishedAt: Date, dataAsOf: Date? = nil) {
        self.provider = provider
        self.status = status
        self.message = message
        self.warningCount = warningCount
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.dataAsOf = dataAsOf
    }
}

public struct HomebrewPackageKey: Hashable, Codable, Sendable {
    public let prefix: String
    public let kind: HomebrewPackageKind
    public let fullName: String

    public init(prefix: String, kind: HomebrewPackageKind, fullName: String) {
        self.prefix = prefix
        self.kind = kind
        self.fullName = fullName
    }

    public init(_ package: HomebrewPackage) {
        self.init(prefix: package.prefix, kind: package.kind, fullName: package.fullName)
    }

    public var stringValue: String { "\(prefix)|\(kind.rawValue)|\(fullName)" }
}

public enum HomebrewTargetResolution: Sendable {
    case resolved(HomebrewTarget)
    case unsupported(String)
    case unavailable(String)
    case transientFailure(String)
}

public enum HomebrewReleaseNotesResolution: Sendable {
    case resolved(HomebrewReleaseNotes)
    case unsupported(String)
    case unavailable(String)
    case transientFailure(String)
}

public protocol HomebrewTargetResolving: Sendable {
    func resolveTarget(for package: HomebrewPackage) -> HomebrewTargetResolution
}

public protocol HomebrewReleaseNotesResolving: Sendable {
    func resolveReleaseNotes(for package: HomebrewPackage, target: HomebrewTarget) -> HomebrewReleaseNotesResolution
}

public struct RefreshPersistenceInput: Sendable {
    public let startedAt: Date
    public let finishedAt: Date
    public let nativeInventory: NativeInventoryResult
    public let homebrewInventory: HomebrewInventory
    public let targetResults: [HomebrewPackageKey: HomebrewTargetResolution]
    public let releaseNoteResults: [HomebrewPackageKey: HomebrewReleaseNotesResolution]
    public let providerResults: [ProviderRefreshResult]

    public init(startedAt: Date, finishedAt: Date, nativeInventory: NativeInventoryResult, homebrewInventory: HomebrewInventory, targetResults: [HomebrewPackageKey: HomebrewTargetResolution], releaseNoteResults: [HomebrewPackageKey: HomebrewReleaseNotesResolution], providerResults: [ProviderRefreshResult]) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.nativeInventory = nativeInventory
        self.homebrewInventory = homebrewInventory
        self.targetResults = targetResults
        self.releaseNoteResults = releaseNoteResults
        self.providerResults = providerResults
    }
}
