import Darwin
import Foundation
import XCTest
@testable import SiftCore

final class NativeUpdateTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "sift-native-updates-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        StubURLProtocol.requested = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        StubURLProtocol.responses = [:]
    }

    // MARK: - Version ordering

    func testSparkleVersionOrdering() {
        let ascending: [(String, String)] = [
            ("1.0", "1.0.1"),
            ("1.0b1", "1.0"),
            ("1.0a", "1.0b"),
            ("9", "10"),
            ("2026010101", "2026030101"),
            ("3106797.2605011144", "3624198.2610060731"),
            ("6.100", "6.300"),
            ("1.9", "1.10"),
            ("1.0beta", "1.0-beta"),
            ("1.0+2", "1.0"),
        ]
        for (older, newer) in ascending {
            XCTAssertEqual(SparkleVersion.compare(older, newer), .orderedAscending, "\(older) < \(newer)")
            XCTAssertEqual(SparkleVersion.compare(newer, older), .orderedDescending, "\(newer) > \(older)")
        }
        // Answers read from Sparkle 2.8.1 itself.
        let same: [(String, String)] = [("1.0", "1.0"), ("01", "1"), ("1.0", "1.0.0"), ("1.0", "1.0-beta"), ("1.0-rc.1", "1.0"), ("1.0.0a", "1.0a"), ("1.0.", "1.0.0"), ("99999999999999999999", "100000000000000000000")]
        for (a, b) in same { XCTAssertEqual(SparkleVersion.compare(a, b), .orderedSame, "\(a) = \(b)") }
        XCTAssertEqual(SparkleVersion.compare("1_0", "1.0"), .orderedDescending)
        XCTAssertEqual(SparkleVersion.compare("١", ""), .orderedDescending, "any script's decimal digits are numbers")
        // Sparkle 1 (as some older apps bundle) doesn't pad, so the longer version is newer.
        XCTAssertEqual(SparkleVersion.compare("1.0.0", "1.0", padding: false), .orderedDescending)
        XCTAssertEqual(SparkleVersion.compare("1.0.0a", "1.0a", padding: false), .orderedDescending)
    }

    func testSparkleRulesFollowTheBundledFramework() throws {
        let v1 = root.appending(path: "One.app/Contents/Frameworks/Sparkle.framework/Versions/Current")
        try FileManager.default.createDirectory(at: v1.appending(path: "Resources/Autoupdate.app"), withIntermediateDirectories: true)
        let v2 = root.appending(path: "Two.app/Contents/Frameworks/Sparkle.framework/Versions/Current")
        try FileManager.default.createDirectory(at: v2.appending(path: "Updater.app"), withIntermediateDirectories: true)
        XCTAssertTrue(SparkleAppcastParser.bundlesSparkle1(root.appending(path: "One.app").path))
        XCTAssertFalse(SparkleAppcastParser.bundlesSparkle1(root.appending(path: "Two.app").path))
        XCTAssertFalse(SparkleAppcastParser.bundlesSparkle1(root.appending(path: "None.app").path))
    }

    func testCargoVersionsFollowSemVer() {
        let ascending: [(String, String)] = [
            ("1.0.0-alpha", "1.0.0-alpha.1"), ("1.0.0-alpha.1", "1.0.0-alpha.beta"), ("1.0.0-alpha.beta", "1.0.0-beta"),
            ("1.0.0-beta", "1.0.0-beta.2"), ("1.0.0-beta.2", "1.0.0-beta.11"), ("1.0.0-beta.11", "1.0.0-rc.1"), ("1.0.0-rc.1", "1.0.0"),
            ("0.4.17", "1.1.2"), ("1.9.0", "1.10.0"), ("1.1.1", "1.1.2"),
        ]
        for (older, newer) in ascending {
            XCTAssertEqual(SemanticVersion.compare(older, newer), .orderedAscending, "\(older) < \(newer)")
            XCTAssertEqual(SemanticVersion.compare(newer, older), .orderedDescending, "\(newer) > \(older)")
        }
        XCTAssertEqual(SemanticVersion.compare("1.0.0+build.5", "1.0.0"), .orderedSame)
        let index = Data([#"{"name":"x","vers":"1.0.0-beta.1","yanked":false}"#, #"{"name":"x","vers":"1.0.0+build-7","yanked":false}"#].joined(separator: "\n").utf8)
        XCTAssertEqual(CargoProvider.latestVersion(indexData: index, installed: "0.9.0"), "1.0.0", "a dash in build metadata isn't a prerelease")
        XCTAssertEqual(CargoProvider.latestVersion(indexData: index, installed: "1.0.0-alpha"), "1.0.0", "a prerelease install still sees the release")
    }

    // MARK: - Appcasts

    func testAppcastParsingUsesOnlyDirectItemFields() throws {
        // Shapes copied from real feeds: element versions, enclosure-attribute versions,
        // CDATA HTML notes and a beta channel, plus nested
        // informational-update and delta elements whose versions describe other builds.
        let feed = """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel>
                <item>
                  <title>Version 3.0 beta</title>
                  <sparkle:channel>beta</sparkle:channel>
                  <enclosure url="https://example.com/3.0.zip" sparkle:version="300" sparkle:shortVersionString="3.0"/>
                </item>
                <item>
                  <sparkle:version>200</sparkle:version>
                  <sparkle:shortVersionString>2.0</sparkle:shortVersionString>
                  <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
                  <sparkle:informationalUpdate><sparkle:version>999</sparkle:version></sparkle:informationalUpdate>
                  <sparkle:deltas><enclosure url="https://example.com/delta.zip" sparkle:version="998" sparkle:deltaFrom="150"/></sparkle:deltas>
                  <description><![CDATA[<h2>Version 2.0</h2><ul><li><p>Faster &amp; smaller</p></li><li><p>Fixes</p></li></ul>]]></description>
                  <enclosure url="https://example.com/2.0.zip" length="1"/>
                </item>
                <item>
                  <sparkle:releaseNotesLink>
                      https://example.com/notes.html
                  </sparkle:releaseNotesLink>
                  <enclosure url="https://example.com/1.5.zip" sparkle:version="150" sparkle:shortVersionString="1.5"/>
                </item>
                <item>
                  <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
                  <enclosure url="https://example.com/4.0.zip" sparkle:version="400" sparkle:shortVersionString="4.0"/>
                </item>
                <item><title>No version</title></item>
              </channel>
            </rss>
            """
        let items = try SparkleAppcastParser.parse(Data(feed.utf8))
        XCTAssertEqual(items.map(\.version), ["300", "200", "150", "400"])
        XCTAssertEqual(items[1].shortVersion, "2.0")
        XCTAssertEqual(items[2].releaseNotesURL, "https://example.com/notes.html")

        let best = try XCTUnwrap(SparkleAppcastParser.bestItem(items, systemVersion: "26.0.0"))
        XCTAssertEqual(best.version, "200")
        XCTAssertEqual(HTMLText.plainText(from: try XCTUnwrap(best.releaseNotesHTML)), "Version 2.0\n• Faster & smaller\n• Fixes")
        XCTAssertEqual(SparkleAppcastParser.bestItem(items, systemVersion: "14.0")?.version, "150")
    }

    func testAppcastParserRejectsMalformedXMLAndDoesNotExpandEntities() throws {
        XCTAssertThrowsError(try SparkleAppcastParser.parse(Data("<rss><channel><item>".utf8)))
        let external = """
            <?xml version="1.0"?>
            <!DOCTYPE rss [<!ENTITY secret SYSTEM "file:///etc/passwd">]>
            <rss><channel><item><sparkle:version>1</sparkle:version><description>&secret;</description></item></channel></rss>
            """
        let items = (try? SparkleAppcastParser.parse(Data(external.utf8))) ?? []
        XCTAssertFalse(items.contains { ($0.releaseNotesHTML ?? "").contains("root:") })
    }

    func testHTMLTextDropsScriptsAndDecodesEntities() {
        XCTAssertEqual(HTMLText.plainText(from: "<html><head><title>x</title><style>p{}</style></head><body><p>A&nbsp;&#8220;b&#x201D; &lt;c&gt;</p><script>alert(1)</script><p>Next<br>line</p></body></html>"), "A “b” <c>\nNext\nline")
    }

    // MARK: - App Store

    func testAppStoreListingPrefersMacBuildForExactBundleIdentifier() throws {
        let json = """
            {"resultCount":3,"results":[
              {"bundleId":"com.example.other","kind":"mac-software","version":"9.0"},
              {"bundleId":"com.example.app","kind":"software","version":"2.1","releaseNotes":"iOS notes"},
              {"bundleId":"com.example.app","kind":"mac-software","version":"2.0","releaseNotes":"Mac notes","trackViewUrl":"https://apps.apple.com/app/id1","minimumOsVersion":"14.0"}
            ]}
            """
        let listing = try XCTUnwrap(AppStoreListing.parse(Data(json.utf8), bundleIdentifier: "com.example.app"))
        XCTAssertEqual(listing, AppStoreListing(version: "2.0", releaseNotes: "Mac notes", storeURL: "https://apps.apple.com/app/id1", minimumSystemVersion: "14.0"))
        XCTAssertNil(try AppStoreListing.parse(Data(#"{"resultCount":0,"results":[]}"#.utf8), bundleIdentifier: "com.example.app"))
    }

    // MARK: - Resolver

    func testResolverReportsSparkleUpdateAgainstBundleBuildVersion() throws {
        StubURLProtocol.responses["https://updates.example.com/appcast.xml"] = (200, """
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
            <item><enclosure url="https://updates.example.com/a.zip" sparkle:version="2026030101" sparkle:shortVersionString="6.300"/>
            <sparkle:releaseNotesLink>https://updates.example.com/notes.html</sparkle:releaseNotesLink></item>
            </channel></rss>
            """)
        let resolver = try makeResolver()
        let outdated = application(short: "6.100", build: "2026010101", authority: .sparkle, feed: "https://updates.example.com/appcast.xml")
        XCTAssertEqual(resolver.check(outdated), .available(version: "6.300", notes: NativeReleaseNotes(content: nil, sourceURL: "https://updates.example.com/notes.html")))
        let current = application(short: "6.300", build: "2026030101", authority: .sparkle, feed: "https://updates.example.com/appcast.xml")
        XCTAssertEqual(resolver.check(current), .upToDate)
        // Ahead of the declared feed: the app replaced it at run time, so the feed proves nothing.
        let ahead = application(short: "7.0", build: "2026120101", authority: .sparkle, feed: "https://updates.example.com/appcast.xml")
        guard case .unchecked = resolver.check(ahead) else { return XCTFail("a feed behind the installed version isn't an answer") }
    }

    func testResolverRefusesNonPublicFeedsAndExplainsMissingFeed() throws {
        let resolver = try makeResolver()
        for feed in ["http://updates.example.com/appcast.xml", "https://localhost/appcast.xml", "https://192.168.1.1/appcast.xml", "https://printer.local/appcast.xml", "https://user:pw@example.com/a.xml", "file:///tmp/appcast.xml"] {
            guard case .unchecked = resolver.check(application(short: "1.0", build: "1", authority: .sparkle, feed: feed)) else { return XCTFail(feed) }
        }
        guard case let .unchecked(reason) = resolver.check(application(short: "1.0", build: "1", authority: .sparkle, feed: nil)) else { return XCTFail() }
        XCTAssertTrue(reason.contains("run time"))
        XCTAssertTrue(StubURLProtocol.requested.isEmpty)
    }

    func testResolverReportsTransientFeedFailure() throws {
        StubURLProtocol.responses["https://updates.example.com/appcast.xml"] = (503, "")
        let outcome = try makeResolver().check(application(short: "1.0", build: "1", authority: .sparkle, feed: "https://updates.example.com/appcast.xml"))
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
    }

    func testResolverComparesAppStoreVersionWithShortVersion() throws {
        StubURLProtocol.responses["https://itunes.apple.com/lookup?bundleId=com.example.app&country=us&entity=macSoftware"] = (200, #"{"resultCount":1,"results":[{"bundleId":"com.example.app","kind":"mac-software","version":"1.19.0","releaseNotes":"Fixes"}]}"#)
        let resolver = try makeResolver()
        XCTAssertEqual(resolver.check(application(short: "1.18.2", build: "42", authority: .appStore)), .available(version: "1.19.0", notes: NativeReleaseNotes(content: "Fixes", sourceURL: nil)))
        XCTAssertEqual(resolver.check(application(short: "1.19.0", build: "43", authority: .appStore)), .upToDate)
    }

    // MARK: - Persistence

    func testNativeUpdateIsShownOnlyWhileCheckedVersionIsInstalled() throws {
        let database = try Database(url: root.appending(path: "sift.sqlite3"))
        let old = NativeApplication(path: "/Applications/Aviary.app", bundleIdentifier: "com.example.aviary", displayName: "Aviary", shortVersion: "1.47.0", buildVersion: "9", classification: .user, discoveryRoot: "/Applications", updateAuthority: .sparkle, sparkleFeedURL: "https://example.com/a.xml")
        let first = Date(timeIntervalSince1970: 1_000)
        let check = NativeUpdateCheck(path: old.path, authority: .sparkle, installedVersionKey: Database.versionKey(short: "1.47.0", build: "9"), outcome: .available(version: "1.52.0", notes: NativeReleaseNotes(content: "New things", sourceURL: nil)))
        _ = try database.applyRefresh(input(at: first, applications: [old], checks: [check]))

        XCTAssertEqual(try database.updates(now: first).map { "\($0.provider) \($0.name) \($0.installedVersion) -> \($0.availableVersion)" }, ["sparkle Aviary 1.47.0 -> 1.52.0"])
        XCTAssertEqual(try database.dashboard(now: first).data.availableUpdateCount, 1)
        let item = try XCTUnwrap(database.nativeApplicationItems().first)
        XCTAssertEqual(item.availableVersion, "1.52.0")
        XCTAssertEqual(item.updateSource, "sparkle")
        XCTAssertEqual(try database.nativeReleaseNotes(path: old.path, targetVersion: "1.52.0")?.content, "New things")

        // A failed check keeps the previous answer.
        let second = Date(timeIntervalSince1970: 2_000)
        _ = try database.applyRefresh(input(at: second, applications: [old], checks: [NativeUpdateCheck(path: old.path, authority: .sparkle, installedVersionKey: check.installedVersionKey, outcome: .failed("timed out"))], nativeUpdatesStatus: .failure))
        XCTAssertEqual(try database.updates(now: second).map(\.availableVersion), ["1.52.0"])

        // Once the app updates itself, the old answer no longer applies even without a new check.
        let third = Date(timeIntervalSince1970: 3_000)
        let updated = NativeApplication(path: old.path, bundleIdentifier: old.bundleIdentifier, displayName: "Aviary", shortVersion: "1.52.0", buildVersion: "10", classification: .user, discoveryRoot: "/Applications", updateAuthority: .sparkle, sparkleFeedURL: old.sparkleFeedURL)
        _ = try database.applyRefresh(input(at: third, applications: [updated], checks: [NativeUpdateCheck(path: old.path, authority: .sparkle, installedVersionKey: check.installedVersionKey, outcome: .failed("timed out"))], nativeUpdatesStatus: .failure))
        XCTAssertEqual(try database.updates(now: third), [])
        XCTAssertEqual(try database.dashboard(now: third).data.availableUpdateCount, 0)
        XCTAssertNil(try database.nativeApplicationItems().first?.availableVersion)
    }

    func testRepeatedRefreshesKeepOneObservationAndCheckPerApplication() throws {
        let database = try Database(url: root.appending(path: "sift.sqlite3"))
        var app = NativeApplication(path: "/Applications/Aviary.app", bundleIdentifier: "com.example.aviary", displayName: "Aviary", shortVersion: "1.0", buildVersion: "1", classification: .user, discoveryRoot: "/Applications", updateAuthority: .sparkle)
        for index in 1...25 {
            if index == 10 { app = NativeApplication(path: app.path, bundleIdentifier: app.bundleIdentifier, displayName: "Aviary", shortVersion: "2.0", buildVersion: "2", classification: .user, discoveryRoot: "/Applications", updateAuthority: .sparkle) }
            let check = NativeUpdateCheck(path: app.path, authority: .sparkle, installedVersionKey: Database.versionKey(short: app.shortVersion, build: app.buildVersion), outcome: .available(version: "3.0", notes: nil))
            _ = try database.applyRefresh(input(at: Date(timeIntervalSince1970: TimeInterval(index * 1_000)), applications: [app], checks: [check]))
        }

        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM observations;"), 1)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM update_availability;"), 1)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(DISTINCT refresh_session_id) FROM provider_runs;"), 20)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM refresh_sessions;"), 20)
        // The version change survives as a transition, and the latest answer still applies.
        XCTAssertEqual(try database.nativeVersionTransitions().map { "\($0.fromVersion) -> \($0.toVersion)" }, ["1.0 (1) -> 2.0 (2)"])
        XCTAssertEqual(try database.updates(now: Date(timeIntervalSince1970: 25_000)).map(\.availableVersion), ["3.0"])
        XCTAssertEqual(try database.dashboard(now: Date(timeIntervalSince1970: 25_000)).latestRefreshStatus, .success)
    }

    func testUncheckedReasonIsRecordedForDisplay() throws {
        let database = try Database(url: root.appending(path: "sift.sqlite3"))
        let app = NativeApplication(path: "/Applications/Switcher.app", bundleIdentifier: "com.example.switcher", displayName: "Switcher", shortVersion: "11.10.1", buildVersion: "11.10.1", classification: .user, discoveryRoot: "/Applications", updateAuthority: .sparkle)
        let check = NativeUpdateCheck(path: app.path, authority: .sparkle, installedVersionKey: Database.versionKey(short: "11.10.1", build: "11.10.1"), outcome: .unchecked("No feed."))
        _ = try database.applyRefresh(input(at: Date(timeIntervalSince1970: 1_000), applications: [app], checks: [check]))

        let item = try XCTUnwrap(database.nativeApplicationItems().first)
        XCTAssertNil(item.availableVersion)
        XCTAssertEqual(item.updateDetail, "No feed.")
        XCTAssertTrue(CatalogRenderer.detail(item, notes: nil).contains("Updates: Sparkle · No feed."))
    }

    func testRefreshRejectsChecksForUninventoriedApplications() throws {
        let database = try Database(url: root.appending(path: "sift.sqlite3"))
        let check = NativeUpdateCheck(path: "/Applications/Ghost.app", authority: .sparkle, installedVersionKey: "", outcome: .upToDate)
        XCTAssertThrowsError(try database.applyRefresh(input(at: Date(timeIntervalSince1970: 1_000), applications: [], checks: [check])))
    }

    func testCatalogSelectorFallsBackToUniqueNamePrefix() {
        let items = ["Capture Pro", "Bastion Siege 6", "Python Launcher", "Python Launcher"].enumerated().map { index, name in
            CatalogItem(selector: "app:\(index)", aliases: [name], kind: .nativeApp, name: name, fullName: nil, installedVersion: nil, availableVersion: nil, active: true, bundleIdentifier: nil, path: nil, prefix: nil, tap: nil, ownership: nil, autoUpdates: false, observedAt: .now)
        }
        XCTAssertEqual(items.resolveCatalogItem("capture"), .item(items[0]))
        XCTAssertEqual(items.resolveCatalogItem("bastionsiege"), .item(items[1]))
        guard case .ambiguous = items.resolveCatalogItem("python") else { return XCTFail() }
        XCTAssertEqual(items.resolveCatalogItem("zzz"), .missing)
        XCTAssertEqual(items.resolveCatalogItem("  "), .missing)
    }

    // MARK: - Helpers

    private func makeResolver() throws -> NativeUpdateResolver {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let database = try Database(url: root.appending(path: "metadata-\(UUID().uuidString).sqlite3"))
        return NativeUpdateResolver(metadataClient: MetadataHTTPClient(database: database, configuration: configuration, environment: [:]), storefront: "us", systemVersion: "26.0.0")
    }

    private func application(short: String, build: String, authority: NativeUpdateAuthority, feed: String? = nil) -> NativeApplication {
        NativeApplication(path: "/Applications/Example.app", bundleIdentifier: "com.example.app", displayName: "Example", shortVersion: short, buildVersion: build, classification: .user, discoveryRoot: "/Applications", updateAuthority: authority, sparkleFeedURL: feed)
    }

    private func input(at date: Date, applications: [NativeApplication], checks: [NativeUpdateCheck], nativeUpdatesStatus: ProviderRefreshStatus = .success) -> RefreshPersistenceInput {
        let results = RefreshProvider.allCases.map { provider in
            let status = provider == .nativeUpdates ? nativeUpdatesStatus : .success
            return ProviderRefreshResult(provider: provider, status: status, startedAt: date, finishedAt: date, dataAsOf: status == .success ? date : nil)
        }
        return RefreshPersistenceInput(startedAt: date, finishedAt: date, nativeInventory: NativeInventoryResult(applications: applications, scannedRoots: ["/Applications"]), homebrewInventory: HomebrewInventory(prefixes: []), targetResults: [:], releaseNoteResults: [:], nativeUpdateChecks: checks, providerResults: results)
    }
}

private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var requested: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requested.append(url.absoluteString)
        let (status, body) = Self.responses[url.absoluteString] ?? (404, "")
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
