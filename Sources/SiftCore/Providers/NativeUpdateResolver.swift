import Foundation

public protocol NativeUpdateResolving: Sendable {
    func resolve(_ application: NativeApplication) -> NativeUpdateCheck
    /// Loads shared lookups ahead of time so `resolve` doesn't wait on them.
    func prepare()
}

public extension NativeUpdateResolving {
    func prepare() {}
}

/// Asks a native application's own update authority for its latest version: the Sparkle feed the
/// bundle declares, or the App Store's catalog entry for its exact bundle identifier.
public struct NativeUpdateResolver: NativeUpdateResolving {
    private let metadataClient: MetadataHTTPClient
    private let storefront: String
    private let systemVersion: String
    private let catalog: OnceLoader<HomebrewCaskCatalog>
    private let blackmagic: OnceLoader<BlackmagicDownloads>

    public init(
        metadataClient: MetadataHTTPClient, storefront: String = Locale.current.region?.identifier.lowercased() ?? "us",
        systemVersion: String = NativeUpdateResolver.currentSystemVersion
    ) {
        self.metadataClient = metadataClient
        catalog = OnceLoader {
            try metadataClient.fetch(HomebrewCaskCatalog.url, resource: .homebrewCaskCatalog, derivedAs: "index-v2", HomebrewCaskCatalog.init(data:))
        }
        blackmagic = OnceLoader { try BlackmagicDownloads(data: metadataClient.fetch(BlackmagicDownloads.url, resource: .blackmagicDownloads).body) }
        self.storefront = storefront.allSatisfy(\.isLetter) && storefront.count == 2 ? storefront : "us"
        self.systemVersion = systemVersion
    }

    public static var currentSystemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// Asks the application's own updater, falling back to Homebrew's cask catalog when that
    /// updater can't be queried. Steam games and Apple applications have their own delivery.
    public func resolve(_ application: NativeApplication) -> NativeUpdateCheck {
        let key = Database.versionKey(short: application.shortVersion, build: application.buildVersion)
        func result(_ authority: NativeUpdateAuthority, _ outcome: NativeUpdateOutcome, note: String? = nil) -> NativeUpdateCheck {
            NativeUpdateCheck(path: application.path, authority: authority, installedVersionKey: key, outcome: outcome, note: note)
        }
        let direct = check(application)
        guard case .unchecked = direct, ![.steam, .apple, .setapp].contains(application.updateAuthority) else {
            return result(application.updateAuthority, direct)
        }

        // 1. Homebrew's cask catalog, tied by the exact bundle identifier.
        let catalog: HomebrewCaskCatalog
        switch self.catalog.load() {
        case let .success(loaded): catalog = loaded
        case let .failure(error): return result(.homebrewCatalog, .failed("Homebrew cask catalog: \(error.localizedDescription)"))
        }
        let fileName = (application.path as NSString).lastPathComponent
        if let entry = catalog.entry(bundleIdentifier: application.bundleIdentifier, bundleFileName: fileName) {
            return result(
                .homebrewCatalog, compare(entry.upstreamVersion, with: application),
                note: "Latest version from the Homebrew cask \u{201C}\(entry.token)\u{201D}.")
        }

        // 2. The app's own GitHub release check, found in its executable.
        let urls = BundleURLScanner.urls(in: application)
        if let repository = BundleURLScanner.releaseRepository(in: urls, for: application) {
            switch latestGitHubRelease(repository) {
            case let .success(release?):
                return result(
                    .githubReleases, compare(release.version, with: application, notes: release.notes),
                    note: "Latest release of github.com/\(repository.path), which the app checks for updates.")
            case .success(nil): break
            case let .failure(error): return result(.githubReleases, .failed("GitHub releases for \(application.displayName): \(error.localizedDescription)"))
            }
        }

        // 3. A cask with the same app name whose vendor domain the app itself references.
        if let (entry, domain) = catalog.entry(bundleFileName: fileName, referencedHosts: Set(urls.compactMap { $0.host?.lowercased() })) {
            return result(
                .homebrewCatalog, compare(entry.upstreamVersion, with: application),
                note: "Latest version from the Homebrew cask \u{201C}\(entry.token)\u{201D}, matched by app name and the vendor domain \(domain).")
        }
        if application.shortVersion == nil, application.buildVersion == nil {
            return result(application.updateAuthority, .unchecked("The bundle declares no version, so there is nothing to compare an update with."))
        }
        return result(application.updateAuthority, direct)
    }

    /// Available when `latest` orders after the installed short version (and isn't the build).
    private func compare(_ latest: String, with application: NativeApplication, notes: NativeReleaseNotes? = nil) -> NativeUpdateOutcome {
        guard let installed = application.shortVersion ?? application.buildVersion else { return .unchecked("The bundle declares no version to compare.") }
        let isNewer = SparkleVersion.compare(latest, installed) == .orderedDescending && latest != application.buildVersion
        return isNewer ? .available(version: latest, notes: notes) : .upToDate
    }

