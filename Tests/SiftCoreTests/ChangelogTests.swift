import Foundation
import XCTest
@testable import SiftCore

final class ChangelogTests: XCTestCase {
    private var url: URL!

    override func setUp() { url = temporaryDatabaseURL() }
    override func tearDown() {
        MetadataURLProtocol.handler = nil
        removeDatabase(at: url)
    }

    // MARK: Parsing

    func testMarkdownChangelogSplitsAtVersionHeadingsAndKeepsSubsections() {
        let document = """
            # Changelog
            All notable changes.

            ## [Unreleased]
            - Work in progress

            ## [1.2.0](https://example.com/compare) - 2026-10-21
            ### Added
            - Snapshots
            ### Fixed
            - A crash

            ## v1.1.0 Christmas release
            - Presents

            ## 1.0.0
            - First
            """
        let entries = ChangelogDocument.entries(fromMarkdown: document, sourceURL: nil)
        XCTAssertEqual(entries.map(\.version), ["1.2.0", "1.1.0", "1.0.0"])
        XCTAssertEqual(entries[0].content, "### Added\n- Snapshots\n### Fixed\n- A crash")
        XCTAssertEqual(entries[0].date, ChangelogDocument.utcDate(year: 2026, month: 10, day: 21))
        XCTAssertEqual(entries[1].title, "Christmas release")
    }

    func testSetextHeadingsFromReStructuredTextAreVersionHeadings() {
        let entries = ChangelogDocument.entries(fromMarkdown: "Changelog\n=========\n\n0.39.1 [2026-10-02]\n-------------------\n- Fix\n\n0.39.0 [2026-09-01]\n-------------------\n- New\n", sourceURL: nil)
        XCTAssertEqual(entries.map(\.version), ["0.39.1", "0.39.0"])
        XCTAssertEqual(entries.first?.content, "- Fix")
    }

    func testWebPageChangelogIsConvertedAndSplit() {
        let html = """
            <html><head><title>x</title><script>var a = "<h2>9.9</h2>";</script></head><body>
            <header><ul><li><a href=/apps/>Apps</a></li></ul></header>
            <main><h1>iStat Menus version history</h1><h3>7.5</h3><p>14 September 2026<ul><li class=added>Super cores.</li></ul></p>
            <h3>7.3</h3><p>14 May 2026<ul><li>Cloud cover &amp; more.</li></ul></p></main><footer>© Bjango</footer></body></html>
            """
        let entries = ChangelogResolver.pageEntries(html, url: URL(string: "https://bjango.com/mac/istatmenus/versionhistory/")!)
        XCTAssertEqual(entries.map(\.version), ["7.5", "7.3"])
        XCTAssertEqual(entries[1].content, "- Cloud cover & more.")
        XCTAssertEqual(entries[1].date, ChangelogDocument.utcDate(year: 2026, month: 5, day: 14))
    }

    func testCodeBlocksOnAPageDontSwallowTheHeadingsAfterThem() {
        let html = "<h2>go1.27.0 (released 2026-08-19)</h2><p>Major release.</p><pre>go install x</pre><h2>go1.26.0 (released 2026-02-10)</h2><p>Older.</p>"
        let entries = ChangelogResolver.pageEntries(html, url: URL(string: "https://go.dev/doc/devel/release")!)
        XCTAssertEqual(entries.map(\.version), ["1.27.0", "1.26.0"])
        XCTAssertEqual(entries[0].date, ChangelogDocument.utcDate(year: 2026, month: 8, day: 19))
    }

    func testChangelogLinksPreferTheSameSiteAndReadUnquotedAttributes() {
        let html = #"<a href=/mac/istatmenus/versionhistory/>Version history</a> <a href="https://news.example.org/news/review">Review</a> <a href='/buy/'>Buy</a>"#
        XCTAssertEqual(ChangelogResolver.changelogLinks(in: html, base: URL(string: "https://bjango.com/mac/istatmenus/")!).map(\.absoluteString), ["https://bjango.com/mac/istatmenus/versionhistory/"])
    }

