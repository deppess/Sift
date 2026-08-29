import Darwin
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

    func testWritableDatabaseRejectsNonStickyWritableParent() throws {
        let directory = try temporaryDatabaseDirectory(mode: 0o777)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try Database(url: directory.appending(path: "sift.sqlite3"))) { error in
            guard case .unsafeFilesystemPath = error as? DatabaseError else { return XCTFail("Expected unsafe parent error, got \(error)") }
        }
    }

    func testWritableDatabaseAcceptsStickyParent() throws {
        let directory = try temporaryDatabaseDirectory(mode: 0o1777)
        let url = directory.appending(path: "sift.sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try Database(url: url)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    }

    func testDatabaseRejectsSymlinkAndHardlink() throws {
        let directory = try temporaryDatabaseDirectory(mode: 0o700)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "target.sqlite3")
        try Data().write(to: target)
        let symlink = directory.appending(path: "symlink.sqlite3")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        XCTAssertThrowsError(try Database(url: symlink))

        let hardlink = directory.appending(path: "hardlink.sqlite3")
        XCTAssertEqual(link(target.path, hardlink.path), 0)
        XCTAssertThrowsError(try Database(url: hardlink)) { error in
            guard case .invalidDatabasePath = error as? DatabaseError else { return XCTFail("Expected invalid database path, got \(error)") }
        }
    }

    func testRefreshLockRejectsHardlinkedFile() throws {
        let directory = try temporaryDatabaseDirectory(mode: 0o700)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "sift.sqlite3")
        let lock = url.appendingPathExtension("refresh.lock")
        try Data().write(to: lock)
        XCTAssertEqual(link(lock.path, directory.appending(path: "other.lock").path), 0)

        XCTAssertThrowsError(try Database(url: url)) { error in
            guard case .refreshLockUnavailable = error as? DatabaseError else { return XCTFail("Expected unsafe lock error, got \(error)") }
        }
    }

    func testFailedRefreshDoesNotAdvanceSuccessfulDataAge() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let successfulDate = Date(timeIntervalSince1970: 1_000)
        _ = try database.applyRefresh(refreshInput(at: successfulDate))
        _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 2_000), providerStatuses: Dictionary(uniqueKeysWithValues: RefreshProvider.allCases.map { ($0, .failure) })))

        let dashboard = try database.dashboard(now: Date(timeIntervalSince1970: 2_100), staleAfter: 1_500)
        XCTAssertEqual(dashboard.lastAttemptAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(dashboard.dataAsOf, successfulDate)
        XCTAssertEqual(dashboard.latestRefreshStatus, .failure)
        XCTAssertEqual(dashboard.freshness, .current)
        XCTAssertEqual(dashboard.data.failedProviderCount, RefreshProvider.allCases.count)
    }

    func testNativeInventoryIsIdempotentAndRecordsBuildTransitions() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let first = NativeApplication(path: "/Applications/Example.app", bundleIdentifier: "com.example.app", displayName: "Example", shortVersion: "1.0", buildVersion: "100", classification: .user, discoveryRoot: "/Applications")
        let firstSummary = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 1_001), nativeInventory: NativeInventoryResult(applications: [first])))
        XCTAssertEqual(firstSummary.addedCount, 1)
        XCTAssertEqual(firstSummary.changedCount, 0)

        let repeated = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 2_001), nativeInventory: NativeInventoryResult(applications: [first])))
        XCTAssertEqual(repeated.addedCount, 0)
        XCTAssertEqual(repeated.changedCount, 0)

        let updated = NativeApplication(path: first.path, bundleIdentifier: first.bundleIdentifier, displayName: first.displayName, shortVersion: "1.0", buildVersion: "101")
        let changed = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 3_001), nativeInventory: NativeInventoryResult(applications: [updated])))
        XCTAssertEqual(changed.changedCount, 1)
    }

    func testCompleteNativeInventoryMarksMissingApplicationInactive() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let application = NativeApplication(path: "/Applications/Example.app", bundleIdentifier: nil, displayName: "Example", shortVersion: nil, buildVersion: nil, classification: .user, discoveryRoot: "/Applications")
        _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 1_000), nativeInventory: NativeInventoryResult(applications: [application], scannedRoots: ["/Applications"], candidatePaths: [application.path])))
        let summary = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 2_000), nativeInventory: NativeInventoryResult(applications: [], scannedRoots: ["/Applications"])))
        XCTAssertEqual(summary.inactiveCount, 1)
        XCTAssertEqual(try database.catalogItems(includeAll: true).first?.active, false)
    }

    func testStalenessBeginsAtConfiguredBoundary() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let refreshedAt = Date(timeIntervalSince1970: 1_000)
        _ = try database.applyRefresh(refreshInput(at: refreshedAt))

        XCTAssertEqual(try database.dashboard(now: refreshedAt.addingTimeInterval(120), staleAfter: 120).freshness, .stale)
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
        let package = homebrewPackage(kind: .formula, name: "yazi")
        let key = HomebrewPackageKey(package)
        _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 1_000), homebrewInventory: HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: package.prefix, packages: [package], complete: true, warnings: [])]), targetResults: [key: .resolved(HomebrewTarget(version: notes.availableVersion, sourceURL: notes.sourceURL))], releaseNoteResults: [key: .resolved(notes)]))
        XCTAssertEqual(try database.homebrewReleaseNotes(prefix: package.prefix, kind: package.kind, fullName: package.fullName, installedVersion: notes.installedVersion, availableVersion: notes.availableVersion), notes)
    }

    func testCompleteHomebrewPrefixMarksMissingPackageAndArtifactInactive() throws {
        let url = temporaryDatabaseURL()
        do {
            let database = try Database(url: url)
            let cask = homebrewPackage(kind: .cask, name: "example", artifacts: ["/Applications/Example.app"])
            let first = HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: cask.prefix, packages: [cask], complete: true, warnings: [])])
            _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 1_000), homebrewInventory: first, targetResults: [HomebrewPackageKey(cask): .unavailable("not checked")]))

            let empty = HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: cask.prefix, packages: [], complete: true, warnings: [])])
            _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 2_000), homebrewInventory: empty))

            XCTAssertTrue(try database.catalogItems().isEmpty)
            XCTAssertEqual(try database.catalogItems(includeAll: true).first?.active, false)
        }
        removeDatabase(at: url)
    }

    func testPartialHomebrewPrefixRetainsPreviouslyObservedPackages() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let formula = homebrewPackage(kind: .formula, name: "example")
        _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 1_000), homebrewInventory: HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: formula.prefix, packages: [formula], complete: true, warnings: [])]), targetResults: [HomebrewPackageKey(formula): .unavailable("not checked")]))

        _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 2_000), homebrewInventory: HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: formula.prefix, packages: [], complete: false, warnings: ["offline"])])))

        XCTAssertEqual(try database.catalogItems().map(\.name), ["example"])
    }

    func testChangedCaskArtifactsStopSuppressingOldNativeApplication() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let native = NativeApplication(path: "/Applications/Example.app", bundleIdentifier: "com.example.app", displayName: "Example", shortVersion: "1.0", buildVersion: nil, classification: .user, discoveryRoot: "/Applications")
        _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 1_000), nativeInventory: NativeInventoryResult(applications: [native], scannedRoots: ["/Applications"], candidatePaths: [native.path])))

        let cask = homebrewPackage(kind: .cask, name: "example", artifacts: [native.path])
        _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 2_000), homebrewInventory: HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: cask.prefix, packages: [cask], complete: true, warnings: [])]), targetResults: [HomebrewPackageKey(cask): .unavailable("not checked")]))
        XCTAssertFalse(try database.catalogItems().contains { $0.kind == .nativeApp })

        let movedCask = homebrewPackage(kind: .cask, name: "example", artifacts: ["/Applications/Renamed.app"])
        _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 3_000), homebrewInventory: HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: movedCask.prefix, packages: [movedCask], complete: true, warnings: [])]), targetResults: [HomebrewPackageKey(movedCask): .unavailable("not checked")]))
        XCTAssertTrue(try database.catalogItems().contains { $0.kind == .nativeApp })
    }

    func testAutoUpdatingCaskIsPersistedWithUpdate() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let cask = homebrewPackage(kind: .cask, name: "example", autoUpdates: true)
        let key = HomebrewPackageKey(cask)
        _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 1_000), homebrewInventory: HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: cask.prefix, packages: [cask], complete: true, warnings: [])]), targetResults: [key: .resolved(HomebrewTarget(version: "2.0", sourceURL: nil))]))

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
            (HomebrewPackageKey(package), HomebrewTargetResolution.resolved(HomebrewTarget(version: "2.0", sourceURL: nil)))
        })
        _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 1_000), homebrewInventory: HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: formula.prefix, packages: packages, complete: true, warnings: [])]), targetResults: targets))

        let dashboard = try database.dashboard()
        XCTAssertEqual(dashboard.data.availableUpdateCount, 1)
        XCTAssertEqual(dashboard.data.informationalUpdateCount, 1)
    }

    func testHomebrewUpdateFreshnessMarksOldEvidenceStale() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let formula = homebrewPackage(kind: .formula, name: "example")
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let key = HomebrewPackageKey(formula)
        let results = RefreshProvider.allCases.map {
            ProviderRefreshResult(provider: $0, status: .success, startedAt: observedAt, finishedAt: observedAt, dataAsOf: observedAt)
        }
        let input = RefreshPersistenceInput(startedAt: observedAt, finishedAt: observedAt, nativeInventory: NativeInventoryResult(applications: []), homebrewInventory: HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: formula.prefix, packages: [formula], complete: true, warnings: [])]), targetResults: [key: .resolved(HomebrewTarget(version: "2.0", sourceURL: nil))], releaseNoteResults: [:], providerResults: results)
        _ = try database.applyRefresh(input)

        let update = try XCTUnwrap(database.homebrewUpdates(now: observedAt.addingTimeInterval(120), staleAfter: 120).first)
        XCTAssertEqual(update.freshness, .stale)
        XCTAssertEqual(update.dataAsOf, observedAt)
        XCTAssertTrue(HomebrewRenderer.humanReadable([update]).contains("stale; data as of"))
    }

    func testUnifiedPartialRefreshKeepsMissingNativeApplicationsActive() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let application = NativeApplication(path: "/Applications/Example.app", bundleIdentifier: "com.example.app", displayName: "Example", shortVersion: "1.0", buildVersion: nil, classification: .user, discoveryRoot: "/Applications")
        _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 1_000), nativeInventory: NativeInventoryResult(applications: [application], scannedRoots: ["/Applications"], candidatePaths: [application.path])))

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
        XCTAssertEqual(try database.catalogItems(includeAll: true).first?.active, true)
        XCTAssertEqual(try database.dashboard(now: finishedAt).data.partialProviderCount, 1)
    }

    func testUnifiedRefreshRejectsReplayedCompletionTime() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let startedAt = Date(timeIntervalSince1970: 2_000)
        let finishedAt = Date(timeIntervalSince1970: 2_001)
        let results = RefreshProvider.allCases.map {
            ProviderRefreshResult(provider: $0, status: .success, startedAt: startedAt, finishedAt: finishedAt, dataAsOf: finishedAt)
        }
        let input = RefreshPersistenceInput(startedAt: startedAt, finishedAt: finishedAt, nativeInventory: NativeInventoryResult(applications: []), homebrewInventory: HomebrewInventory(prefixes: []), targetResults: [:], releaseNoteResults: [:], providerResults: results)

        _ = try database.applyRefresh(input)
        XCTAssertThrowsError(try database.applyRefresh(input)) { error in
            guard case .invalidRefreshInput = error as? DatabaseError else { return XCTFail("Expected refresh ordering error, got \(error)") }
        }
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

    func testMetadataCachePreservesEmptyBlob() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let requestURL = "https://formulae.brew.sh/api/formula/empty.json"
        try database.storeMetadataResponse(url: requestURL, resourceKind: "homebrew-target-v2", statusCode: 200, body: Data(), etag: nil, lastModified: nil, validatedAt: Date(timeIntervalSince1970: 1_000))

        let cached = try database.cachedMetadataResponse(url: requestURL, resourceKind: "homebrew-target-v2")
        XCTAssertEqual(cached?.body, Data())
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
        XCTAssertNil(try database.cachedMetadataResponse(url: requestURL, resourceKind: "github-release-list-v3-anonymous"))
    }

    func testGitHubRateLimitParsesHTTPDateAndIsSharedAcrossClients() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let requestURL = "https://api.github.com/repos/owner/repository/releases"
        let now = Date(timeIntervalSince1970: 1_000)
        let retryAt = now.addingTimeInterval(120)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        var requests = 0
        MetadataURLProtocol.handler = { _ in
            requests += 1
            return (429, nil, ["Retry-After": formatter.string(from: retryAt), "X-RateLimit-Reset": String(Int(now.addingTimeInterval(60).timeIntervalSince1970))])
        }
        defer { MetadataURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataURLProtocol.self]
        let environment = ["GITHUB_TOKEN": "http-date-test-token"]
        let first = MetadataHTTPClient(database: database, configuration: configuration, environment: environment, now: { now })
        let second = MetadataHTTPClient(database: database, configuration: configuration, environment: environment, now: { now })

        XCTAssertThrowsError(try first.fetch(URL(string: requestURL)!, resource: .githubReleaseList)) { error in
            guard case let .rateLimited(actualRetryAt) = error as? MetadataHTTPError else { return XCTFail("Expected rate-limit error, got \(error)") }
            XCTAssertEqual(actualRetryAt, retryAt)
        }
        XCTAssertThrowsError(try second.fetch(URL(string: requestURL)!, resource: .githubReleaseList)) { error in
            guard case let .rateLimited(actualRetryAt) = error as? MetadataHTTPError else { return XCTFail("Expected shared rate-limit error, got \(error)") }
            XCTAssertEqual(actualRetryAt, retryAt)
        }
        XCTAssertEqual(requests, 1)
    }

    func testGitHubSourceParsesExactArchiveAndReleaseTags() {
        XCTAssertEqual(
            GitHubSource.parse(URL(string: "https://github.com/owner/repository/archive/refs/tags/v1.2.3.tar.gz")!),
            GitHubSource(repository: GitHubRepository(owner: "owner", name: "repository"), tag: "v1.2.3")
        )
        XCTAssertEqual(
            GitHubSource.parse(URL(string: "https://github.com/owner/repository_name/archive/v1.2.3.tar.gz")!),
            GitHubSource(repository: GitHubRepository(owner: "owner", name: "repository_name"), tag: "v1.2.3")
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
        XCTAssertNil(GitHubSource.parse(URL(string: "https://user@github.com/owner/repository")!))
        XCTAssertNil(GitHubSource.parse(URL(string: "https://github.com:443/owner/repository")!))
        XCTAssertNil(GitHubSource.parse(URL(string: "https://github.com/owner/repository?ref=v1")!))
        XCTAssertNil(GitHubSource.parse(URL(string: "https://github.com/owner/repository#v1")!))
        XCTAssertNil(GitHubSource.parse(URL(string: "https://github.com/own%C3%A9r/repository")!))
        XCTAssertNil(GitHubSource.parse(URL(string: "https://github.com/owner_name/repository")!))
        XCTAssertNil(GitHubSource.parse(URL(string: "https://github.com/owner/repository/archive/refs/tags/%2E%2E.tar.gz")!))
        XCTAssertNil(GitHubSource.parse(URL(string: "https://github.com/owner/repository/releases/download/v1/%1Bunsafe.zip")!))
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
        XCTAssertTrue(output.contains("Safe\nnot terminal formatting"))
    }

    func testCompactReleaseNotesCollapseInstallAndDownloadSections() {
        let notes = HomebrewReleaseNotes(name: "example", installedVersion: "1.0", availableVersion: "2.0", content: "## Bug fixes\n- Fix an important issue\n\n## Install example\n```sh\ncurl example\n```\n\n## Download example\n| File | Platform |\n| --- | --- |", sourceURL: "https://example.test/release", coverage: "targetOnly")

        let compact = HomebrewRenderer.show(notes)
        XCTAssertTrue(compact.contains("Bug fixes"))
        XCTAssertTrue(compact.contains("Fix an important issue"))
        XCTAssertTrue(compact.contains("omitted"))
        XCTAssertFalse(compact.contains("curl example"))

        let full = HomebrewRenderer.show(notes, full: true)
        XCTAssertTrue(full.contains("curl example"))
    }

    func testTerminalSanitizerRemovesWholeEscapeSequences() {
        let text = "safe\u{1B}[31mcolored\u{1B}]8;;https://attacker.example\u{7}link\u{1B}Ppayload\u{1B}\\done\u{1B}Xhidden\u{1B}\\after\u{9B}2J"

        XCTAssertEqual(text.terminalText, "safecoloredlinkdoneafter")
        XCTAssertEqual("one\n\u{1B}]0;title\u{7}two".terminalInline, "one two")
        XCTAssertEqual("one\u{9D}title\u{1B}\\two".terminalText, "onetwo")
    }

    func testTerminalSanitizerRemovesBidiAndZeroWidthControls() {
        XCTAssertEqual("visible \u{202E}text\u{2066}!\u{200B}\u{200D}\u{FEFF}".terminalText, "visible text!")
        XCTAssertEqual("cafe \u{2615} \u{1F642}".terminalText, "cafe \u{2615} \u{1F642}")
    }

    func testHomebrewAPIUsesOnlySafePackagePathComponents() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        MetadataURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "formulae.brew.sh")
            XCTAssertEqual(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.percentEncodedPath, "/api/formula/openssl@3.json")
            return (200, Data("{\"versions\":{\"stable\":\"3.0\"}}".utf8), [:])
        }
        defer { MetadataURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataURLProtocol.self]
        let api = HomebrewAPI(metadataClient: MetadataHTTPClient(database: database, configuration: configuration))

        XCTAssertEqual(try api.target(for: homebrewPackage(kind: .formula, name: "openssl@3"))?.version, "3.0")
        XCTAssertNil(try api.target(for: homebrewPackage(kind: .formula, name: "openssl@3/../../attacker")))
        XCTAssertNil(try api.target(for: homebrewPackage(kind: .formula, name: "..")))
    }

    func testCommandRunnerStopsOversizedStreamingOutput() throws {
        let runner = CommandRunner()
        XCTAssertThrowsError(try runner.run(executable: URL(filePath: "/usr/bin/yes"), arguments: [], environment: ProcessInfo.processInfo.environment, timeout: 5, outputLimit: 1_024)) { error in
            XCTAssertEqual((error as? CommandRunnerError)?.errorDescription, CommandRunnerError.outputTooLarge(URL(filePath: "/usr/bin/yes")).errorDescription)
        }
    }

    func testCommandRunnerKillsOutputProducingDescendant() throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "sift-command-runner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = "trap '' TERM; sleep 0.1; (trap '' TERM; printf '%s' \"$$\" > \"$1\"; while :; do printf x; done) & wait"

        XCTAssertThrowsError(try CommandRunner().run(executable: URL(filePath: "/bin/sh"), arguments: ["-c", script, "sh", pidFile.path], environment: ProcessInfo.processInfo.environment, timeout: 5, outputLimit: 1_024)) { error in
            XCTAssertEqual((error as? CommandRunnerError)?.errorDescription, CommandRunnerError.outputTooLarge(URL(filePath: "/bin/sh")).errorDescription)
        }
        let childPID = try XCTUnwrap(Int32(String(decoding: try Data(contentsOf: pidFile), as: UTF8.self)))
        XCTAssertEqual(kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
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

    private func refreshInput(at date: Date, nativeInventory: NativeInventoryResult = NativeInventoryResult(applications: []), homebrewInventory: HomebrewInventory = HomebrewInventory(prefixes: []), targetResults: [HomebrewPackageKey: HomebrewTargetResolution] = [:], releaseNoteResults: [HomebrewPackageKey: HomebrewReleaseNotesResolution] = [:], providerStatuses: [RefreshProvider: ProviderRefreshStatus] = [:]) -> RefreshPersistenceInput {
        let providerResults = RefreshProvider.allCases.map { provider in
            let status = providerStatuses[provider] ?? .success
            return ProviderRefreshResult(provider: provider, status: status, startedAt: date, finishedAt: date, dataAsOf: status == .success ? date : nil)
        }
        return RefreshPersistenceInput(startedAt: date, finishedAt: date, nativeInventory: nativeInventory, homebrewInventory: homebrewInventory, targetResults: targetResults, releaseNoteResults: releaseNoteResults, providerResults: providerResults)
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

    private func temporaryDatabaseDirectory(mode: mode_t) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sift-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(directory.path, mode), 0)
        return directory
    }

    private func removeDatabase(at url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal", ".refresh.lock"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
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
