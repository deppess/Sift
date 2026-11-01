import Foundation

public enum RefreshProvider: String, Codable, CaseIterable, Sendable {
    case nativeApplications = "native-apps"
    case homebrewInventory = "homebrew-inventory"
    case homebrewTargets = "homebrew-targets"
    case homebrewReleaseNotes = "homebrew-release-notes"
    case npmGlobal = "npm-global"
    case uvTools = "uv-tools"
    case nativeUpdates = "native-updates"
    case steamGames = "steam-games"
    case macPorts = "macports"
    case cargo = "cargo"

    /// Providers whose inventory is stored as managed packages.
    static let managedPackageProviders: Set<RefreshProvider> = [.npmGlobal, .uvTools, .steamGames, .macPorts, .cargo]
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

    public init(
        provider: RefreshProvider, status: ProviderRefreshStatus, message: String? = nil, warningCount: Int = 0, startedAt: Date, finishedAt: Date,
        dataAsOf: Date? = nil
    ) {
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

/// `HomebrewTargetResolution` and `HomebrewReleaseNotesResolution` share this case shape (they
/// differ only in what `.resolved` carries), so refresh-summary counting and status aggregation
/// are written once against this bucket rather than once per resolution type.
public enum HomebrewResolutionBucket: Sendable {
    case resolved, unsupported, unavailable
    case transientFailure(String)

    public var transientFailureMessage: String? {
        if case let .transientFailure(message) = self { message } else { nil }
    }
}

public protocol HomebrewResolutionSummarizable: Sendable {
    var resolutionBucket: HomebrewResolutionBucket { get }
}

extension HomebrewTargetResolution: HomebrewResolutionSummarizable {
    public var resolutionBucket: HomebrewResolutionBucket {
        switch self {
        case .resolved: .resolved
        case .unsupported: .unsupported
        case .unavailable: .unavailable
        case let .transientFailure(message): .transientFailure(message)
        }
    }
}

extension HomebrewReleaseNotesResolution: HomebrewResolutionSummarizable {
    public var resolutionBucket: HomebrewResolutionBucket {
        switch self {
        case .resolved: .resolved
        case .unsupported: .unsupported
        case .unavailable: .unavailable
        case let .transientFailure(message): .transientFailure(message)
        }
    }
}

public protocol HomebrewReleaseNotesResolving: Sendable {
    func resolveReleaseNotes(for package: HomebrewPackage, target: HomebrewTarget) -> HomebrewReleaseNotesResolution
}

public struct NativeReleaseNotes: Codable, Equatable, Sendable {
    public let content: String?
    public let sourceURL: String?

    public init(content: String?, sourceURL: String?) {
        self.content = content
        self.sourceURL = sourceURL
    }
}

/// The result of asking an application's update authority whether a newer version exists.
public enum NativeUpdateOutcome: Equatable, Sendable {
    case available(version: String, notes: NativeReleaseNotes?)
    case upToDate
    /// The authority can't be asked (no declared feed, not listed in the store); not an error.
    case unchecked(String)
    /// A transient failure; the previously cached answer is kept.
    case failed(String)
}

public struct NativeUpdateCheck: Equatable, Sendable {
    public let path: String
    public let authority: NativeUpdateAuthority
    /// The installed version the check compared against, in `Database.versionKey` form. An answer
    /// is only shown while the installation still has this version.
    public let installedVersionKey: String
    public let outcome: NativeUpdateOutcome
    /// How the answer was obtained, shown with the application (e.g. which cask supplied it).
    public let note: String?

    public init(path: String, authority: NativeUpdateAuthority, installedVersionKey: String, outcome: NativeUpdateOutcome, note: String? = nil) {
        self.note = note
        self.path = path
        self.authority = authority
        self.installedVersionKey = installedVersionKey
        self.outcome = outcome
    }
}

public struct RefreshPersistenceInput: Sendable {
    public let startedAt: Date
    public let finishedAt: Date
    public let nativeInventory: NativeInventoryResult
    public let homebrewInventory: HomebrewInventory
    public let targetResults: [HomebrewPackageKey: HomebrewTargetResolution]
    public let releaseNoteResults: [HomebrewPackageKey: HomebrewReleaseNotesResolution]
    public let managedPackageInventories: [ManagedPackageInventory]
    public let nativeUpdateChecks: [NativeUpdateCheck]
    public let providerResults: [ProviderRefreshResult]

    public init(
        startedAt: Date, finishedAt: Date, nativeInventory: NativeInventoryResult, homebrewInventory: HomebrewInventory,
        targetResults: [HomebrewPackageKey: HomebrewTargetResolution], releaseNoteResults: [HomebrewPackageKey: HomebrewReleaseNotesResolution],
        managedPackageInventories: [ManagedPackageInventory] = [], nativeUpdateChecks: [NativeUpdateCheck] = [], providerResults: [ProviderRefreshResult]
    ) {
        self.nativeUpdateChecks = nativeUpdateChecks
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.nativeInventory = nativeInventory
        self.homebrewInventory = homebrewInventory
        self.targetResults = targetResults
        self.releaseNoteResults = releaseNoteResults
        self.managedPackageInventories = managedPackageInventories
        self.providerResults = providerResults
    }
}

public struct ManagedPackage: Equatable, Sendable {
    public let name: String
    public let installedVersion: String
    public let availableVersion: String?
    // False when this package's installed version disagreed between the provider's inventory and
    // outdated-check calls this round (e.g. another process updated it mid-refresh). That mismatch
    // makes this package's availableVersion untrustworthy for this round only — Database must
    // preserve its previously cached value rather than clearing it, without affecting any other
    // package in the same scope.
    public let isVersionConsistent: Bool
    /// False for a dependency the user never asked for; hidden from default views.
    public let requested: Bool
    /// The provider installs updates by itself (Steam); listed, but not counted as needing action.
    public let selfUpdating: Bool
    /// Application bundles this package installed, which the package's provider then reports.
    public let applicationPaths: [String]
    /// The provider's own identifier when the name isn't one (a Steam app ID).
    public let identifier: String?

    public init(
        name: String, installedVersion: String, availableVersion: String? = nil, isVersionConsistent: Bool = true, requested: Bool = true,
        selfUpdating: Bool = false, applicationPaths: [String] = [], identifier: String? = nil
    ) {
        self.identifier = identifier
        self.requested = requested
        self.selfUpdating = selfUpdating
        self.applicationPaths = applicationPaths
        self.name = name
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.isVersionConsistent = isVersionConsistent
    }
}

public struct ManagedPackageScope: Equatable, Sendable {
    public let scope: String
    public let packages: [ManagedPackage]
    // False when this round's outdated-version check failed for this scope; a package's
    // nil availableVersion is then ambiguous ("unknown" vs. "confirmed not outdated") and
    // Database must preserve the previously cached value rather than clearing it.
    public let outdatedDataComplete: Bool

    public init(scope: String, packages: [ManagedPackage], outdatedDataComplete: Bool = true) {
        self.scope = scope
        self.packages = packages
        self.outdatedDataComplete = outdatedDataComplete
    }
}

public struct ManagedPackageInventory: Equatable, Sendable {
    public let provider: RefreshProvider
    public let scopes: [ManagedPackageScope]

    public init(provider: RefreshProvider, scopes: [ManagedPackageScope]) {
        self.provider = provider
        self.scopes = scopes
    }
}

public struct UnifiedUpdate: Codable, Equatable, Sendable {
    public let provider: String
    public let scope: String
    public let name: String
    public let installedVersion: String
    public let availableVersion: String
    public let freshness: Freshness
    public let dataAsOf: Date?
    /// The software updates itself (an auto-updating cask); listed for completeness, but counted
    /// separately from updates that need the user to act.
    public let selfUpdating: Bool

    public init(
        provider: String, scope: String, name: String, installedVersion: String, availableVersion: String, freshness: Freshness, dataAsOf: Date?,
        selfUpdating: Bool = false
    ) {
        self.selfUpdating = selfUpdating
        self.provider = provider
        self.scope = scope
        self.name = name
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.freshness = freshness
        self.dataAsOf = dataAsOf
    }
}