    func testPlaceholdersDontCountAsChangelogs() {
        XCTAssertTrue(ChangelogDocument.isPlaceholder("Please visit the Help Centre for the latest [release notes](https://affin.co/ReleaseNotesAffinity)."))
        XCTAssertTrue(ChangelogDocument.isPlaceholder("See https://example.com/changelog"))
        XCTAssertTrue(ChangelogDocument.isPlaceholder(""))
        XCTAssertFalse(ChangelogDocument.isPlaceholder("- Fixed a crash when opening large files.\n- Added dark mode."))
        XCTAssertFalse(ChangelogDocument.isPlaceholder("Bug fixes and performance improvements."))
    }

    func testPlainTextNewsFilesAreSplitAtTheirReleaseLines() {
        let gnu = "GNU coreutils NEWS\n\n* Noteworthy changes in release ?.? (????-??-??) [?]\n\n* Noteworthy changes in release 9.5 (2024-03-28) [stable]\n\n** Bug fixes\n\n  chmod -R now avoids a race.\n\n* Noteworthy changes in release 9.4 (2023-08-29) [stable]\n\n  Fixes.\n"
        let entries = ChangelogDocument.entries(fromMarkdown: gnu, sourceURL: nil)
        XCTAssertEqual(entries.map(\.version), ["9.5", "9.4"])
        XCTAssertEqual(entries[0].content, "### Bug fixes\n\nchmod -R now avoids a race.")
        XCTAssertEqual(ChangelogDocument.entries(fromMarkdown: "version <next>:\n- wip\n\nversion 7.1:\n- VVC decoder\n\nversion 7.0:\n- Old\n", sourceURL: nil).map(\.version), ["7.1", "7.0"])
        XCTAssertEqual(ChangelogDocument.entries(fromMarkdown: "CHANGES FROM 3.5a TO 3.6\n\n* New\n\nCHANGES FROM 3.5 TO 3.5a\n\n* Fix\n", sourceURL: nil).map(\.version), ["3.6", "3.5a"])
        XCTAssertEqual(ChangelogVersion.token(in: "go1.25.0 (released 2025-08-12)"), "1.25.0")
        XCTAssertTrue(ChangelogVersion.looselyMatches("7.3", "7.30"))
        XCTAssertFalse(ChangelogVersion.matches("7.3", "7.30"))
    }

    func testBBCodeBecomesMarkdown() {
        let bbcode = "[h2]Balance[/h2][list][*][p]Sniper damage up[/p][/*][*]Ninja [b]faster[/b][/list][img]{STEAM_CLAN_IMAGE}/x.png[/img][url=https://x]Read[/url]"
        XCTAssertEqual(ChangelogDocument.markdown(fromBBCode: bbcode), "## Balance\n\n- Sniper damage up\n\n- Ninja **faster**\nRead")
    }

    // MARK: Versions

    func testInstalledVersionsAreMatchedLikeTheirPackageManagersWriteThem() {
        XCTAssertEqual(ChangelogVersion.normalized("9.12_1"), "9.12")
        XCTAssertEqual(ChangelogVersion.normalized("158.0.1,2"), "158.0.1")
        XCTAssertEqual(ChangelogVersion.normalized("57.4 (12224)"), "57.4")
        XCTAssertEqual(ChangelogVersion.token(in: "Release v2.103.2 (2026-10-21)"), "2.103.2")
        XCTAssertEqual(ChangelogVersion.token(in: "Version 8"), "8")
        XCTAssertNil(ChangelogVersion.token(in: "2026-10-21"))
        XCTAssertTrue(ChangelogVersion.matches("v1.0", "1.0.0"))
    }

    func testNewEntriesAreThoseAboveTheInstalledVersion() {
        let entries = ["2.103.2", "2.103.1", "2.103.0", "2.102.0", "2.101.0"].map { ChangelogEntry(version: $0, content: "- change") }
        let changelog = Changelog(selector: "formula:gh", name: "gh", installedVersion: "2.102.0", availableVersion: "2.103.2", source: "GitHub releases (cli/cli)", sourceURL: nil, entries: entries, fetchedAt: .now)
        XCTAssertEqual(changelog.newEntries.map(\.version), ["2.103.2", "2.103.1", "2.103.0"])
        XCTAssertEqual(changelog.installedEntry?.version, "2.102.0")
        // A rebuild has no entry of its own; newer entries still compare newer.
        let rebuilt = Changelog(selector: "formula:gh", name: "gh", installedVersion: "2.102.5_1", availableVersion: nil, source: "", sourceURL: nil, entries: entries, fetchedAt: .now)
        XCTAssertEqual(rebuilt.newEntries.map(\.version), ["2.103.2", "2.103.1", "2.103.0"])
        let rendered = ChangelogRenderer.humanReadable(changelog)
        XCTAssertTrue(rendered.hasPrefix("gh  2.102.0 -> 2.103.2  ·  3 new versions"))
        XCTAssertTrue(rendered.contains("2.102.0  installed"))
        XCTAssertTrue(rendered.contains("1 older version · sift changelog formula:gh --all"))
        XCTAssertFalse(rendered.contains("2.101.0"))
    }

