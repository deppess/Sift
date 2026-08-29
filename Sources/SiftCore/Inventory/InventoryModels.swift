import Foundation

public enum ApplicationClassification: String, Codable, Equatable, Sendable {
    case user
    case system
    case coreService
    case unknown
}

public struct NativeSearchRoot: Sendable, Equatable {
    public let url: URL
    public let classification: ApplicationClassification
    public let required: Bool

    public init(url: URL, classification: ApplicationClassification, required: Bool) {
        self.url = url
        self.classification = classification
        self.required = required
    }
}

public struct NativeApplication: Sendable, Equatable {
    public let path: String
    public let bundleIdentifier: String?
    public let displayName: String
    public let shortVersion: String?
    public let buildVersion: String?
    public let classification: ApplicationClassification
    public let discoveryRoot: String

    public init(path: String, bundleIdentifier: String?, displayName: String, shortVersion: String?, buildVersion: String?, classification: ApplicationClassification = .unknown, discoveryRoot: String = "") {
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.classification = classification
        self.discoveryRoot = discoveryRoot
    }
}

public struct NativeInventoryResult: Sendable {
    public let applications: [NativeApplication]
    public let warnings: [String]
    public let complete: Bool
    public let scannedRoots: [String]
    public let candidatePaths: Set<String>

    public init(applications: [NativeApplication], warnings: [String] = [], complete: Bool = true, scannedRoots: [String] = [], candidatePaths: Set<String> = []) {
        self.applications = applications
        self.warnings = warnings
        self.complete = complete
        self.scannedRoots = scannedRoots
        self.candidatePaths = candidatePaths
    }
}

public struct RefreshSummary: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let startedAt: Date
    public let finishedAt: Date
    public let status: RefreshStatus
    public let discoveredCount: Int
    public let addedCount: Int
    public let changedCount: Int
    public let unchangedCount: Int
    public let inactiveCount: Int
    public let homebrewDiscoveredCount: Int
    public let targetResolvedCount: Int
    public let targetUnsupportedCount: Int
    public let targetFailureCount: Int
    public let releaseNotesFetchedCount: Int
    public let releaseNotesFailureCount: Int
    public let providerResults: [ProviderRefreshResult]
    public let warningCount: Int

    public init(startedAt: Date, finishedAt: Date, status: RefreshStatus, discoveredCount: Int, addedCount: Int, changedCount: Int, unchangedCount: Int, inactiveCount: Int, homebrewDiscoveredCount: Int = 0, targetResolvedCount: Int = 0, targetUnsupportedCount: Int = 0, targetFailureCount: Int = 0, releaseNotesFetchedCount: Int = 0, releaseNotesFailureCount: Int = 0, providerResults: [ProviderRefreshResult] = [], warningCount: Int) {
        self.schemaVersion = 0
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.discoveredCount = discoveredCount
        self.addedCount = addedCount
        self.changedCount = changedCount
        self.unchangedCount = unchangedCount
        self.inactiveCount = inactiveCount
        self.homebrewDiscoveredCount = homebrewDiscoveredCount
        self.targetResolvedCount = targetResolvedCount
        self.targetUnsupportedCount = targetUnsupportedCount
        self.targetFailureCount = targetFailureCount
        self.releaseNotesFetchedCount = releaseNotesFetchedCount
        self.releaseNotesFailureCount = releaseNotesFailureCount
        self.providerResults = providerResults
        self.warningCount = warningCount
    }
}

public enum CatalogKind: String, Codable, Equatable, Sendable {
    case nativeApp
    case homebrewFormula
    case homebrewCask
}

public struct CatalogItem: Codable, Equatable, Sendable {
    public let selector: String
    public let aliases: [String]
    public let kind: CatalogKind
    public let name: String
    public let fullName: String?
    public let installedVersion: String?
    public let availableVersion: String?
    public let active: Bool
    public let bundleIdentifier: String?
    public let path: String?
    public let prefix: String?
    public let tap: String?
    public let ownership: String?
    public let autoUpdates: Bool
    public let observedAt: Date

    public var updateAvailable: Bool {
        availableVersion != nil && availableVersion != installedVersion
    }
}

public enum CatalogResolution: Equatable, Sendable {
    case item(CatalogItem)
    case missing
    case ambiguous([CatalogItem])
}
