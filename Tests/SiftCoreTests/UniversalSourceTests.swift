import CSQLite
import Darwin
import Foundation
import XCTest
@testable import SiftCore

/// Update sources beyond package managers' own CLIs: Homebrew's cask catalog, Steam's library
/// manifests, MacPorts' registry and port index, and Blackmagic's downloads feed.
final class UniversalSourceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "sift-universal-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Homebrew cask catalog

    func testCaskCatalogMatchesOnlyByExactBundleIdentifierEvidence() throws {
        let catalog = try HomebrewCaskCatalog(data: Data("""
            [
              {"token":"net-guard","version":"6.5","artifacts":[{"uninstall":[{"quit":"com.example.netguard"}]},{"app":["Net Guard.app"]}]},
              {"token":"net-guard@nightly","version":"6.6","artifacts":[{"uninstall":[{"quit":"com.example.netguard"}]},{"app":["Net Guard.app"]}]},
              {"token":"hypervise","version":"5.0.8","artifacts":[{"app":["Hypervise.app"]},{"zap":[{"trash":["~/Library/Containers/com.hypervise.Hypervise","~/Library/Preferences/com.hypervise.Hypervise.plist"]}]}]},
              {"token":"hypervise@beta","version":"5.1.0","artifacts":[{"app":["Hypervise.app"]},{"zap":[{"trash":["~/Library/Preferences/com.hypervise.Hypervise.plist"]}]}]},
              {"token":"beat-studio","version":"26.1.7.5421","artifacts":[{"pkg":["Install Beat Studio.pkg"]},{"zap":[{"trash":"~/Library/Preferences/com.example.beatstudio.plist"}]}]},
              {"token":"lookalike","version":"9.0","artifacts":[{"app":["Net Guard.app"]}]},
              {"token":"rolling","version":"latest","artifacts":[{"app":["Rolling.app"]},{"uninstall":[{"quit":"com.example.rolling"}]}]},
              {"token":"twins-a","version":"1.0","artifacts":[{"uninstall":[{"quit":"com.example.twin"}]}]},
              {"token":"twins-b","version":"1.1","artifacts":[{"uninstall":[{"quit":"com.example.twin"}]}]}
            ]
            """.utf8))

        // Quit stanza names the identifier; the stable cask wins over its @nightly variant.
        XCTAssertEqual(catalog.entry(bundleIdentifier: "com.example.NetGuard", bundleFileName: "Net Guard.app")?.token, "net-guard")
        // App name plus an identifier in zap paths, preferring the stable cask.
        XCTAssertEqual(catalog.entry(bundleIdentifier: "com.hypervise.Hypervise", bundleFileName: "Hypervise.app")?.version, "5.0.8")
        // A package installer whose zap paths name the identifier.
        XCTAssertEqual(catalog.entry(bundleIdentifier: "com.example.beatstudio", bundleFileName: "Beat Studio 2026.app")?.token, "beat-studio")
        // A matching name alone is never enough.
        XCTAssertNil(catalog.entry(bundleIdentifier: "com.other.guard", bundleFileName: "Net Guard.app"))
        // A prefix of a mentioned identifier is not a match for a different app.
        XCTAssertNil(catalog.entry(bundleIdentifier: "com.hypervise", bundleFileName: "Hypervise.app"))
        // Unversioned casks and ambiguous evidence give no answer.
        XCTAssertNil(catalog.entry(bundleIdentifier: "com.example.rolling", bundleFileName: "Rolling.app"))
        XCTAssertNil(catalog.entry(bundleIdentifier: "com.example.twin", bundleFileName: "Twin.app"))
        XCTAssertNil(catalog.entry(bundleIdentifier: nil, bundleFileName: "Hypervise.app"))
    }

    func testResolverFallsBackToCaskCatalogWhenUpdaterIsUnreadable() throws {
        StubCatalogProtocol.body = #"[{"token":"canvas","version":"3.3.1,4501","artifacts":[{"app":["Canvas.app"]},{"uninstall":[{"quit":"com.canvasapp.canvas"}]}]}]"#
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubCatalogProtocol.self]
        StubCatalogProtocol.requests = 0
        let database = try Database(url: root.appending(path: "sift.sqlite3"))
        let resolver = NativeUpdateResolver(metadataClient: MetadataHTTPClient(database: database, configuration: configuration, environment: [:]), storefront: "us", systemVersion: "26.0")
        // Sparkle with a run-time feed: unreadable, so the catalog answers.
        let canvas = NativeApplication(path: "/Applications/Canvas.app", bundleIdentifier: "com.canvasapp.canvas", displayName: "Canvas", shortVersion: "3.2.3", buildVersion: "3020300", classification: .user, discoveryRoot: "/Applications", updateAuthority: .sparkle)
        let check = resolver.resolve(canvas)
        XCTAssertEqual(check.authority, .homebrewCatalog)
        XCTAssertEqual(check.outcome, .available(version: "3.3.1", notes: nil))
        XCTAssertEqual(check.note, "Latest version from the Homebrew cask \u{201C}canvas\u{201D}.")
        // Unmatched apps keep the original explanation; the catalog was fetched only once.
        let other = NativeApplication(path: "/Applications/Other.app", bundleIdentifier: "com.example.other", displayName: "Other", shortVersion: "1.0", buildVersion: "1", classification: .user, discoveryRoot: "/Applications")
        guard case .unchecked = resolver.resolve(other).outcome else { return XCTFail() }
        XCTAssertEqual(StubCatalogProtocol.requests, 1)
        // A new client (the next refresh) reads the catalog back from compressed cache storage.
        let second = NativeUpdateResolver(metadataClient: MetadataHTTPClient(database: database, configuration: configuration, environment: [:]), storefront: "us", systemVersion: "26.0")
        XCTAssertEqual(second.resolve(canvas).outcome, .available(version: "3.3.1", notes: nil))
        XCTAssertEqual(StubCatalogProtocol.requests, 1)
    }

    // MARK: - Steam

    func testSteamProviderReadsEveryLibraryAndPendingBuilds() throws {
        let steam = root.appending(path: "Steam", directoryHint: .isDirectory)
        let external = root.appending(path: "External Library", directoryHint: .isDirectory)
        try write(steam.appending(path: "steamapps/libraryfolders.vdf"), """
            "libraryfolders"
            {
            \t"0" { "path" "\(steam.path)" "apps" { "1000010" "1" } }
            \t"1" { "path" "\(external.path)" }
            \t"2" { "path" "/Volumes/Unplugged" }
            }
            """)
        try write(steam.appending(path: "steamapps/appmanifest_1000010.acf"), """
            "AppState"
            {
            \t"appid"\t\t"1000010"
            \t"name"\t\t"Card Rogue"
            \t"StateFlags"\t\t"4"
            \t"installdir"\t\t"Card Rogue"
            \t"buildid"\t\t"12000001"
            \t"TargetBuildID"\t\t"12000001"
            \t"InstalledDepots" { "1000012" { "manifest" "1" } }
            }
            """)
        try write(external.appending(path: "steamapps/appmanifest_1000020.acf"), """
            "AppState" { "appid" "1000020" "name" "Bastion Siege 6" "StateFlags" "6" "installdir" "BastionSiege6" "buildid" "21000001" "TargetBuildID" "21000002" }
            """)
        try write(external.appending(path: "steamapps/appmanifest_1.acf"), "not a manifest")

        let inventory = SteamProvider(steamDirectory: steam).discover()

        XCTAssertTrue(inventory.detected)
        XCTAssertEqual(inventory.libraries.map(\.path), [steam.path, external.path])
        XCTAssertEqual(inventory.libraries[0].games, [SteamGame(appID: "1000010", name: "Card Rogue", buildID: "12000001", pendingBuildID: nil, installDirectory: steam.appending(path: "steamapps/common/Card Rogue").path)])
        XCTAssertEqual(inventory.libraries[1].games.first?.pendingBuildID, "21000002")
        XCTAssertEqual(inventory.warnings.count, 1)
        XCTAssertFalse(SteamProvider(steamDirectory: root.appending(path: "missing")).discover().detected)
    }

    // MARK: - MacPorts

    func testMacPortsProviderReadsRegistryAndIndexWithoutRunningPort() throws {
        let prefix = root.appending(path: "opt-local", directoryHint: .isDirectory)
        try makeRegistry(at: prefix.appending(path: "var/macports/registry/registry.db"))
        try write(prefix.appending(path: "etc/macports/sources.conf"), "# comment\nrsync://rsync.macports.org/macports/release/tarballs/ports.tar.gz [default]\n")
        try write(prefix.appending(path: "var/macports/sources/rsync.macports.org/macports/release/tarballs/ports/PortIndex"), """
            R-A3 120
            depends_build {port:clang-22 port:R} description {Accurate {nested} metrics} name R-A3 version 1.0.0 revision 1 portdir R/R-A3
            arangodb 60
            long_description {🥑 A database} name arangodb version 3.8.5.1 revision 0
            xz 90
            long_description {XZ compresses
            across lines \\{ with a stray brace} name xz version 5.8.1 revision 0
            python314 200
            variants {universal lto} description {An interpreted language} name python314 epoch 0 version 3.14.8 categories lang revision 0 portdir lang/python314
            zlib 80
            name zlib version 1.3.2 revision 0 epoch 0 description {A {lossless} library}
            """)

        let inventory = MacPortsProvider(prefix: prefix).discover()

        XCTAssertEqual(inventory.prefix, prefix.path)
        XCTAssertTrue(inventory.indexAvailable)
        XCTAssertEqual(inventory.ports.map(\.name), ["python314", "zlib"])
        let python = try XCTUnwrap(inventory.ports.first)
        XCTAssertEqual(python.displayVersion, "3.14.7_0")
        XCTAssertFalse(python.requested)
        XCTAssertEqual(python.applicationPaths, ["/Applications/MacPorts/Python 3.14/IDLE.app"])
        XCTAssertEqual(inventory.index["python314"]?.displayVersion, "3.14.8_0")
        XCTAssertNil(inventory.index["R-A3"])
        XCTAssertTrue(MacPortsProvider.isOutdated(python, index: try XCTUnwrap(inventory.index["python314"])))
        XCTAssertFalse(MacPortsProvider.isOutdated(inventory.ports[1], index: try XCTUnwrap(inventory.index["zlib"])))
    }

    func testMacPortsVersionOrdering() {
        let ascending: [(String, String)] = [("1.3.1", "1.3.2"), ("1.9", "1.10"), ("20260512-3.1", "20260601-3.1"), ("1.0a", "1.0.1"), ("2.7", "2.7.1")]
        for (older, newer) in ascending {
            XCTAssertEqual(MacPortsProvider.compareVersions(older, newer), .orderedAscending, "\(older) < \(newer)")
            XCTAssertEqual(MacPortsProvider.compareVersions(newer, older), .orderedDescending, "\(newer) > \(older)")
        }
        XCTAssertEqual(MacPortsProvider.compareVersions("1.0.0", "1.0.0"), .orderedSame)
        let installed = MacPort(name: "openssl", epoch: 1, version: "3", revision: 31, requested: false, applicationPaths: [])
        XCTAssertFalse(MacPortsProvider.isOutdated(installed, index: MacPortsIndexEntry(epoch: 0, version: "4", revision: 0)))
        XCTAssertTrue(MacPortsProvider.isOutdated(installed, index: MacPortsIndexEntry(epoch: 1, version: "3", revision: 32)))
    }

    // MARK: - Blackmagic

    func testBlackmagicDownloadsIgnoreBetasAndPickNewestMacRelease() throws {
        let downloads = try BlackmagicDownloads(data: Data("""
            {"downloads":[
              {"name":"DaVinci Resolve 21.2 Public Beta","urls":{"Mac OS X":[{"product":"davinci-resolve","major":21,"minor":2,"releaseNum":0}]}},
              {"name":"DaVinci Resolve 21.1.1 Update","urls":{"Mac OS X":[{"product":"davinci-resolve","major":21,"minor":1,"releaseNum":1}],"Windows":[{"product":"davinci-resolve","major":22,"minor":0,"releaseNum":0}]}},
              {"name":"DaVinci Resolve 21.0.4 Update","urls":{"Mac OS X":[{"product":"davinci-resolve","major":21,"minor":0,"releaseNum":4}]}},
              {"name":"Blackmagic RAW 6.0","urls":{"Mac OS X":[{"product":"braw-sdk","major":6,"minor":0,"releaseNum":0}]}}
            ]}
            """.utf8))
        XCTAssertEqual(downloads.latestVersion(product: "davinci-resolve"), "21.1.1")
        XCTAssertEqual(downloads.latestVersion(product: "braw-sdk"), "6.0")
        XCTAssertNil(downloads.latestVersion(product: "davinci-resolve-studio"))
        XCTAssertEqual(BlackmagicDownloads.product(forBundleIdentifier: "com.blackmagic-design.DaVinciResolve"), "davinci-resolve")
        XCTAssertNil(BlackmagicDownloads.product(forBundleIdentifier: "com.blackmagic-design.UninstallDaVinciResolve"))
    }

    // MARK: - Cargo

    func testCargoProviderReadsInstallRecordAndSkipsMissingOrNonRegistryCrates() throws {
        let home = root.appending(path: "cargo", directoryHint: .isDirectory)
        try write(home.appending(path: ".crates2.json"), """
            {"installs":{
              "plotkit 0.4.17 (registry+https://github.com/rust-lang/crates.io-index)":{"bins":["plot"]},
              "gone 1.0.0 (registry+https://github.com/rust-lang/crates.io-index)":{"bins":["gone"]},
              "local-tool 0.1.0 (path+file:///Users/example/tool)":{"bins":["local-tool"]}
            }}
            """)
        for binary in ["plot", "local-tool"] {
            try write(home.appending(path: "bin/\(binary)"), "#!/bin/sh\n")
            XCTAssertEqual(chmod(home.appending(path: "bin/\(binary)").path, 0o755), 0)
        }
        let inventory = CargoProvider(cargoHome: home).discover()
        XCTAssertEqual(inventory.crates, [CargoCrate(name: "plotkit", version: "0.4.17")])
        XCTAssertNil(CargoProvider(cargoHome: root.appending(path: "missing")).discover().cargoHome)
    }

    func testCargoSparseIndexPathsAndLatestVersion() {
        XCTAssertEqual(CargoProvider.indexURL(for: "a")?.absoluteString, "https://index.crates.io/1/a")
        XCTAssertEqual(CargoProvider.indexURL(for: "ab")?.absoluteString, "https://index.crates.io/2/ab")
        XCTAssertEqual(CargoProvider.indexURL(for: "abc")?.absoluteString, "https://index.crates.io/3/a/abc")
        XCTAssertEqual(CargoProvider.indexURL(for: "PlotKit")?.absoluteString, "https://index.crates.io/pl/ot/plotkit")
        XCTAssertNil(CargoProvider.indexURL(for: "../etc"))
        let index = Data("""
            {"name":"plotkit","vers":"1.1.1","yanked":false}
            {"name":"plotkit","vers":"1.2.0","yanked":true}
            {"name":"plotkit","vers":"1.10.0-beta.1","yanked":false}
            {"name":"plotkit","vers":"1.1.2+build.5","yanked":false}
            {"name":"plotkit","vers":"0.4.17","yanked":false}
            """.utf8)
        XCTAssertEqual(CargoProvider.latestVersion(indexData: index, installed: "0.4.17"), "1.1.2")
        XCTAssertEqual(CargoProvider.latestVersion(indexData: index, installed: "1.0.0-rc.1"), "1.10.0-beta.1")
    }

    func testSetappApplicationsAreAttributedToSetapp() throws {
        // Setapp installs into /Applications/Setapp, which a test can't write, so the classifier
        // is exercised through the bundle path it sees.
        let resolver = NativeUpdateResolver(metadataClient: MetadataHTTPClient(database: try Database(url: root.appending(path: "sift.sqlite3")), configuration: .ephemeral, environment: [:]))
        let app = NativeApplication(path: "/Applications/Setapp/CleanMyMac.app", bundleIdentifier: "com.macpaw.CleanMyMac-setapp", displayName: "CleanMyMac", shortVersion: "5.0", buildVersion: "1", classification: .user, discoveryRoot: "/Applications", updateAuthority: .setapp)
        XCTAssertEqual(resolver.resolve(app).outcome, .unchecked("Setapp installs updates for its apps."))
    }

    // MARK: - Persistence

    func testManagedPackagesHonorRequestedSelfUpdatingAndApplicationOwnership() throws {
        let database = try Database(url: root.appending(path: "sift.sqlite3"))
        let date = Date(timeIntervalSince1970: 1_000)
        let idle = NativeApplication(path: "/Applications/MacPorts/Python 3.14/IDLE.app", bundleIdentifier: "org.python.IDLE", displayName: "IDLE", shortVersion: "3.14.7", buildVersion: nil, classification: .user, discoveryRoot: "/Applications")
        let inventories = [
            ManagedPackageInventory(provider: .macPorts, scopes: [ManagedPackageScope(scope: "/opt/local", packages: [
                ManagedPackage(name: "python314", installedVersion: "3.14.7_0", availableVersion: "3.14.8_0", requested: false, applicationPaths: [idle.path]),
                ManagedPackage(name: "py313-Pillow", installedVersion: "12.3.0_0", availableVersion: "12.4.0_0"),
            ])]),
            ManagedPackageInventory(provider: .steamGames, scopes: [ManagedPackageScope(scope: "/Steam", packages: [
                ManagedPackage(name: "Bastion Siege 6", installedVersion: "21000001", availableVersion: "21000002", selfUpdating: true),
            ])]),
        ]
        let results = RefreshProvider.allCases.map { ProviderRefreshResult(provider: $0, status: .success, startedAt: date, finishedAt: date, dataAsOf: date) }
        _ = try database.applyRefresh(RefreshPersistenceInput(startedAt: date, finishedAt: date, nativeInventory: NativeInventoryResult(applications: [idle], scannedRoots: ["/Applications"]), homebrewInventory: HomebrewInventory(prefixes: []), targetResults: [:], releaseNoteResults: [:], managedPackageInventories: inventories, providerResults: results))

        XCTAssertEqual(try database.updates(now: date).map { "\($0.provider) \($0.name) \($0.selfUpdating)" }, ["steam-games Bastion Siege 6 true", "macports py313-Pillow false"])
        XCTAssertEqual(try database.updates(includeAll: true, now: date).map(\.name), ["Bastion Siege 6", "py313-Pillow", "python314"])
        let dashboard = try database.dashboard(now: date)
        XCTAssertEqual(dashboard.data.availableUpdateCount, 1)
        XCTAssertEqual(dashboard.data.informationalUpdateCount, 1)
        XCTAssertEqual(try database.nativeApplicationItems().first?.updateSource, "macports")
        XCTAssertEqual(try database.catalogItems().map(\.name), ["IDLE"])
    }

    // MARK: - Helpers

    private func write(_ url: URL, _ contents: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    /// A registry with MacPorts' real table shapes (minus its custom VERSION collation).
    private func makeRegistry(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let sql = """
            CREATE TABLE ports (id INTEGER PRIMARY KEY, name TEXT COLLATE NOCASE, epoch INTEGER, version TEXT, revision INTEGER, state TEXT, requested INTEGER);
            CREATE TABLE files (id INTEGER, path TEXT, actual_path TEXT, active INTEGER, binary BOOL);
            INSERT INTO ports VALUES (1, 'python314', 0, '3.14.7', 0, 'installed', 0), (2, 'zlib', 0, '1.3.2', 0, 'installed', 1), (3, 'old', 0, '1.0', 0, 'imaged', 1);
            INSERT INTO files VALUES (1, '/Applications/MacPorts/Python 3.14/IDLE.app/Contents/Info.plist', NULL, 1, 0),
                                     (1, '/opt/local/Library/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/Info.plist', NULL, 1, 0),
                                     (1, '/opt/local/bin/python3.14', NULL, 1, 1);
            """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    }
}

private final class StubCatalogProtocol: URLProtocol {
    nonisolated(unsafe) static var body = "[]"
    nonisolated(unsafe) static var requests = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["ETag": "\"v1\""])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
