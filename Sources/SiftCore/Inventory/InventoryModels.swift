import Foundation

public enum ApplicationClassification: String, Codable, Equatable, Sendable {
    case user
    case system
    case coreService
    /// A bundle outside the standard application roots that isn't independently installed by the
    /// user: helpers kept in Application Support, cached updaters, development build products.
    case auxiliary
    /// A launcher shim that opens other software (e.g. a Steam desktop shortcut), not an install.
    case launcher
    case unknown
}

/// Who delivers updates for a native application, detected from the bundle itself. This is
/// independent of how the app was installed: a Homebrew cask is reported by the Homebrew provider.
public enum NativeUpdateAuthority: String, Codable, Equatable, Sendable {
    /// Purchased through the Mac App Store (the bundle carries a `_MASReceipt`).
    case appStore
    /// Embeds the Sparkle framework; checkable only when the bundle declares its feed (`SUFeedURL`).
    case sparkle
    /// Installed and updated by Steam.
    case steam
    /// An Apple application delivered with macOS updates.
    case apple
    /// Blackmagic Design's software, which checks Blackmagic's public downloads feed.
    case blackmagic
    /// Installed and updated by the Setapp subscription client.
    case setapp
    /// Checked through an electron-builder update manifest (`Contents/Resources/app-update.yml`).
    case electron
    /// Not detected from a bundle: installed and updated together with another application from
    /// the same vendor (same installer package, or the same product folder).
    case bundled
    /// Not detected from a bundle: the app's own GitHub release-check URL was found in its executable.
    case githubReleases
    /// Not detected from a bundle: the version came from Homebrew's public cask catalog because the
    /// application's own updater can't be queried.
    case homebrewCatalog
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
    public let updateAuthority: NativeUpdateAuthority
    public let sparkleFeedURL: String?
    /// Real locations behind symlinks: the bundle itself, or its main executable. A link into a
    /// package manager's directory (Homebrew's Caskroom or Cellar) ties the app to that package.
    public let linkTargets: [String]

    /// The real bundle directory: the link's destination when `path` is a symlinked bundle.
    var bundlePath: String { linkTargets.first { $0.hasSuffix(".app") } ?? path }

    public init(path: String, bundleIdentifier: String?, displayName: String, shortVersion: String?, buildVersion: String?, classification: ApplicationClassification = .unknown, discoveryRoot: String = "", updateAuthority: NativeUpdateAuthority = .unknown, sparkleFeedURL: String? = nil, linkTargets: [String] = []) {
        self.linkTargets = linkTargets
        self.updateAuthority = updateAuthority
        self.sparkleFeedURL = sparkleFeedURL
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
        self.schemaVersion = 1
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
    /// Where updates come from: "homebrew", or a NativeUpdateAuthority raw value for native apps.
    public let updateSource: String?
    /// Why the latest update check gave no answer (no declared feed, not in the store), if it didn't.
    public let updateDetail: String?

    public init(selector: String, aliases: [String], kind: CatalogKind, name: String, fullName: String?, installedVersion: String?, availableVersion: String?, active: Bool, bundleIdentifier: String?, path: String?, prefix: String?, tap: String?, ownership: String?, autoUpdates: Bool, observedAt: Date, updateSource: String? = nil, updateDetail: String? = nil) {
        self.selector = selector
        self.aliases = aliases
        self.kind = kind
        self.name = name
        self.fullName = fullName
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.active = active
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.prefix = prefix
        self.tap = tap
        self.ownership = ownership
        self.autoUpdates = autoUpdates
        self.observedAt = observedAt
        self.updateSource = updateSource
        self.updateDetail = updateDetail
    }

    public var updateAvailable: Bool {
        availableVersion != nil && availableVersion != installedVersion
    }

    public func disambiguatingSelector(with suffix: String) -> CatalogItem {
        CatalogItem(selector: "\(selector)@\(suffix)", aliases: aliases, kind: kind, name: name, fullName: fullName, installedVersion: installedVersion, availableVersion: availableVersion, active: active, bundleIdentifier: bundleIdentifier, path: path, prefix: prefix, tap: tap, ownership: ownership, autoUpdates: autoUpdates, observedAt: observedAt, updateSource: updateSource, updateDetail: updateDetail)
    }
}

public enum CatalogResolution: Equatable, Sendable {
    case item(CatalogItem)
    case missing
    case ambiguous([CatalogItem])
}

public extension Array where Element == CatalogItem {
    /// Exact selector/alias matches win outright; otherwise falls back to a case-insensitive name/alias
    /// match. Shared by `Database.resolveCatalogItem` (Homebrew + native catalog) and callers resolving
    /// against a narrower, already-fetched item set (e.g. native apps only for `sift apps <name>`).
    func resolveCatalogItem(_ selector: String) -> CatalogResolution {
        let exact = filter { $0.selector == selector || $0.aliases.contains(selector) }
        if exact.count == 1 { return .item(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact) }
        let folded = filter { $0.name.caseInsensitiveCompare(selector) == .orderedSame || $0.aliases.contains { $0.caseInsensitiveCompare(selector) == .orderedSame } }
        if !folded.isEmpty { return folded.count == 1 ? .item(folded[0]) : .ambiguous(folded) }
        // Last, a name that starts with the selector as a whole word or ignoring spaces, so
        // "capture" finds "Capture Pro" and "bastion" finds "Bastion Siege 6".
        let key = Self.matchKey(selector)
        guard !key.isEmpty else { return .missing }
        let prefixed = filter { Self.matchKey($0.name).hasPrefix(key) }
        return prefixed.count == 1 ? .item(prefixed[0]) : prefixed.isEmpty ? .missing : .ambiguous(prefixed)
    }

    private static func matchKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }
    }
}

public struct NativeVersionTransition: Codable, Equatable, Sendable {
    public let selector: String
    public let name: String
    public let path: String
    public let fromVersion: String
    public let toVersion: String
    public let observedAt: Date

    public init(selector: String, name: String, path: String, fromVersion: String, toVersion: String, observedAt: Date) {
        self.selector = selector
        self.name = name
        self.path = path
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.observedAt = observedAt
    }
}
