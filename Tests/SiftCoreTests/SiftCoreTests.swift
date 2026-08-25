import Foundation
import XCTest
@testable import SiftCore

final class SiftCoreTests: XCTestCase {
    func testEmptyDatabaseHasUnknownFreshness() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)

        let dashboard = try database.dashboard(now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(dashboard.schemaVersion, 0)
        XCTAssertNil(dashboard.lastAttemptAt)
        XCTAssertNil(dashboard.dataAsOf)
        XCTAssertEqual(dashboard.freshness, .unknown)
        XCTAssertEqual(dashboard.latestRefreshStatus, .never)
    }

    func testWritableDatabaseRefreshLockRejectsSecondWriter() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let first = try Database(url: url)
        XCTAssertThrowsError(try Database(url: url)) { error in
            guard case .refreshInProgress = error as? DatabaseError else { return XCTFail("Expected refresh lock error, got \(error)") }
        }
        _ = first
    }

    func testFailedRefreshDoesNotAdvanceSuccessfulDataAge() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let successfulDate = Date(timeIntervalSince1970: 1_000)
        try database.recordRefresh(at: successfulDate, providerOutcomes: [NativeApplicationProvider.identifier: .success])
        try database.recordRefresh(at: Date(timeIntervalSince1970: 2_000), providerOutcomes: [NativeApplicationProvider.identifier: .failure(message: "offline")])

        let dashboard = try database.dashboard(now: Date(timeIntervalSince1970: 2_100), staleAfter: 1_500)
        XCTAssertEqual(dashboard.lastAttemptAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertNil(dashboard.dataAsOf)
        XCTAssertEqual(dashboard.latestRefreshStatus, .failure)
        XCTAssertEqual(dashboard.freshness, .unknown)
        XCTAssertEqual(dashboard.data.failedProviderCount, 1)
    }

    func testNativeInventoryIsIdempotentAndRecordsBuildTransitions() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let first = NativeApplication(path: "/Applications/Example.app", bundleIdentifier: "com.example.app", displayName: "Example", shortVersion: "1.0", buildVersion: "100", classification: .user, discoveryRoot: "/Applications")
        let firstSummary = try database.applyNativeInventory(NativeInventoryResult(applications: [first]), startedAt: Date(timeIntervalSince1970: 1_000), finishedAt: Date(timeIntervalSince1970: 1_001))
        XCTAssertEqual(firstSummary.addedCount, 1)
        XCTAssertEqual(firstSummary.changedCount, 0)

        let repeated = try database.applyNativeInventory(NativeInventoryResult(applications: [first]), startedAt: Date(timeIntervalSince1970: 2_000), finishedAt: Date(timeIntervalSince1970: 2_001))
        XCTAssertEqual(repeated.addedCount, 0)
        XCTAssertEqual(repeated.changedCount, 0)

        let updated = NativeApplication(path: first.path, bundleIdentifier: first.bundleIdentifier, displayName: first.displayName, shortVersion: "1.0", buildVersion: "101")
        let changed = try database.applyNativeInventory(NativeInventoryResult(applications: [updated]), startedAt: Date(timeIntervalSince1970: 3_000), finishedAt: Date(timeIntervalSince1970: 3_001))
        XCTAssertEqual(changed.changedCount, 1)
        XCTAssertEqual(try database.cachedApplications().first?.buildVersion, "101")
    }

    func testCompleteNativeInventoryMarksMissingApplicationInactive() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let application = NativeApplication(path: "/Applications/Example.app", bundleIdentifier: nil, displayName: "Example", shortVersion: nil, buildVersion: nil, classification: .user, discoveryRoot: "/Applications")
        _ = try database.applyNativeInventory(NativeInventoryResult(applications: [application], scannedRoots: ["/Applications"], candidatePaths: [application.path]), finishedAt: Date(timeIntervalSince1970: 1_000))
        let summary = try database.applyNativeInventory(NativeInventoryResult(applications: [], scannedRoots: ["/Applications"]), finishedAt: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(summary.inactiveCount, 1)
        XCTAssertFalse(try database.cachedApplications().first?.active ?? true)
    }

    func testStalenessBeginsAtConfiguredBoundary() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let refreshedAt = Date(timeIntervalSince1970: 1_000)
        try database.recordRefresh(at: refreshedAt, providerOutcomes: [NativeApplicationProvider.identifier: .success])

        XCTAssertEqual(try database.dashboard(now: refreshedAt.addingTimeInterval(120), staleAfter: 120).freshness, .unknown)
    }

    func testJSONIsDecodableAndContainsExplicitNulls() throws {
        let dashboard = Dashboard(generatedAt: Date(timeIntervalSince1970: 1_000), lastAttemptAt: nil, dataAsOf: nil, freshness: .unknown, latestRefreshStatus: .never, data: DashboardData(availableUpdateCount: 0, recentTransitionCount: 0, failedProviderCount: 0))
        let output = try DashboardRenderer.json(dashboard)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(Dashboard.self, from: Data(output.utf8)), dashboard)
        XCTAssertTrue(output.contains("\"lastAttemptAt\" : null"))
        XCTAssertTrue(output.contains("\"dataAsOf\" : null"))
    }

    func testNativeProviderUsesBoundedRootsAndDeduplicatesCandidates() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sift-bundles-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApplication(at: root.appending(path: "Example.app"), metadata: ["CFBundleIdentifier": "com.example.app", "CFBundleDisplayName": "Example", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "100", "CFBundlePackageType": "APPL"])
        try makeApplication(at: root.appending(path: "Nested/Second.app"), metadata: ["CFBundleIdentifier": "com.example.second", "CFBundleName": "Second", "CFBundlePackageType": "APPL"])
        try makeApplication(at: root.appending(path: "TooDeep/One/Two/Third.app"), metadata: ["CFBundleIdentifier": "com.example.third", "CFBundleName": "Third", "CFBundlePackageType": "APPL"])

        let searchRoot = NativeSearchRoot(url: root, classification: .user, required: true)
        let inventory = NativeApplicationProvider(roots: [searchRoot, searchRoot]).discover()
        XCTAssertTrue(inventory.complete)
        XCTAssertEqual(inventory.applications.map(\.displayName), ["Example", "Second"])
        XCTAssertEqual(inventory.applications.first?.classification, .user)
        XCTAssertEqual(inventory.candidatePaths.count, 2)
    }

    func testNativeProviderMarksMissingRequiredRootPartial() {
        let root = URL(fileURLWithPath: "/tmp/sift-missing-\(UUID().uuidString)")
        let inventory = NativeApplicationProvider(roots: [NativeSearchRoot(url: root, classification: .user, required: true)]).discover()
        XCTAssertFalse(inventory.complete)
        XCTAssertEqual(inventory.applications.count, 0)
        XCTAssertEqual(inventory.warnings.count, 1)
    }

    func testHomebrewReleaseNotesAreCachedByTargetVersion() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let notes = HomebrewReleaseNotes(name: "yazi", installedVersion: "25.5.31", availableVersion: "26.8.15", content: "## [v26.8.15]\n- Drag and drop", sourceURL: "https://example.test/changelog", coverage: "complete")
        try database.storeReleaseNotes(notes, prefix: "/opt/homebrew", kind: .formula)
        XCTAssertEqual(try database.homebrewReleaseNotes(named: "yazi"), notes)
    }

    func testCompleteHomebrewPrefixMarksMissingPackageAndArtifactInactive() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let cask = homebrewPackage(kind: .cask, name: "example", artifacts: ["/Applications/Example.app"])
        let first = HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: cask.prefix, packages: [cask], complete: true, warnings: [])])
        try database.applyHomebrewPackages(first, targets: [:], observedAt: Date(timeIntervalSince1970: 1_000))

        let empty = HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: cask.prefix, packages: [], complete: true, warnings: [])])
        try database.applyHomebrewPackages(empty, targets: [:], observedAt: Date(timeIntervalSince1970: 2_000))

        XCTAssertTrue(try database.catalogItems().isEmpty)
        XCTAssertEqual(try database.catalogItems(includeAll: true).first?.active, false)
    }

    func testPartialHomebrewPrefixRetainsPreviouslyObservedPackages() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let formula = homebrewPackage(kind: .formula, name: "example")
        try database.applyHomebrewPackages(HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: formula.prefix, packages: [formula], complete: true, warnings: [])]), targets: [:], observedAt: Date(timeIntervalSince1970: 1_000))

        try database.applyHomebrewPackages(HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: formula.prefix, packages: [], complete: false, warnings: ["offline"])]), targets: [:], observedAt: Date(timeIntervalSince1970: 2_000))

        XCTAssertEqual(try database.catalogItems().map(\.name), ["example"])
    }

    func testChangedCaskArtifactsStopSuppressingOldNativeApplication() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let native = NativeApplication(path: "/Applications/Example.app", bundleIdentifier: "com.example.app", displayName: "Example", shortVersion: "1.0", buildVersion: nil, classification: .user, discoveryRoot: "/Applications")
        _ = try database.applyNativeInventory(NativeInventoryResult(applications: [native], scannedRoots: ["/Applications"], candidatePaths: [native.path]), finishedAt: Date(timeIntervalSince1970: 1_000))

        let cask = homebrewPackage(kind: .cask, name: "example", artifacts: [native.path])
        try database.applyHomebrewPackages(HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: cask.prefix, packages: [cask], complete: true, warnings: [])]), targets: [:], observedAt: Date(timeIntervalSince1970: 2_000))
        XCTAssertFalse(try database.catalogItems().contains { $0.kind == .nativeApp })

        let movedCask = homebrewPackage(kind: .cask, name: "example", artifacts: ["/Applications/Renamed.app"])
        try database.applyHomebrewPackages(HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: movedCask.prefix, packages: [movedCask], complete: true, warnings: [])]), targets: [:], observedAt: Date(timeIntervalSince1970: 3_000))
        XCTAssertTrue(try database.catalogItems().contains { $0.kind == .nativeApp })
    }

    func testAutoUpdatingCaskIsPersistedWithUpdate() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let cask = homebrewPackage(kind: .cask, name: "example", autoUpdates: true)
        let key = "\(cask.prefix)|\(cask.kind.rawValue)|\(cask.fullName)"
        try database.applyHomebrewPackages(HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: cask.prefix, packages: [cask], complete: true, warnings: [])]), targets: [key: HomebrewTarget(version: "2.0", sourceURL: nil)])

        XCTAssertEqual(try database.homebrewUpdates().first?.autoUpdates, true)
        XCTAssertEqual(try database.catalogItems().first?.autoUpdates, true)
    }

    func testDashboardCountsActionableHomebrewUpdatesButNotAutoUpdatingCasks() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let formula = homebrewPackage(kind: .formula, name: "formula")
        let cask = homebrewPackage(kind: .cask, name: "cask", autoUpdates: true)
        let packages = [formula, cask]
        let targets = Dictionary(uniqueKeysWithValues: packages.map { package in
            ("\(package.prefix)|\(package.kind.rawValue)|\(package.fullName)", HomebrewTarget(version: "2.0", sourceURL: nil))
        })
        try database.applyHomebrewPackages(HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: formula.prefix, packages: packages, complete: true, warnings: [])]), targets: targets)

        let dashboard = try database.dashboard()
        XCTAssertEqual(dashboard.data.availableUpdateCount, 1)
        XCTAssertEqual(dashboard.data.informationalUpdateCount, 1)
    }

    func testUnifiedPartialRefreshKeepsMissingNativeApplicationsActive() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let application = NativeApplication(path: "/Applications/Example.app", bundleIdentifier: "com.example.app", displayName: "Example", shortVersion: "1.0", buildVersion: nil, classification: .user, discoveryRoot: "/Applications")
        _ = try database.applyNativeInventory(NativeInventoryResult(applications: [application], scannedRoots: ["/Applications"], candidatePaths: [application.path]), finishedAt: Date(timeIntervalSince1970: 1_000))

        let startedAt = Date(timeIntervalSince1970: 2_000)
        let finishedAt = Date(timeIntervalSince1970: 2_001)
        let results = [
            ProviderRefreshResult(provider: .nativeApplications, status: .partial, message: "root unavailable", warningCount: 1, startedAt: startedAt, finishedAt: finishedAt),
            ProviderRefreshResult(provider: .homebrewInventory, status: .success, startedAt: startedAt, finishedAt: finishedAt, dataAsOf: finishedAt),
            ProviderRefreshResult(provider: .homebrewTargets, status: .success, startedAt: startedAt, finishedAt: finishedAt, dataAsOf: finishedAt),
            ProviderRefreshResult(provider: .homebrewReleaseNotes, status: .success, startedAt: startedAt, finishedAt: finishedAt, dataAsOf: finishedAt),
        ]
        let summary = try database.applyRefresh(RefreshPersistenceInput(startedAt: startedAt, finishedAt: finishedAt, nativeInventory: NativeInventoryResult(applications: [], warnings: ["root unavailable"], complete: false, scannedRoots: ["/Applications"]), homebrewInventory: HomebrewInventory(prefixes: []), targetResults: [:], releaseNoteResults: [:], providerResults: results))

        XCTAssertEqual(summary.status, .partial)
        XCTAssertEqual(summary.providerResults.count, 4)
        XCTAssertTrue(try database.cachedApplications().first?.active ?? false)
        XCTAssertEqual(try database.dashboard(now: finishedAt).data.partialProviderCount, 1)
    }

    func testFreshMetadataCacheAvoidsNetworkAndPreservesPayload() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let requestURL = "https://formulae.brew.sh/api/formula/example.json"
        try database.storeMetadataResponse(url: requestURL, resourceKind: "homebrew-target-v2", statusCode: 200, body: Data("cached".utf8), etag: "etag", lastModified: nil, validatedAt: timestamp)
        let client = MetadataHTTPClient(database: database, now: { timestamp.addingTimeInterval(60) })

        XCTAssertEqual(try String(decoding: client.fetch(URL(string: requestURL)!, resource: .homebrewTarget).body, as: UTF8.self), "cached")
    }

    func testCachedMetadataNotFoundRemainsExplicitAbsence() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let requestURL = "https://formulae.brew.sh/api/formula/missing.json"
        try database.storeMetadataResponse(url: requestURL, resourceKind: "homebrew-target-v2", statusCode: 404, body: nil, etag: nil, lastModified: nil, validatedAt: timestamp)
        let client = MetadataHTTPClient(database: database, now: { timestamp.addingTimeInterval(60) })

        XCTAssertThrowsError(try client.fetch(URL(string: requestURL)!, resource: .homebrewTarget)) { error in
            XCTAssertEqual((error as? MetadataHTTPError)?.errorDescription, MetadataHTTPError.notFound.errorDescription)
        }
    }

    func testNotFoundCacheRevalidatesWith304() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let validatedAt = Date(timeIntervalSince1970: 1_000)
        let revalidatedAt = validatedAt.addingTimeInterval(7 * 60 * 60)
        let requestURL = "https://formulae.brew.sh/api/formula/missing.json"
        try database.storeMetadataResponse(url: requestURL, resourceKind: "homebrew-target-v2", statusCode: 404, body: nil, etag: "missing-etag", lastModified: nil, validatedAt: validatedAt)

        MetadataURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "missing-etag")
            return (304, nil, [:])
        }
        defer { MetadataURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataURLProtocol.self]
        let client = MetadataHTTPClient(database: database, configuration: configuration, now: { revalidatedAt })

        XCTAssertThrowsError(try client.fetch(URL(string: requestURL)!, resource: .homebrewTarget)) { error in
            XCTAssertEqual((error as? MetadataHTTPError)?.errorDescription, MetadataHTTPError.notFound.errorDescription)
        }
        XCTAssertEqual(try database.cachedMetadataResponse(url: requestURL, resourceKind: "homebrew-target-v2")?.validatedAt, revalidatedAt)
    }

    func testMetadataClientStopsOversizedResponseWhileStreaming() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let requestURL = "https://formulae.brew.sh/api/formula/large.json"
        MetadataURLProtocol.handler = { _ in (200, Data(repeating: 0, count: 1_048_577), [:]) }
        defer { MetadataURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataURLProtocol.self]
        let client = MetadataHTTPClient(database: database, configuration: configuration)

        XCTAssertThrowsError(try client.fetch(URL(string: requestURL)!, resource: .homebrewTarget)) { error in
            XCTAssertEqual((error as? MetadataHTTPError)?.errorDescription, MetadataHTTPError.responseTooLarge.errorDescription)
        }
        XCTAssertNil(try database.cachedMetadataResponse(url: requestURL, resourceKind: "homebrew-target-v2"))
    }

    func testGitHubMetadataPolicyUsesPreferredTokenAndRequiredHeaders() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        MetadataURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer preferred-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "sift-pre-v1")
            return (200, Data("{}".utf8), [:])
        }
        defer { MetadataURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataURLProtocol.self]
        let client = MetadataHTTPClient(database: database, configuration: configuration, environment: ["GITHUB_TOKEN": " preferred-token ", "GH_TOKEN": "fallback-token"])

        let response = try client.fetch(URL(string: "https://api.github.com/repos/owner/repository/git/ref/tags/v1")!, resource: .githubReference)
        XCTAssertEqual(response.body, Data("{}".utf8))
    }

    func testGitHubRateLimitIsTypedAndNotCached() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let requestURL = "https://api.github.com/repos/owner/repository/releases"
        MetadataURLProtocol.handler = { _ in (429, nil, ["Retry-After": "60"]) }
        defer { MetadataURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataURLProtocol.self]
        let now = Date(timeIntervalSince1970: 1_000)
        let client = MetadataHTTPClient(database: database, configuration: configuration, now: { now })

        XCTAssertThrowsError(try client.fetch(URL(string: requestURL)!, resource: .githubReleaseList)) { error in
            guard case let .rateLimited(retryAt) = error as? MetadataHTTPError else { return XCTFail("Expected rate-limit error, got \(error)") }
            XCTAssertEqual(retryAt, now.addingTimeInterval(60))
        }
        XCTAssertNil(try database.cachedMetadataResponse(url: requestURL, resourceKind: "github-release-list-v2-anonymous"))
    }

    func testGitHubSourceParsesExactArchiveAndReleaseTags() {
        XCTAssertEqual(
            GitHubSource.parse(URL(string: "https://github.com/owner/repository/archive/refs/tags/v1.2.3.tar.gz")!),
            GitHubSource(repository: GitHubRepository(owner: "owner", name: "repository"), tag: "v1.2.3")
        )
        XCTAssertEqual(
            GitHubSource.parse(URL(string: "https://github.com/owner/repository/releases/download/release%2F1.2.3/app.zip")!),
            GitHubSource(repository: GitHubRepository(owner: "owner", name: "repository"), tag: "release/1.2.3")
        )
        XCTAssertEqual(
            GitHubSource.parse(URL(string: "https://codeload.github.com/owner/repository/tar.gz/refs/tags/v1.2.3")!),
            GitHubSource(repository: GitHubRepository(owner: "owner", name: "repository"), tag: "v1.2.3")
        )
    }

    func testGitHubSourceRejectsLookalikesAndUnsafePaths() {
        XCTAssertNil(GitHubSource.parse(URL(string: "https://github.com.example/owner/repository/archive/v1.2.3.tar.gz")!))
        XCTAssertNil(GitHubSource.parse(URL(string: "https://github.com/owner/../archive/v1.2.3.tar.gz")!))
        XCTAssertNil(GitHubSource.parse(URL(string: "http://github.com/owner/repository/archive/v1.2.3.tar.gz")!))
        XCTAssertNil(GitHubSource.parse(URL(string: "https://github.com/owner/.git/archive/v1.2.3.tar.gz")!))
    }

    func testGitHubTagResolverUsesOneExactVersionCandidate() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let commit = String(repeating: "a", count: 40)
        MetadataURLProtocol.handler = { request in
            request.url?.path.hasSuffix("/tags/v1.2.3") == true
                ? (200, Data("{\"object\":{\"type\":\"commit\",\"sha\":\"\(commit)\"}}".utf8), [:])
                : (404, nil, [:])
        }
        defer { MetadataURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataURLProtocol.self]
        let resolver = GitHubTagResolver(metadataClient: MetadataHTTPClient(database: database, configuration: configuration))

        XCTAssertEqual(
            try resolver.resolve(repository: GitHubRepository(owner: "owner", name: "repository"), sourceTag: nil, upstreamVersion: "1.2.3"),
            GitHubTagIdentity(tag: "v1.2.3", commitSHA: commit)
        )
    }

    func testGitHubTagResolverPeelsAnnotatedTags() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let tagObject = String(repeating: "b", count: 40)
        let commit = String(repeating: "c", count: 40)
        MetadataURLProtocol.handler = { request in
            switch request.url?.path {
            case "/repos/owner/repository/git/ref/tags/v1.2.3":
                return (200, Data("{\"object\":{\"type\":\"tag\",\"sha\":\"\(tagObject)\"}}".utf8), [:])
            case "/repos/owner/repository/git/tags/\(tagObject)":
                return (200, Data("{\"object\":{\"type\":\"commit\",\"sha\":\"\(commit)\"}}".utf8), [:])
            default:
                return (404, nil, [:])
            }
        }
        defer { MetadataURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataURLProtocol.self]
        let resolver = GitHubTagResolver(metadataClient: MetadataHTTPClient(database: database, configuration: configuration))

        XCTAssertEqual(
            try resolver.resolve(repository: GitHubRepository(owner: "owner", name: "repository"), sourceTag: "v1.2.3", upstreamVersion: "ignored"),
            GitHubTagIdentity(tag: "v1.2.3", commitSHA: commit)
        )
    }

    func testReleaseNotesPreferExactGitHubReleaseBody() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let commit = String(repeating: "a", count: 40)
        MetadataURLProtocol.handler = { request in
            switch request.url?.path {
            case "/repos/owner/repository/git/ref/tags/1.2.3":
                return (404, nil, [:])
            case "/repos/owner/repository/git/ref/tags/v1.2.3":
                return (200, Data("{\"object\":{\"type\":\"commit\",\"sha\":\"\(commit)\"}}".utf8), [:])
            case "/repos/owner/repository/releases/tags/v1.2.3":
                return (200, Data("{\"id\":12,\"body\":\"Fixed a critical issue.\",\"draft\":false}".utf8), [:])
            default:
                return (404, nil, [:])
            }
        }
        defer { MetadataURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataURLProtocol.self]
        let resolver = ReleaseNotesResolver(metadataClient: MetadataHTTPClient(database: database, configuration: configuration))
        let package = homebrewPackage(kind: .formula, name: "example")
        let target = HomebrewTarget(version: "1.2.3", sourceURL: "https://github.com/owner/repository", upstreamVersion: "1.2.3")

        guard case let .resolved(notes) = resolver.resolveReleaseNotes(for: package, target: target) else {
            return XCTFail("Expected the exact GitHub Release body.")
        }
        XCTAssertEqual(notes.content, "Fixed a critical issue.")
        XCTAssertEqual(notes.coverage, "targetOnly")
        XCTAssertEqual(notes.sourceURL, "https://github.com/owner/repository/releases/tag/v1.2.3")
    }

    func testReleaseNotesUseCommitPinnedExactChangelogRange() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let commit = String(repeating: "d", count: 40)
        MetadataURLProtocol.handler = { request in
            switch request.url?.path {
            case "/repos/owner/repository/git/ref/tags/1.2.3":
                return (404, nil, [:])
            case "/repos/owner/repository/git/ref/tags/v1.2.3":
                return (200, Data("{\"object\":{\"type\":\"commit\",\"sha\":\"\(commit)\"}}".utf8), [:])
            case "/repos/owner/repository/releases/tags/v1.2.3":
                return (404, nil, [:])
            case "/owner/repository/\(commit)/CHANGELOG.md":
                return (200, Data("## [v1.2.3]\n- Current change\n\n## [1.2.2] - 2026-01-01\n- Previous change\n".utf8), [:])
            default:
                return (404, nil, [:])
            }
        }
        defer { MetadataURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataURLProtocol.self]
        let resolver = ReleaseNotesResolver(metadataClient: MetadataHTTPClient(database: database, configuration: configuration))
        let package = HomebrewPackage(prefix: "/opt/homebrew", kind: .formula, name: "example", fullName: "example", tap: "homebrew/core", ownership: .explicitlyRequested, installedVersion: "1.2.2", sourceURL: nil, homepage: nil, artifactPaths: [], autoUpdates: false)
        let target = HomebrewTarget(version: "1.2.3", sourceURL: "https://github.com/owner/repository", upstreamVersion: "1.2.3")

        guard case let .resolved(notes) = resolver.resolveReleaseNotes(for: package, target: target) else {
            return XCTFail("Expected an exact changelog range.")
        }
        XCTAssertEqual(notes.content, "## [v1.2.3]\n- Current change")
        XCTAssertEqual(notes.coverage, "complete")
        XCTAssertEqual(notes.sourceURL, "https://raw.githubusercontent.com/owner/repository/\(commit)/CHANGELOG.md")
    }

    func testReleaseNotesRejectSimilarChangelogHeading() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let commit = String(repeating: "e", count: 40)
        MetadataURLProtocol.handler = { request in
            switch request.url?.path {
            case "/repos/owner/repository/git/ref/tags/1.2.3":
                return (404, nil, [:])
            case "/repos/owner/repository/git/ref/tags/v1.2.3":
                return (200, Data("{\"object\":{\"type\":\"commit\",\"sha\":\"\(commit)\"}}".utf8), [:])
            case "/repos/owner/repository/releases/tags/v1.2.3":
                return (404, nil, [:])
            case "/owner/repository/\(commit)/CHANGELOG.md":
                return (200, Data("## [v1.2.3-beta]\n- Not the requested release\n".utf8), [:])
            default:
                return (404, nil, [:])
            }
        }
        defer { MetadataURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataURLProtocol.self]
        let resolver = ReleaseNotesResolver(metadataClient: MetadataHTTPClient(database: database, configuration: configuration))
        let package = homebrewPackage(kind: .formula, name: "example")
        let target = HomebrewTarget(version: "1.2.3", sourceURL: "https://github.com/owner/repository", upstreamVersion: "1.2.3")

        guard case .unavailable = resolver.resolveReleaseNotes(for: package, target: target) else {
            return XCTFail("A similarly named changelog heading must not be accepted.")
        }
    }

    func testHumanReadableOutputStripsTerminalControlSequences() {
        let notes = HomebrewReleaseNotes(name: "Example\u{1B}[2J", installedVersion: "1.0\r", availableVersion: "2.0", content: "- Safe\n\u{1B}[31mnot terminal formatting", sourceURL: "https://example.test/\u{1B}[8m", coverage: "targetOnly")
        let output = HomebrewRenderer.show(notes)

        XCTAssertFalse(output.unicodeScalars.contains { $0 == "\u{1B}" || $0 == "\r" })
        XCTAssertTrue(output.contains("- Safe\n[31mnot terminal formatting"))
    }

    func testCommandRunnerStopsOversizedStreamingOutput() throws {
        let runner = CommandRunner()
        XCTAssertThrowsError(try runner.run(executable: URL(filePath: "/usr/bin/yes"), arguments: [], environment: ProcessInfo.processInfo.environment, timeout: 5, outputLimit: 1_024)) { error in
            XCTAssertEqual((error as? CommandRunnerError)?.errorDescription, CommandRunnerError.outputTooLarge(URL(filePath: "/usr/bin/yes")).errorDescription)
        }
    }

    func testCommandRunnerReturnsNonzeroStatus() throws {
        let runner = CommandRunner()
        let result = try runner.run(executable: URL(filePath: "/bin/sh"), arguments: ["-c", "printf failure >&2; exit 7"], environment: ProcessInfo.processInfo.environment)
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "failure")
    }

    private func homebrewPackage(kind: HomebrewPackageKind, name: String, artifacts: [String] = [], autoUpdates: Bool = false) -> HomebrewPackage {
        HomebrewPackage(prefix: "/opt/homebrew", kind: kind, name: name, fullName: name, tap: kind == .formula ? "homebrew/core" : "homebrew/cask", ownership: kind == .formula ? .explicitlyRequested : .installedCask, installedVersion: "1.0", sourceURL: nil, homepage: nil, artifactPaths: artifacts, autoUpdates: autoUpdates)
    }

    private func makeApplication(at url: URL, metadata: [String: String]) throws {
        let plistURL = url.appending(path: "Contents/Info.plist")
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try data.write(to: plistURL)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "sift-test-\(UUID().uuidString).sqlite3")
    }

    private func removeDatabase(at url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }
}

private final class MetadataURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data?, [String: String]))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: MetadataHTTPError.invalidResponse)
            return
        }
        let result = handler(request)
        guard let response = HTTPURLResponse(url: url, statusCode: result.0, httpVersion: "HTTP/1.1", headerFields: result.2) else {
            client?.urlProtocol(self, didFailWithError: MetadataHTTPError.invalidResponse)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = result.1 { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