    private func latestGitHubRelease(_ repository: GitHubRepository) -> Result<(version: String, notes: NativeReleaseNotes?)?, Error> {
        guard let url = URL(string: "https://api.github.com/repos/\(repository.path)/releases/latest") else { return .success(nil) }
        do {
            let body = try metadataClient.fetch(url, resource: .githubLatestRelease).body
            guard let release = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                release["draft"] as? Bool != true, release["prerelease"] as? Bool != true,
                let tag = (release["tag_name"] as? String)?.nonEmpty
            else { return .success(nil) }
            let version = tag.drop { !$0.isNumber }
            guard !version.isEmpty else { return .success(nil) }
            let page = (release["html_url"] as? String).flatMap(URL.init(string:)).flatMap { isPublicHTTPSURL($0) ? $0.absoluteString : nil }
            let text = (release["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty.map { String($0.prefix(65_536)) }
            return .success((String(version), text == nil && page == nil ? nil : NativeReleaseNotes(content: text, sourceURL: page)))
        } catch MetadataHTTPError.notFound {
            return .success(nil)
        } catch {
            return .failure(error)
        }
    }

    /// Downloads (or reads from cache) and indexes the cask catalog, which nearly every refresh
    /// needs for at least one application.
    public func prepare() {
        _ = catalog.load()
    }

    public func check(_ application: NativeApplication) -> NativeUpdateOutcome {
        switch application.updateAuthority {
        case .sparkle: checkSparkle(application)
        case .appStore: checkAppStore(application)
        case .electron: checkElectron(application)
        case .steam: .unchecked("Steam installs updates for its games.")
        case .blackmagic: checkBlackmagic(application)
        case .setapp: .unchecked("Setapp installs updates for its apps.")
        case .apple: .unchecked("Delivered with macOS software updates.")
        case .homebrewCatalog, .bundled, .githubReleases, .unknown: .unchecked("No update source was detected for this application.")
        }
    }

    // MARK: Electron

    /// electron-builder's manifest names either a GitHub repository or a server publishing
    /// `latest-mac.yml`, exactly as the app's own updater reads it.
    private func checkElectron(_ application: NativeApplication) -> NativeUpdateOutcome {
        guard let manifest = ElectronUpdateManifest(bundlePath: application.bundlePath) else {
            return .unchecked("The Electron update manifest could not be read.")
        }
        switch manifest.source {
        case let .github(repository):
            switch latestGitHubRelease(repository) {
            case let .success(release?): return compare(release.version, with: application, notes: release.notes)
            case .success(nil): return .unchecked("github.com/\(repository.path) has no published release.")
            case let .failure(error): return .failed("GitHub releases for \(application.displayName): \(error.localizedDescription)")
            }
        case let .generic(base):
            let url = base.appending(path: "latest-mac.yml")
            guard isPublicHTTPSURL(url), let host = url.host?.lowercased() else { return .unchecked("The Electron update server is not a public HTTPS URL.") }
            do {
                guard let version = ElectronUpdateManifest.version(inLatestYAML: try metadataClient.fetch(url, resource: .electronUpdateFeed(host: host)).body)
                else { return .unchecked("The Electron update feed lists no version.") }
                return compare(version, with: application)
            } catch {
                return .failed("Electron update feed for \(application.displayName): \(error.localizedDescription)")
            }
        case .unsupported(let provider):
            return .unchecked("The app updates through \(provider), which Sift can't query.")
        }
    }

    // MARK: Sparkle

    private func checkSparkle(_ application: NativeApplication) -> NativeUpdateOutcome {
        guard let feed = application.sparkleFeedURL else {
            return .unchecked("The application configures its Sparkle feed at run time, so it can't be read from the bundle.")
        }
        guard let url = URL(string: feed), isPublicHTTPSURL(url), let host = url.host?.lowercased() else {
            return .unchecked("The application's Sparkle feed is not a public HTTPS URL.")
        }
        let items: [SparkleAppcastItem]
        do {
            items = try SparkleAppcastParser.parse(metadataClient.fetch(url, resource: .sparkleAppcast(host: host)).body)
        } catch {
            return .failed("Sparkle feed for \(application.displayName): \(error.localizedDescription)")
        }
        // Compared the way the app's own copy of Sparkle compares.
        let padding = !SparkleAppcastParser.bundlesSparkle1(application.bundlePath)
        guard let best = SparkleAppcastParser.bestItem(items, systemVersion: systemVersion, padding: padding) else {
            return .unchecked("The Sparkle feed lists no release for this version of macOS.")
        }
        // Sparkle compares the feed's build version with CFBundleVersion.
        guard let installed = application.buildVersion ?? application.shortVersion else { return .unchecked("The bundle declares no version to compare.") }
        switch SparkleVersion.compare(best.version, installed, padding: padding) {
        case .orderedSame: return .upToDate
        // An app can replace its declared feed at run time (some declare one they stopped
        // updating); a feed with nothing as new as the installed version isn't the one it uses.
        case .orderedAscending:
            return .unchecked("The Sparkle feed in the bundle lists nothing newer than \(best.displayVersion), so the app uses another feed.")
        case .orderedDescending: break
        }
        let content = best.releaseNotesHTML.map(HTMLText.plainText(from:)).flatMap { $0.isEmpty ? nil : String($0.prefix(65_536)) }
        let notesURL = best.releaseNotesURL.flatMap(URL.init(string:)).flatMap { isPublicHTTPSURL($0) ? $0.absoluteString : nil }
        let notes = content == nil && notesURL == nil ? nil : NativeReleaseNotes(content: content, sourceURL: notesURL)
        return .available(version: best.displayVersion, notes: notes)
    }

    // MARK: Blackmagic

    private func checkBlackmagic(_ application: NativeApplication) -> NativeUpdateOutcome {
        guard let identifier = application.bundleIdentifier, let product = BlackmagicDownloads.product(forBundleIdentifier: identifier) else {
            return .unchecked("No Blackmagic product matches this application.")
        }
        let downloads: BlackmagicDownloads
        switch blackmagic.load() {
        case let .success(loaded): downloads = loaded
        case let .failure(error): return .failed("Blackmagic downloads for \(application.displayName): \(error.localizedDescription)")
        }
        guard let latest = downloads.latestVersion(product: product) else { return .unchecked("Blackmagic lists no macOS release for this product.") }
        return compare(latest, with: application)
    }

    // MARK: App Store

    private func checkAppStore(_ application: NativeApplication) -> NativeUpdateOutcome {
        guard let bundleIdentifier = application.bundleIdentifier else { return .unchecked("The bundle has no identifier to look up.") }
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleIdentifier), URLQueryItem(name: "country", value: storefront),
            URLQueryItem(name: "entity", value: "macSoftware")
        ]
        let listing: AppStoreListing?
        do {
            listing = try AppStoreListing.parse(metadataClient.fetch(components.url!, resource: .appStoreLookup).body, bundleIdentifier: bundleIdentifier)
        } catch {
            return .failed("App Store lookup for \(application.displayName): \(error.localizedDescription)")
        }
        guard let listing else { return .unchecked("Not listed in the \(storefront.uppercased()) App Store.") }
        let notes =
            listing.releaseNotes == nil && listing.storeURL == nil
            ? nil : NativeReleaseNotes(content: listing.releaseNotes.map { String($0.prefix(65_536)) }, sourceURL: listing.storeURL)
        let outcome = compare(listing.version, with: application, notes: notes)
        if case .available = outcome, let minimum = listing.minimumSystemVersion, SparkleVersion.compare(systemVersion, minimum) == .orderedAscending {
            return .unchecked("Version \(listing.version) requires macOS \(minimum).")
        }
        return outcome
    }
}