    // MARK: Resolving

    func testGitHubReleasesAreTheChangelogAndPagesFollowUntilShort() throws {
        let database = try Database(url: url)
        var requested: [String] = []
        MetadataURLProtocol.handler = { request in
            let url = request.url!.absoluteString
            requested.append(url)
            if url.hasPrefix("https://api.github.com/repos/cli/cli/releases") {
                let releases: [[String: Any]] = [
                    ["tag_name": "v2.103.2", "name": "GitHub CLI 2.103.2", "body": "## What's Changed\n- Fix attach\n\n**Full Changelog**: https://github.com/cli/cli/compare/v2.103.1...v2.103.2", "published_at": "2026-10-23T10:00:00Z", "html_url": "https://github.com/cli/cli/releases/tag/v2.103.2"],
                    ["tag_name": "v2.104.0-rc1", "prerelease": true, "body": "- Preview"],
                    ["tag_name": "v2.103.1", "name": "Christmas", "body": "- Hints", "published_at": "2026-10-20T10:00:00Z"],
                ]
                return (200, try! JSONSerialization.data(withJSONObject: releases), [:])
            }
            return (404, nil, [:])
        }
        let resolver = ChangelogResolver(client: mockedClient(database), environment: [:])
        let item = homebrewItem("gh", installed: "2.103.1")
        guard case let .resolved(source, sourceURL, entries) = resolver.resolve(ChangelogSubject(item: item, homebrewSourceURL: "https://github.com/cli/cli/archive/refs/tags/v2.103.1.tar.gz")) else { return XCTFail("expected a changelog") }
        XCTAssertEqual(source, "GitHub releases (cli/cli)")
        XCTAssertEqual(sourceURL, "https://github.com/cli/cli/releases")
        XCTAssertEqual(entries.map(\.version), ["2.103.2", "2.103.1"])
        XCTAssertEqual(entries[0].content, "## What's Changed\n- Fix attach")
        XCTAssertNil(entries[0].title)
        XCTAssertEqual(entries[1].title, "Christmas")
        XCTAssertEqual(requested.filter { $0.contains("api.github.com") }.count, 1, "a short page is the last one")
    }

    func testAPlaceholderFeedFollowsTheLinkInsideItsDescription() throws {
        let database = try Database(url: url)
        MetadataURLProtocol.handler = { request in
            switch request.url!.absoluteString {
            case "https://updates.example.com/appcast.xml":
                let feed = """
                    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
                    <item><pubDate>Tue, 20 Oct 2026 10:00:00 +0000</pubDate><description><![CDATA[Please visit the Help Centre for the latest <a href="https://help.example.com/notes">release notes</a>.]]></description><enclosure sparkle:version="40" sparkle:shortVersionString="3.3.1" url="https://x/a.zip"/></item>
                    </channel></rss>
                    """
                return (200, Data(feed.utf8), [:])
            case "https://help.example.com/notes":
                return (200, Data("<html><body><h2>3.3.1</h2><ul><li>Faster export</li></ul><h2>3.3.0</h2><ul><li>Layers</li></ul></body></html>".utf8), [:])
            default:
                return (404, nil, [:])
            }
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "sift-changelog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Example.app")
        try makeApplication(at: app, metadata: ["CFBundleIdentifier": "com.example.app", "CFBundleName": "Example", "CFBundleShortVersionString": "3.3.0", "CFBundleVersion": "39", "SUFeedURL": "https://updates.example.com/appcast.xml"])
        let item = CatalogItem(selector: "app:com.example.app", aliases: ["Example"], kind: .nativeApp, name: "Example", fullName: nil, installedVersion: "3.3.0", availableVersion: "3.3.1", active: true, bundleIdentifier: "com.example.app", path: app.path, prefix: nil, tap: nil, ownership: nil, autoUpdates: false, observedAt: .now, updateSource: "sparkle")
        let resolution = ChangelogResolver(client: mockedClient(database), homeDirectory: root.path, environment: [:]).resolve(ChangelogSubject(item: item))
        guard case let .resolved(source, _, entries) = resolution else { return XCTFail("expected a changelog, got \(resolution)") }
        XCTAssertEqual(source, "the app's update feed")
        XCTAssertEqual(entries.map(\.version), ["3.3.1"])
        XCTAssertEqual(entries.first?.content, "- Faster export")
        XCTAssertEqual(entries.first?.sourceURL, "https://help.example.com/notes")
    }

