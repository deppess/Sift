import Darwin
import Foundation
import XCTest
@testable import SiftCore

/// Evidence used for apps no direct update authority covers: saved Sparkle feeds, links into
/// package managers, same-vendor bundles, the app's own GitHub release check, Electron manifests,
/// and the catalog's name-plus-vendor-domain tier.
final class FallbackSourceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "sift-fallback-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        FallbackStubProtocol.responses = [:]
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSparkleFeedSavedInPreferencesIsUsedWhenInfoPlistHasNone() throws {
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let applications = home.appending(path: "Applications", directoryHint: .isDirectory)
        let app = applications.appending(path: "Canvas.app")
        try makeBundle(app, ["CFBundleIdentifier": "com.canvasapp.canvas", "CFBundleShortVersionString": "3.2.3"])
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/Frameworks/Sparkle.framework"), withIntermediateDirectories: true)
        let preferences = home.appending(path: "Library/Containers/com.canvasapp.canvas/Data/Library/Preferences/com.canvasapp.canvas.plist")
        try FileManager.default.createDirectory(at: preferences.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["SUFeedURL": "https://updates.canvasapp.net/canvas-update"], format: .binary, options: 0).write(to: preferences)

        let inventory = NativeApplicationProvider(roots: [NativeSearchRoot(url: applications, classification: .user, required: true)], homeDirectory: home.path).discover()

        XCTAssertEqual(inventory.applications.first?.updateAuthority, .sparkle)
        XCTAssertEqual(inventory.applications.first?.sparkleFeedURL, "https://updates.canvasapp.net/canvas-update")
    }

    func testSparkleFeedMayRedirectToAnotherPublicHostOnly() throws {
        FallbackStubProtocol.responses["https://feeds.example.com/app"] = .redirect("https://bucket.s3.amazonaws.com/app.xml")
        FallbackStubProtocol.responses["https://bucket.s3.amazonaws.com/app.xml"] = .body(#"<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure url="https://x.example.com/a.zip" sparkle:version="20" sparkle:shortVersionString="2.0"/></item></channel></rss>"#)
        FallbackStubProtocol.responses["https://feeds.example.com/local"] = .redirect("https://192.168.0.10/app.xml")
        let resolver = try makeResolver()
        XCTAssertEqual(resolver.check(sparkleApp(feed: "https://feeds.example.com/app")), .available(version: "2.0", notes: nil))
        guard case .failed = resolver.check(sparkleApp(feed: "https://feeds.example.com/local")) else { return XCTFail() }
    }

    func testApplicationLinkedIntoACaskroomIsOwnedByThatCask() throws {
        // Claude Code's URL handler: a bundle whose executable links into the claude-code cask.
        let applications = root.appending(path: "Applications", directoryHint: .isDirectory)
        let caskroom = root.appending(path: "brew/Caskroom/claude-code/2.1.292", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: caskroom, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: caskroom.appending(path: "claude"))
        let app = applications.appending(path: "Claude Code URL Handler.app")
        try makeBundle(app, ["CFBundleIdentifier": "com.anthropic.claude-code-url-handler", "CFBundleVersion": "1.0", "CFBundleExecutable": "claude"])
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: app.appending(path: "Contents/MacOS/claude"), withDestinationURL: caskroom.appending(path: "claude"))
        let prefix = root.appending(path: "brew").resolvingSymlinksInPath().path
        let brew = root.appending(path: "bin/brew")
        try FileManager.default.createDirectory(at: brew.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
            #!/bin/sh
            case "$1" in
                --prefix) echo "\(prefix)" ;;
                info) printf '{"formulae":[],"casks":[{"token":"claude-code","full_token":"claude-code","installed":"2.1.292","artifacts":[]}]}' ;;
                outdated) printf '{"formulae":[],"casks":[{"name":"claude-code","installed_versions":["2.1.292"],"current_version":"2.1.308"}]}' ;;
                *) exit 1 ;;
            esac
            """.utf8).write(to: brew)
        XCTAssertEqual(chmod(brew.path, 0o755), 0)
        let database = try Database(url: root.appending(path: "sift.sqlite3"))
        let coordinator = RefreshCoordinator(
            database: database,
            nativeProvider: NativeApplicationProvider(roots: [NativeSearchRoot(url: applications, classification: .user, required: true)], includeSpotlight: false, homeDirectory: "/nonexistent"),
            homebrewProvider: HomebrewProvider(environment: [:], standardDirectories: [brew.deletingLastPathComponent().path]),
            npmGlobalProvider: NPMGlobalProvider(environment: [:], standardDirectories: []),
            uvToolProvider: UVToolProvider(environment: [:], standardDirectories: []), steamProvider: .absent, macPortsProvider: .absent, cargoProvider: .absent,
            nativeUpdates: UnreachableResolver()
        )
        _ = try coordinator.refresh(now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(try database.nativeApplicationItems().first?.updateSource, "homebrew")
        XCTAssertEqual(try database.updates(now: Date(timeIntervalSince1970: 1_000)).map(\.name), ["claude-code"])
    }

    func testBundledUtilitiesAreCreditedToTheirProductsApplication() throws {
        let applications = root.appending(path: "Applications", directoryHint: .isDirectory)
        let resolve = applications.appending(path: "DaVinci Resolve/DaVinci Resolve.app")
        let monitor = applications.appending(path: "DaVinci Resolve/Blackmagic Remote Monitor.app")
        let stranger = applications.appending(path: "DaVinci Resolve/Other.app")
        try makeBundle(resolve, ["CFBundleIdentifier": "com.blackmagic-design.DaVinciResolve", "CFBundleShortVersionString": "21.0.4"])
        try makeBundle(monitor, ["CFBundleIdentifier": "com.blackmagic-design.DaVinciRemoteMonitor", "CFBundleShortVersionString": "21.0"])
        try makeBundle(stranger, ["CFBundleIdentifier": "com.example.other", "CFBundleShortVersionString": "1.0"])
        let database = try Database(url: root.appending(path: "sift.sqlite3"))
        let coordinator = RefreshCoordinator(
            database: database,
            nativeProvider: NativeApplicationProvider(roots: [NativeSearchRoot(url: applications, classification: .user, required: true)], includeSpotlight: false, homeDirectory: "/nonexistent"),
            homebrewProvider: HomebrewProvider(environment: [:], standardDirectories: []),
            npmGlobalProvider: NPMGlobalProvider(environment: [:], standardDirectories: []),
            uvToolProvider: UVToolProvider(environment: [:], standardDirectories: []), steamProvider: .absent, macPortsProvider: .absent, cargoProvider: .absent,
            nativeUpdates: FixedResolver(answers: ["com.blackmagic-design.DaVinciResolve": .available(version: "21.1.1", notes: nil)])
        )
        _ = try coordinator.refresh(now: Date(timeIntervalSince1970: 1_000))

        let items = Dictionary(uniqueKeysWithValues: try database.nativeApplicationItems().map { ($0.name, $0) })
        XCTAssertEqual(items["DaVinci Resolve"]?.availableVersion, "21.1.1")
        XCTAssertEqual(items["Blackmagic Remote Monitor"]?.updateSource, "bundled")
        XCTAssertEqual(items["Blackmagic Remote Monitor"]?.updateDetail, "Installed and updated with DaVinci Resolve. DaVinci Resolve 21.1.1 is available.")
        XCTAssertNil(items["Blackmagic Remote Monitor"]?.availableVersion)
        // A different vendor in the same folder is not credited.
        XCTAssertEqual(items["Other"]?.updateSource, "unknown")
        XCTAssertEqual(try database.dashboard(now: Date(timeIntervalSince1970: 1_000)).data.availableUpdateCount, 1)
    }

    func testReleaseCheckRepositoryMustBeTheAppsOwn() {
        let beacon = NativeApplication(path: "/Applications/Beacon.app", bundleIdentifier: "com.brightside.beacon", displayName: "Beacon", shortVersion: "1.1.8", buildVersion: "18")
        let urls = [
            "https://api.github.com/repos/Brightside/beacon/releases?per_page=100",
            "https://api.github.com/repos/Brightside/beacon/contributors",
            "https://github.com/sparkle-project/Sparkle/releases",
            "https://github.com/brightside/beacon/releases/latest",
        ].compactMap(URL.init(string:))
        XCTAssertEqual(BundleURLScanner.releaseRepository(in: urls, for: beacon), GitHubRepository(owner: "Brightside", name: "beacon"))
        // Repository links and other projects' release pages are not the app's update check.
        let switcher = NativeApplication(path: "/Applications/Switcher.app", bundleIdentifier: "com.northwind.switcher", displayName: "Switcher", shortVersion: "11", buildVersion: "11")
        XCTAssertNil(BundleURLScanner.releaseRepository(in: ["https://github.com/northwind/switcher", "https://github.com/sparkle-project/Sparkle/releases"].compactMap(URL.init(string:)), for: switcher))
    }

    func testBundleURLScannerReadsExecutableBytes() throws {
        let app = root.appending(path: "Beacon.app")
        try makeBundle(app, ["CFBundleIdentifier": "com.brightside.beacon", "CFBundleExecutable": "Beacon"])
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        var binary = Data([0xCF, 0xFA, 0xED, 0xFE, 0, 0])
        binary.append(Data("https://api.github.com/repos/Brightside/beacon/releases?per_page=100".utf8))
        binary.append(contentsOf: [0, 0x01, 0xFF])
        binary.append(Data("xxhttps://tinyvendor.io\u{0}".utf8))
        try binary.write(to: app.appending(path: "Contents/MacOS/Beacon"))
        let urls = BundleURLScanner.urls(in: NativeApplication(path: app.path, bundleIdentifier: nil, displayName: "Beacon", shortVersion: nil, buildVersion: nil)).map(\.absoluteString)
        XCTAssertEqual(Set(urls), ["https://api.github.com/repos/Brightside/beacon/releases?per_page=100", "https://tinyvendor.io"])
    }

    func testResolverUsesTheAppsGitHubReleaseCheck() throws {
        let app = root.appending(path: "Beacon.app")
        try makeBundle(app, ["CFBundleIdentifier": "com.brightside.beacon", "CFBundleExecutable": "Beacon", "CFBundleShortVersionString": "1.1.7"])
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try Data("https://api.github.com/repos/Brightside/beacon/releases".utf8).write(to: app.appending(path: "Contents/MacOS/Beacon"))
        FallbackStubProtocol.responses["https://formulae.brew.sh/api/cask.json"] = .body("[]")
        FallbackStubProtocol.responses["https://api.github.com/repos/Brightside/beacon/releases/latest"] = .body(#"{"tag_name":"v1.1.8","draft":false,"prerelease":false,"body":"Fixes","html_url":"https://github.com/Brightside/beacon/releases/tag/v1.1.8"}"#)
        let check = try makeResolver().resolve(NativeApplication(path: app.path, bundleIdentifier: "com.brightside.beacon", displayName: "Beacon", shortVersion: "1.1.7", buildVersion: "17", classification: .user))
        XCTAssertEqual(check.authority, .githubReleases)
        XCTAssertEqual(check.outcome, .available(version: "1.1.8", notes: NativeReleaseNotes(content: "Fixes", sourceURL: "https://github.com/Brightside/beacon/releases/tag/v1.1.8")))
    }

    func testElectronManifestsAndFeeds() throws {
        XCTAssertEqual(ElectronUpdateManifest(yaml: "owner: example\nrepo: 'tool'\nprovider: github\nupdaterCacheDirName: tool-updater\n")?.source, .github(GitHubRepository(owner: "example", name: "tool")))
        XCTAssertEqual(ElectronUpdateManifest(yaml: "provider: generic\nurl: https://downloads.example.com/mac\n")?.source, .generic(URL(string: "https://downloads.example.com/mac")!))
        XCTAssertEqual(ElectronUpdateManifest(yaml: "provider: s3\nbucket: x\n")?.source, .unsupported("s3"))
        XCTAssertNil(ElectronUpdateManifest(yaml: "url: https://x.example.com\n"))
        XCTAssertEqual(ElectronUpdateManifest.version(inLatestYAML: Data("version: 4.2.0\nfiles:\n  - url: App-4.2.0.zip\n    sha512: abc\nreleaseDate: '2026-10-01'\n".utf8)), "4.2.0")

        FallbackStubProtocol.responses["https://downloads.example.com/mac/latest-mac.yml"] = .body("version: 4.2.0\n")
        let app = root.appending(path: "Tool.app")
        try makeBundle(app, ["CFBundleIdentifier": "com.example.tool", "CFBundleShortVersionString": "4.1.0"])
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
        try Data("provider: generic\nurl: https://downloads.example.com/mac\n".utf8).write(to: app.appending(path: "Contents/Resources/app-update.yml"))
        let detected = NativeApplicationProvider(roots: [NativeSearchRoot(url: root, classification: .user, required: true)], homeDirectory: "/nonexistent").discover().applications.first { $0.path.hasSuffix("Tool.app") }
        XCTAssertEqual(detected?.updateAuthority, .electron)
        XCTAssertEqual(try makeResolver().check(try XCTUnwrap(detected)), .available(version: "4.2.0", notes: nil))
    }

    func testCatalogNameAndVendorDomainTier() throws {
        let catalog = try HomebrewCaskCatalog(data: Data("""
            [
              {"token":"keyguard","version":"8.3","homepage":"https://tinyvendor.io/keyguard","url":"https://tinyvendor.io/releases/KeyGuard-8.3.zip","artifacts":[{"app":["KeyGuard.app"]}]},
              {"token":"hosted","version":"2.0","homepage":"https://github.com/someone/hosted","url":"https://github.com/someone/hosted/releases/download/2.0/Hosted.zip","artifacts":[{"app":["Hosted.app"]}]}
            ]
            """.utf8))
        XCTAssertEqual(catalog.entry(bundleFileName: "KeyGuard.app", referencedHosts: ["tinyvendor.io"])?.entry.version, "8.3")
        XCTAssertEqual(catalog.entry(bundleFileName: "KeyGuard.app", referencedHosts: ["updates.tinyvendor.io"])?.domain, "tinyvendor.io")
        XCTAssertNil(catalog.entry(bundleFileName: "KeyGuard.app", referencedHosts: ["example.com"]))
        // Shared hosting says nothing about the vendor.
        XCTAssertNil(catalog.entry(bundleFileName: "Hosted.app", referencedHosts: ["github.com"]))
        XCTAssertEqual(HomebrewCaskCatalog.vendorDomain("downloads.example.co.uk"), "example.co.uk")
        XCTAssertNil(HomebrewCaskCatalog.vendorDomain("objects.githubusercontent.com"))
    }

    // MARK: - Helpers

    private func makeResolver() throws -> NativeUpdateResolver {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FallbackStubProtocol.self]
        let database = try Database(url: root.appending(path: "metadata-\(UUID().uuidString).sqlite3"))
        return NativeUpdateResolver(metadataClient: MetadataHTTPClient(database: database, configuration: configuration, environment: ["GITHUB_TOKEN": "test-\(UUID().uuidString)"]), storefront: "us", systemVersion: "26.0")
    }

    private func sparkleApp(feed: String) -> NativeApplication {
        NativeApplication(path: "/Applications/App.app", bundleIdentifier: "com.example.app", displayName: "App", shortVersion: "1.0", buildVersion: "10", classification: .user, updateAuthority: .sparkle, sparkleFeedURL: feed)
    }

    private func makeBundle(_ url: URL, _ metadata: [String: String]) throws {
        let plist = url.appending(path: "Contents/Info.plist")
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0).write(to: plist)
    }
}

private struct UnreachableResolver: NativeUpdateResolving {
    func resolve(_ application: NativeApplication) -> NativeUpdateCheck {
        NativeUpdateCheck(path: application.path, authority: application.updateAuthority, installedVersionKey: Database.versionKey(short: application.shortVersion, build: application.buildVersion), outcome: .unchecked("test"))
    }
}

private struct FixedResolver: NativeUpdateResolving {
    let answers: [String: NativeUpdateOutcome]
    func resolve(_ application: NativeApplication) -> NativeUpdateCheck {
        NativeUpdateCheck(path: application.path, authority: answers[application.bundleIdentifier ?? ""] == nil ? .unknown : .blackmagic, installedVersionKey: Database.versionKey(short: application.shortVersion, build: application.buildVersion), outcome: answers[application.bundleIdentifier ?? ""] ?? .unchecked("No update source was detected for this application."))
    }
}

private final class FallbackStubProtocol: URLProtocol {
    enum Response { case body(String), redirect(String) }
    nonisolated(unsafe) static var responses: [String: Response] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        switch Self.responses[url.absoluteString] {
        case let .redirect(location)?:
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": location])!
            var next = URLRequest(url: URL(string: location)!)
            next.httpMethod = request.httpMethod
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        case let .body(text)?:
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case nil:
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