/// Runs `work` at most once, on first use (the cask catalog and Blackmagic feed are downloaded
/// only when an application needs them), and remembers its result.
private final class OnceLoader<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let work: @Sendable () throws -> Value
    private var result: Result<Value, Error>?

    init(_ work: @escaping @Sendable () throws -> Value) { self.work = work }

    func load() -> Result<Value, Error> {
        lock.withLock {
            if let result { return result }
            let loaded = Result { try work() }
            result = loaded
            return loaded
        }
    }
}

struct AppStoreListing: Equatable {
    let version: String
    let releaseNotes: String?
    let storeURL: String?
    let minimumSystemVersion: String?

    /// The listing for exactly this bundle identifier, preferring the Mac build when a universal
    /// purchase also returns its iOS counterpart.
    static func parse(_ data: Data, bundleIdentifier: String) throws -> AppStoreListing? {
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any], let results = document["results"] as? [[String: Any]] else {
            throw MetadataHTTPError.invalidResponse
        }
        let matches = results.filter { $0["bundleId"] as? String == bundleIdentifier }
        guard let result = matches.first(where: { $0["kind"] as? String == "mac-software" }) ?? (matches.count == 1 ? matches.first : nil),
            let version = (result["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty
        else { return nil }
        let storeURL = (result["trackViewUrl"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0.absoluteString : nil }
        return AppStoreListing(
            version: version, releaseNotes: (result["releaseNotes"] as? String)?.nonEmpty, storeURL: storeURL,
            minimumSystemVersion: (result["minimumOsVersion"] as? String)?.nonEmpty)
    }
}
