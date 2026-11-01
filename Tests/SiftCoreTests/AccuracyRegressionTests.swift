import Darwin
import Foundation
import XCTest
@testable import SiftCore

/// Regressions found by auditing a real machine's inventory against macOS and Homebrew.
final class AccuracyRegressionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "sift-accuracy-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Database requires a parent directory private to the current user.
        XCTAssertEqual(chmod(root.path, 0o700), 0)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Native inventory

    func testNativeProviderFollowsHiddenSymlinkedBundleAndClassifiesByDestination() throws {
        // macOS ships /Applications/Safari.app as a symlink (flagged hidden) into its Cryptex.
        let applications = root.appending(path: "Applications", directoryHint: .isDirectory)
        let destination = root.appending(path: "Cryptex/Linked.app")
        try makeBundle(at: destination, metadata: ["CFBundleIdentifier": "com.example.linked", "CFBundleName": "Linked", "CFBundleShortVersionString": "27.0"])
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let link = applications.appending(path: "Linked.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        XCTAssertEqual(lchflags(link.path, UInt32(UF_HIDDEN)), 0)

        let inventory = NativeApplicationProvider(
            roots: [NativeSearchRoot(url: applications, classification: .user, required: true)], homeDirectory: "/nonexistent"
        ).discover()

        XCTAssertTrue(inventory.complete)
        let application = try XCTUnwrap(inventory.applications.first)
        XCTAssertEqual(inventory.applications.count, 1)
        // The link's own path is recorded; its metadata comes from the destination.
        XCTAssertEqual(application.path, applications.resolvingSymlinksInPath().appending(path: "Linked.app").path)
        XCTAssertEqual(application.shortVersion, "27.0")
        // Classified by where the bundle really lives, not by the root holding the link.
        XCTAssertEqual(application.classification, .auxiliary)
    }

    func testNativeProviderSkipsDanglingSymlinkAndDeduplicatesLinkToSameBundle() throws {
        try makeBundle(at: root.appending(path: "Real.app"), metadata: ["CFBundleIdentifier": "com.example.real", "CFBundleName": "Real"])
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Alias.app"), withDestinationURL: root.appending(path: "Real.app"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Gone.app"), withDestinationURL: root.appending(path: "Missing.app"))

        let inventory = NativeApplicationProvider(roots: [NativeSearchRoot(url: root, classification: .user, required: true)]).discover()

        XCTAssertTrue(inventory.complete)
        XCTAssertEqual(inventory.warnings, [])
        XCTAssertEqual(inventory.applications.map(\.displayName), ["Real"])
    }

    func testNativeProviderSkipsDotDirectories() throws {
        try makeBundle(at: root.appending(path: ".hidden/Secret.app"), metadata: ["CFBundleIdentifier": "com.example.secret", "CFBundleName": "Secret"])
        try makeBundle(at: root.appending(path: "Visible.app"), metadata: ["CFBundleIdentifier": "com.example.visible", "CFBundleName": "Visible"])

        let inventory = NativeApplicationProvider(roots: [NativeSearchRoot(url: root, classification: .user, required: true)]).discover()

        XCTAssertEqual(inventory.applications.map(\.displayName), ["Visible"])
    }

    func testNativeProviderIgnoresInvisibleBundleNames() throws {
        // Several CoreServices agents set CFBundleDisplayName to a lone U+200E.
        try makeBundle(
            at: root.appending(path: "MediaRemoteUI.app"),
            metadata: ["CFBundleIdentifier": "com.example.a", "CFBundleDisplayName": "\u{200E}", "CFBundleName": "Media Remote"])
        try makeBundle(
            at: root.appending(path: "Blank.app"),
            metadata: ["CFBundleIdentifier": "com.example.b", "CFBundleDisplayName": " \u{200F} ", "CFBundleName": "\u{FEFF}"])

        let inventory = NativeApplicationProvider(roots: [NativeSearchRoot(url: root, classification: .user, required: true)]).discover()

        XCTAssertEqual(inventory.applications.map(\.displayName).sorted(), ["Blank", "Media Remote"])
    }

    func testNativeProviderClassifiesSteamDesktopShortcutAsLauncher() throws {
        let shortcut = root.appending(path: "Card Rogue.app")
        try makeBundle(at: shortcut, metadata: ["CFBundleExecutable": "run.sh", "CFBundleVersion": "1.0", "CFBundlePackageType": "APPL"])
        try writeFile(
            at: shortcut.appending(path: "Contents/MacOS/run.sh"), contents: "#!/bin/bash\n# autogenerated file - do not edit\nopen steam://run/1000010\n")
        // An identified app with a shell-script executable is still an application.
        let scripted = root.appending(path: "Scripted.app")
        try makeBundle(at: scripted, metadata: ["CFBundleIdentifier": "com.example.scripted", "CFBundleName": "Scripted", "CFBundleExecutable": "run.sh"])
        try writeFile(at: scripted.appending(path: "Contents/MacOS/run.sh"), contents: "#!/bin/sh\nopen steam://run/1\n")

        let inventory = NativeApplicationProvider(roots: [NativeSearchRoot(url: root, classification: .user, required: true)]).discover()

        let classifications = Dictionary(uniqueKeysWithValues: inventory.applications.map { ($0.displayName, $0.classification) })
        XCTAssertEqual(classifications, ["Card Rogue": .launcher, "Scripted": .user])
    }

    func testClassificationOfBundlesOutsideConfiguredRoots() {
        let home = "/Users/example"
        let expectations: [(String, ApplicationClassification)] = [
            ("/Applications/Tool.app", .user),
            ("/Applications/Utilities/Tool.app", .user),
            ("/Users/example/Applications/Tool.app", .user),
            ("/Users/example/Library/Application Support/Steam/steamapps/common/Game/Game.app", .user),
            ("/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app", .system),
            ("/Library/Apple/System/Library/CoreServices/XProtect.app", .coreService),
            ("/System/Library/CoreServices/Finder.app", .coreService),
            ("/Users/example/Library/Application Support/Gauge Menus 7/Gauge Menus Helper.app", .auxiliary),
            ("/Users/example/Library/Caches/com.example/Updater.app", .auxiliary),
            ("/Users/example/Projects/tool/dist/Tool.app", .auxiliary),
            ("/Library/Application Support/Vendor/Daemon.app", .auxiliary),
            ("/Users/example/ApplicationsBackup/Tool.app", .auxiliary)
        ]
        for (path, expected) in expectations {
            XCTAssertEqual(NativeApplicationProvider.classification(forPath: path, homeDirectory: home), expected, path)
        }
    }

    // MARK: - Homebrew

    func testSelfUpdatingCaskAlreadyAtLatestVersionIsNotReportedAsOutdated() throws {
        // Homebrew keeps reporting a self-updating cask at the version it installed; the bundle on
        // disk is the authority for whether the app has already updated itself.
        let updated = root.appending(path: "Updated.app")
        let behind = root.appending(path: "Behind.app")
        try makeBundle(at: updated, metadata: ["CFBundleIdentifier": "com.example.updated", "CFBundleShortVersionString": "158.0.1"])
        try makeBundle(at: behind, metadata: ["CFBundleIdentifier": "com.example.behind", "CFBundleShortVersionString": "2.0", "CFBundleVersion": "20000"])
        // Updated past the catalog, which lags the vendor.
        let ahead = root.appending(path: "Ahead.app")
        try makeBundle(at: ahead, metadata: ["CFBundleIdentifier": "com.example.ahead", "CFBundleShortVersionString": "4.1"])
        let brew = root.appending(path: "bin/brew")
        try writeFile(
            at: brew,
            contents: """
                #!/bin/sh
                case "$1" in
                    --prefix) echo "/fake/brew" ;;
                    info) printf '{"formulae":[],"casks":[{"token":"updated","full_token":"updated","installed":"158.0,1","auto_updates":true,"artifacts":[{"app":["Updated.app"],"target":"\(updated.path)"}]},{"token":"behind","full_token":"behind","installed":"2.0","auto_updates":true,"artifacts":[{"app":["Behind.app"],"target":"\(behind.path)"}]},{"token":"ahead","full_token":"ahead","installed":"3.0","auto_updates":true,"artifacts":[{"app":["Ahead.app"],"target":"\(ahead.path)"}]}]}' ;;
                    outdated) [ "$3" = "--greedy-auto-updates" ] || exit 3; printf '{"formulae":[],"casks":[{"name":"updated","installed_versions":["158.0,1"],"current_version":"158.0.1,2"},{"name":"behind","installed_versions":["2.0"],"current_version":"3.0"},{"name":"ahead","installed_versions":["3.0"],"current_version":"4.0"}]}' ;;
                    *) exit 1 ;;
                esac
                """, executable: true)
        let url = root.appending(path: "sift.sqlite3")
        let database = try Database(url: url)

        let summary = try coordinator(database: database, brewDirectory: brew.deletingLastPathComponent()).refresh(now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(summary.status, .success)
        let updates = try database.updates(includeAll: true, now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(updates.map(\.name), ["behind"], "a build number (20000) never counts as newer than 3.0")
        XCTAssertEqual(updates.first?.selfUpdating, true)
        XCTAssertEqual(try database.dashboard(now: Date(timeIntervalSince1970: 1_000)).data.informationalUpdateCount, 1)
    }

    // MARK: - npm

    func testNPMProviderSkipsRegistryCheckWhenOnlyNPMItselfIsInstalled() throws {
        // `npm outdated` contacts the registry and was the slowest call in a refresh; it is pointless
        // when the only global package is npm, which Sift never tracks.
        let npm = root.appending(path: "bin/npm")
        try writeFile(
            at: npm,
            contents: """
                #!/bin/sh
                case "$1" in
                    prefix) echo "/fake/npm" ;;
                    list) printf '{"dependencies":{"npm":{"version":"11.0.0"}}}' ;;
                    outdated) exit 7 ;;
                    *) exit 1 ;;
                esac
                """, executable: true)

        let inventory = NPMGlobalProvider(environment: [:], standardDirectories: [npm.deletingLastPathComponent().path]).discover()

        XCTAssertEqual(inventory.warnings, [])
        XCTAssertEqual(inventory.prefixes.map(\.prefix), ["/fake/npm"])
        XCTAssertEqual(inventory.prefixes.first?.packages, [])
        XCTAssertEqual(inventory.prefixes.first?.outdatedComplete, true)
    }

    func testUVProviderSkipsIndexCheckWithNoTools() throws {
        let uv = root.appending(path: "bin/uv")
        try writeFile(
            at: uv,
            contents: """
                #!/bin/sh
                case "$2" in
                    dir) echo "/fake/uv/tools" ;;
                    list) for argument in "$@"; do [ "$argument" = "--outdated" ] && exit 7; done; echo "No tools installed" ;;
                    *) exit 1 ;;
                esac
                """, executable: true)

        let inventory = UVToolProvider(environment: [:], standardDirectories: [uv.deletingLastPathComponent().path]).discover()

        XCTAssertEqual(inventory.warnings, [])
        XCTAssertEqual(inventory.installations.map(\.toolDirectory), ["/fake/uv/tools"])
        XCTAssertEqual(inventory.installations.first?.outdatedComplete, true)
    }

    // MARK: - Persistence

    func testDashboardReportsLatestProviderRunDetails() throws {
        let database = try Database(url: root.appending(path: "sift.sqlite3"))
        let started = Date(timeIntervalSince1970: 1_000)
        let finished = Date(timeIntervalSince1970: 1_030)
        let results = RefreshProvider.allCases.map { provider in
            provider == .npmGlobal
                ? ProviderRefreshResult(
                    provider: provider, status: .partial, message: "npm outdated timed out\nsecond line", warningCount: 1, startedAt: started,
                    finishedAt: finished, dataAsOf: nil)
                : ProviderRefreshResult(provider: provider, status: .success, startedAt: started, finishedAt: started, dataAsOf: started)
        }
        _ = try database.applyRefresh(
            RefreshPersistenceInput(
                startedAt: started, finishedAt: finished, nativeInventory: NativeInventoryResult(applications: []),
                homebrewInventory: HomebrewInventory(prefixes: []), targetResults: [:], releaseNoteResults: [:], providerResults: results))

        let dashboard = try database.dashboard(now: finished)
        let npm = try XCTUnwrap(dashboard.data.providerResults.first { $0.provider == .npmGlobal })
        XCTAssertEqual(npm.warningCount, 1)
        XCTAssertEqual(npm.message, "npm outdated timed out\nsecond line")
        XCTAssertEqual(npm.startedAt, started)
        XCTAssertEqual(npm.finishedAt, finished)
        XCTAssertTrue(DashboardRenderer.humanReadable(dashboard).contains("npm-global: npm outdated timed out"))
    }

    func testReadOnlyOpenRecreatesDeletedWALFiles() throws {
        // Any other SQLite client that closes the database last deletes -wal/-shm, which a
        // read-only connection cannot recreate on its own.
        let url = root.appending(path: "sift.sqlite3")
        do { _ = try Database(url: url) }
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }

        let database = try Database.readOnly(url: url)
        XCTAssertEqual(try database.dashboard().latestRefreshStatus, .never)
        for suffix in ["-wal", "-shm"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path + suffix)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, suffix)
        }
    }

    // MARK: - Helpers

    private func coordinator(database: Database, brewDirectory: URL) -> RefreshCoordinator {
        RefreshCoordinator(
            database: database,
            nativeProvider: NativeApplicationProvider(roots: [], includeSpotlight: false),
            homebrewProvider: HomebrewProvider(environment: [:], standardDirectories: [brewDirectory.path]),
            npmGlobalProvider: NPMGlobalProvider(environment: [:], standardDirectories: []),
            uvToolProvider: UVToolProvider(environment: [:], standardDirectories: []), steamProvider: .absent, macPortsProvider: .absent, cargoProvider: .absent
        )
    }

    private func makeBundle(at url: URL, metadata: [String: String]) throws {
        let plistURL = url.appending(path: "Contents/Info.plist")
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0).write(to: plistURL)
    }

    private func writeFile(at url: URL, contents: String, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        if executable { XCTAssertEqual(chmod(url.path, 0o755), 0) }
    }
}

final class MetadataConcurrencyTests: XCTestCase {
    func testConcurrentRateLimitedGitHubRequestsFailFast() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sift-rate-limit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitedURLProtocol.self]
        // Rate-limit state is shared per credential across clients by design; a unique token keeps
        // this test's block from leaking into other GitHub tests.
        let client = MetadataHTTPClient(
            database: try Database(url: root.appending(path: "sift.sqlite3")), configuration: configuration,
            environment: ["GITHUB_TOKEN": "test-\(UUID().uuidString)"])

        let started = Date()
        let group = DispatchGroup()
        let failures = LockedCounter()
        for index in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    _ = try client.fetch(URL(string: "https://api.github.com/repos/example/repo\(index)/releases/tags/v1")!, resource: .githubReleaseByTag)
                } catch MetadataHTTPError.rateLimited { failures.increment() } catch {}
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(failures.value, 20)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private final class RateLimitedURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reset = String(Int(Date().timeIntervalSince1970) + 600)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": reset])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"message":"API rate limit exceeded"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
