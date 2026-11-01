import Darwin
import Foundation
import Synchronization
import XCTest
@testable import SiftCore

final class MetadataAndReleaseNotesTests: XCTestCase {
    func testFreshMetadataCacheAvoidsNetworkAndPreservesPayload() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let requestURL = "https://itunes.apple.com/lookup?bundleId=example"
        try database.storeMetadataResponse(
            url: requestURL, resourceKind: "app-store-lookup-v1", statusCode: 200, body: Data("cached".utf8), etag: "etag", lastModified: nil,
            validatedAt: timestamp)
        let client = MetadataHTTPClient(database: database, now: { timestamp.addingTimeInterval(60) })

        XCTAssertEqual(try String(decoding: client.fetch(URL(string: requestURL)!, resource: .appStoreLookup).body, as: UTF8.self), "cached")
    }

    func testMetadataCachePreservesEmptyBlob() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let requestURL = "https://itunes.apple.com/lookup?bundleId=empty"
        try database.storeMetadataResponse(
            url: requestURL, resourceKind: "app-store-lookup-v1", statusCode: 200, body: Data(), etag: nil, lastModified: nil,
            validatedAt: Date(timeIntervalSince1970: 1_000))

        let cached = try database.cachedMetadataResponse(url: requestURL, resourceKind: "app-store-lookup-v1")
        XCTAssertEqual(cached?.body, Data())
    }

    func testCachedMetadataNotFoundRemainsExplicitAbsence() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let requestURL = "https://itunes.apple.com/lookup?bundleId=missing"
        try database.storeMetadataResponse(
            url: requestURL, resourceKind: "app-store-lookup-v1", statusCode: 404, body: nil, etag: nil, lastModified: nil, validatedAt: timestamp)
        let client = MetadataHTTPClient(database: database, now: { timestamp.addingTimeInterval(60) })

        XCTAssertThrowsError(try client.fetch(URL(string: requestURL)!, resource: .appStoreLookup)) { error in
            XCTAssertEqual((error as? MetadataHTTPError)?.errorDescription, MetadataHTTPError.notFound.errorDescription)
        }
    }

    func testNotFoundCacheRevalidatesWith304() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let validatedAt = Date(timeIntervalSince1970: 1_000)
        let revalidatedAt = validatedAt.addingTimeInterval(7 * 60 * 60)
        let requestURL = "https://itunes.apple.com/lookup?bundleId=missing"
        try database.storeMetadataResponse(
            url: requestURL, resourceKind: "app-store-lookup-v1", statusCode: 404, body: nil, etag: "missing-etag", lastModified: nil, validatedAt: validatedAt)

        MetadataURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "missing-etag")
            return (304, nil, [:])
        }
        defer { MetadataURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataURLProtocol.self]
        let client = MetadataHTTPClient(database: database, configuration: configuration, now: { revalidatedAt })

        XCTAssertThrowsError(try client.fetch(URL(string: requestURL)!, resource: .appStoreLookup)) { error in
            XCTAssertEqual((error as? MetadataHTTPError)?.errorDescription, MetadataHTTPError.notFound.errorDescription)
        }
        XCTAssertEqual(try database.cachedMetadataResponse(url: requestURL, resourceKind: "app-store-lookup-v1")?.validatedAt, revalidatedAt)
    }

    func testDerivedValueIsRebuiltOnlyWhenTheResponseChanges() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let requestURL = URL(string: "https://itunes.apple.com/lookup?bundleId=derived")!
        let server = Mutex((etag: "a", body: "[1]", requests: 0))
        MetadataURLProtocol.handler = { request in
            server.withLock { state in
                state.requests += 1
                if request.value(forHTTPHeaderField: "If-None-Match") == state.etag { return (304, nil, ["ETag": state.etag]) }
                return (200, Data(state.body.utf8), ["ETag": state.etag])
            }
        }
        defer { MetadataURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataURLProtocol.self]
        let clock = Mutex(Date(timeIntervalSince1970: 1_000))
        let client = MetadataHTTPClient(database: database, configuration: configuration, now: { clock.withLock { $0 } })
        let derivations = Mutex(0)
        func fetch() throws -> [Int] {
            try client.fetch(requestURL, resource: .appStoreLookup, derivedAs: "test-v1") { data in
                derivations.withLock { $0 += 1 }
                return try JSONDecoder().decode([Int].self, from: data)
            }
        }

        XCTAssertEqual(try fetch(), [1])
        XCTAssertEqual(try fetch(), [1])
        XCTAssertEqual(derivations.withLock { $0 }, 1, "a cached response reuses its derived value")

        clock.withLock { $0 = $0.addingTimeInterval(7 * 60 * 60) }
        XCTAssertEqual(try fetch(), [1])
        XCTAssertEqual(derivations.withLock { $0 }, 1, "a 304 revalidation keeps it too")

        clock.withLock { $0 = $0.addingTimeInterval(7 * 60 * 60) }
        server.withLock {
            $0.etag = "b"; $0.body = "[2]"
        }
        XCTAssertEqual(try fetch(), [2])
        XCTAssertEqual(derivations.withLock { $0 }, 2, "a changed response is derived again")
        XCTAssertEqual(server.withLock { $0.requests }, 3)
    }

    func testMetadataClientStopsOversizedResponseWhileStreaming() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let requestURL = "https://itunes.apple.com/lookup?bundleId=large"
        MetadataURLProtocol.handler = { _ in (200, Data(repeating: 0, count: 1_048_577), [:]) }
        defer { MetadataURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataURLProtocol.self]
        let client = MetadataHTTPClient(database: database, configuration: configuration)

        XCTAssertThrowsError(try client.fetch(URL(string: requestURL)!, resource: .appStoreLookup)) { error in
            XCTAssertEqual((error as? MetadataHTTPError)?.errorDescription, MetadataHTTPError.responseTooLarge.errorDescription)
        }
        XCTAssertNil(try database.cachedMetadataResponse(url: requestURL, resourceKind: "app-store-lookup-v1"))
    }

    func testGitHubMetadataPolicyUsesPreferredTokenAndRequiredHeaders() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        MetadataURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer preferred-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), SiftVersion.userAgent)
            return (200, Data("{}".utf8), [:])
        }
        defer { MetadataURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataURLProtocol.self]
        let client = MetadataHTTPClient(
            database: database, configuration: configuration, environment: ["GITHUB_TOKEN": " preferred-token ", "GH_TOKEN": "fallback-token"])

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
            return (
                429, nil, ["Retry-After": formatter.string(from: retryAt), "X-RateLimit-Reset": String(Int(now.addingTimeInterval(60).timeIntervalSince1970))]
            )
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
        let package = HomebrewPackage(
            prefix: "/opt/homebrew", kind: .formula, name: "example", fullName: "example", tap: "homebrew/core", ownership: .explicitlyRequested,
            installedVersion: "1.2.2", sourceURL: nil, artifactPaths: [], autoUpdates: false)
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

    func testReleaseNotesFallBackToRepositoryCommitComparison() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let targetCommit = String(repeating: "b", count: 40)
        let installedCommit = String(repeating: "c", count: 40)
        MetadataURLProtocol.handler = { request in
            switch request.url?.path {
            case "/repos/owner/repository/git/ref/tags/2.0":
                return (404, nil, [:])
            case "/repos/owner/repository/git/ref/tags/v2.0":
                return (200, Data("{\"object\":{\"type\":\"commit\",\"sha\":\"\(targetCommit)\"}}".utf8), [:])
            case "/repos/owner/repository/releases/tags/v2.0":
                return (404, nil, [:])
            case "/owner/repository/\(targetCommit)/CHANGELOG.md":
                return (404, nil, [:])
            case "/repos/owner/repository/git/ref/tags/1.0":
                return (404, nil, [:])
            case "/repos/owner/repository/git/ref/tags/v1.0":
                return (200, Data("{\"object\":{\"type\":\"commit\",\"sha\":\"\(installedCommit)\"}}".utf8), [:])
            case "/repos/owner/repository/compare/\(installedCommit)...\(targetCommit)":
                return (
                    200,
                    Data(
                        "{\"commits\":[{\"sha\":\"\(targetCommit)\",\"commit\":{\"message\":\"Fix a bug\\n\\nDetails here.\"}},{\"sha\":\"\(installedCommit)\",\"commit\":{\"message\":\"Fix a bug\"}}]}"
                            .utf8), [:]
                )
            default:
                return (404, nil, [:])
            }
        }
        defer { MetadataURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataURLProtocol.self]
        let resolver = ReleaseNotesResolver(metadataClient: MetadataHTTPClient(database: database, configuration: configuration))
        let package = homebrewPackage(kind: .formula, name: "example")
        let target = HomebrewTarget(version: "2.0", sourceURL: "https://github.com/owner/repository", upstreamVersion: "2.0")

        guard case let .resolved(notes) = resolver.resolveReleaseNotes(for: package, target: target) else {
            return XCTFail("Expected a repository-commit-comparison fallback.")
        }
        XCTAssertEqual(notes.coverage, "repositoryCommits")
        XCTAssertEqual(notes.content, "## Repository changes (2 commits)\n- Fix a bug × 2")
        XCTAssertEqual(notes.sourceURL, "https://github.com/owner/repository/compare/\(installedCommit)...\(targetCommit)")
    }
}