    func testServiceCachesAndFallsBackToTheLastGoodCopy() throws {
        let database = try Database(url: url)
        let package = HomebrewPackage(prefix: "/nonexistent-prefix", kind: .formula, name: "gh", fullName: "gh", tap: "homebrew/core", ownership: .explicitlyRequested, installedVersion: "2.0.0", sourceURL: "https://github.com/cli/cli/archive/refs/tags/v2.0.0.tar.gz", artifactPaths: [], autoUpdates: false)
        _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 1_000), homebrewInventory: HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: package.prefix, packages: [package], complete: true, warnings: [])]), targetResults: [HomebrewPackageKey(package): .unsupported("none")]))
        var fail = false
        var githubRequests = 0
        MetadataURLProtocol.handler = { request in
            let url = request.url!.absoluteString
            if url.contains("github") { githubRequests += 1 }
            if fail { return (503, nil, [:]) }
            guard url.hasPrefix("https://api.github.com/repos/cli/cli/releases") else { return (404, nil, [:]) }
            return (200, try! JSONSerialization.data(withJSONObject: [["tag_name": "v2.0.0", "body": "- Big"]]), [:])
        }
        let clock = Date(timeIntervalSince1970: 1_000_000)
        var current = clock
        let service = ChangelogService(database: database, resolver: ChangelogResolver(client: MetadataHTTPClient(database: database, configuration: mockedConfiguration(), environment: [:], now: { current }), environment: [:]))
        let item = try XCTUnwrap(database.catalogItems().first { $0.name == "gh" })

        guard case let .changelog(fetched) = try service.changelog(for: item, now: clock) else { return XCTFail("expected a changelog") }
        XCTAssertEqual(fetched.entries.map(\.version), ["2.0.0"])
        let afterFirst = githubRequests

        guard case .changelog = try service.changelog(for: item, now: clock.addingTimeInterval(60)) else { return XCTFail() }
        XCTAssertEqual(githubRequests, afterFirst, "a fresh copy is reused")

        fail = true
        current = clock.addingTimeInterval(7 * 60 * 60)
        guard case let .changelog(stale) = try service.changelog(for: item, refetch: true, now: clock.addingTimeInterval(7 * 60 * 60)) else { return XCTFail("the last good copy should be shown") }
        XCTAssertEqual(stale.entries.map(\.version), ["2.0.0"])
        XCTAssertNotNil(stale.staleReason)
        XCTAssertEqual(try ChangelogService.cached(for: item, database: database)?.source, "GitHub releases (cli/cli)")
    }

    func testHistoryAccumulatesAcrossFetchesAndKeepsRealTextOverPlaceholders() throws {
        let database = try Database(url: url)
        let selector = "app:com.example"
        try database.storeChangelog(selector: selector, source: "feed", sourceURL: nil, entries: [ChangelogEntry(version: "2.0", content: "- Two"), ChangelogEntry(version: "1.0", content: "- One")], fetchedAt: Date(timeIntervalSince1970: 1_000))
        // A one-item feed later: older versions stay, and a placeholder doesn't replace real text.
        try database.storeChangelog(selector: selector, source: "feed", sourceURL: nil, entries: [ChangelogEntry(version: "3.0", content: "- Three"), ChangelogEntry(version: "2.0", content: "See our website for release notes.")], fetchedAt: Date(timeIntervalSince1970: 2_000))
        let entries = try database.changelogEntries(selector: selector)
        XCTAssertEqual(entries.map(\.version), ["3.0", "2.0", "1.0"])
        XCTAssertEqual(entries[1].content, "- Two")
    }

    func testFeedsAreReadAsChangelogs() {
        let atom = """
            <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
            <entry><title>v1.4.0</title><updated>2026-10-20T00:00:00Z</updated><link rel="alternate" href="https://github.com/o/r/releases/tag/v1.4.0"/><content type="html">&lt;ul&gt;&lt;li&gt;Faster&lt;/li&gt;&lt;/ul&gt;</content></entry>
            <entry><title>Release 1.3.0: Spooky</title><updated>2026-10-01T00:00:00Z</updated><content type="html">&lt;p&gt;Ghosts&lt;/p&gt;</content></entry>
            </feed>
            """
        let entries = ChangelogFeeds.entries(fromFeed: Data(atom.utf8))
        XCTAssertEqual(entries.map(\.version), ["1.4.0", "1.3.0"])
        XCTAssertEqual(entries[0].content, "- Faster")
        XCTAssertEqual(entries[0].sourceURL, "https://github.com/o/r/releases/tag/v1.4.0")
        let page = #"<head><link rel="alternate" type="application/rss+xml" href="/changelog/rss.xml"></head>"#
        XCTAssertEqual(ChangelogFeeds.advertisedFeeds(in: page, base: URL(string: "https://example.com/")!).map(\.absoluteString), ["https://example.com/changelog/rss.xml"])
    }

    func testReleasesEmbeddedForScriptsAreRead() {
        let html = """
            <div id="__next"></div><script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"releases":[
            {"version":"5.2.0","date":"2026-10-02","changes":["New editor","Bug fixes"]},
            {"version":"5.1.0","date":"2026-09-01","body":"<ul><li>Sync</li></ul>"},
            {"name":"Pricing","description":"Plans start at $5"}]}}}</script>
            """
        let entries = ChangelogFeeds.embeddedEntries(in: html)
        XCTAssertEqual(entries.map(\.version), ["5.2.0", "5.1.0"])
        XCTAssertEqual(entries[0].content, "- New editor\n- Bug fixes")
        XCTAssertEqual(entries[1].content, "- Sync")
        XCTAssertTrue(ChangelogFeeds.looksScriptBuilt(html))
        XCTAssertFalse(ChangelogFeeds.looksScriptBuilt("<html><body>" + String(repeating: "<p>Real changelog text here.</p>", count: 100) + "</body></html>"))
    }

    func testAScriptBuiltPageIsRenderedWhenItsHTMLHasNoVersions() throws {
        let database = try Database(url: url)
        MetadataURLProtocol.handler = { request in
            request.url!.path == "/changelog" ? (200, Data("<html><body><div id=\"root\"></div><script src=a.js></script><script src=b.js></script><script src=c.js></script></body></html>".utf8), [:]) : (404, nil, [:])
        }
        let rendered = "<html><body><h2>2.1.0</h2><ul><li>Rendered by script</li></ul><h2>2.0.0</h2><ul><li>Older</li></ul></body></html>"
        let resolver = ChangelogResolver(client: mockedClient(database), environment: [:], renderer: { _ in rendered })
        XCTAssertEqual(try resolver.page(URL(string: "https://app.example.com/changelog")!).map(\.version), ["2.1.0", "2.0.0"])
    }

    // MARK: Helpers

    private func mockedConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataURLProtocol.self]
        return configuration
    }

    private func mockedClient(_ database: Database) -> MetadataHTTPClient {
        MetadataHTTPClient(database: database, configuration: mockedConfiguration(), environment: [:])
    }

    private func homebrewItem(_ name: String, installed: String) -> CatalogItem {
        CatalogItem(selector: "formula:\(name)", aliases: [name], kind: .homebrewFormula, name: name, fullName: name, installedVersion: installed, availableVersion: nil, active: true, bundleIdentifier: nil, path: nil, prefix: "/nonexistent-prefix", tap: "homebrew/core", ownership: "explicitlyRequested", autoUpdates: false, observedAt: .now, updateSource: "homebrew")
    }
}
