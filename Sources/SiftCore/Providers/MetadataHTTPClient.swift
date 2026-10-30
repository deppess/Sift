import CryptoKit
import Foundation

public enum MetadataResource: Equatable, Sendable {
    case githubReference
    case githubAnnotatedTag
    case githubReleaseByTag
    case githubReleaseList
    case githubTree
    case githubBlob
    case githubChangelog
    case appStoreLookup
    case homebrewCaskCatalog
    case blackmagicDownloads
    case cratesIndex
    case githubLatestRelease
    /// An electron-builder `latest-mac.yml`; only the host the app's manifest names is allowed.
    case electronUpdateFeed(host: String)
    /// A Sparkle appcast; only the host the application's own bundle declares is allowed.
    case sparkleAppcast(host: String)
    /// A changelog or release-notes web page on the host its package or app names.
    case changelogPage(host: String)
    /// Package metadata naming a project's repository and homepage: npm, PyPI, crates.io, Homebrew.
    case packageRegistry
    /// A Steam game's announcements and patch notes.
    case steamNews
    /// An App Store listing page, for its version history.
    case appStorePage
}

public struct MetadataHTTPResponse: Sendable {
    public let body: Data
}

public struct CachedMetadataResponse: Sendable {
    public let statusCode: Int
    public let body: Data?
    public let etag: String?
    public let lastModified: String?
    public let validatedAt: Date
}

public enum MetadataHTTPError: LocalizedError {
    case unsupportedURL
    case notFound
    case authenticationFailed
    case forbidden
    case rateLimited(retryAt: Date?)
    case serverFailure(statusCode: Int)
    case invalidResponse
    case timedOut
    case responseTooLarge
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedURL: "Metadata URL is not an allowed HTTPS endpoint."
        case .notFound: "Metadata was not found."
        case .authenticationFailed: "Metadata authentication failed."
        case .forbidden: "Metadata access was forbidden."
        case let .rateLimited(retryAt): retryAt.map { "Metadata request was rate limited until \($0.ISO8601Format())." } ?? "Metadata request was rate limited."
        case let .serverFailure(statusCode): "Metadata server returned HTTP \(statusCode)."
        case .invalidResponse: "Metadata server returned an invalid response."
        case .timedOut: "Metadata request timed out."
        case .responseTooLarge: "Metadata response exceeded the configured size limit."
        case let .transport(message): message
        }
    }
}

public final class MetadataHTTPClient: @unchecked Sendable {
    private static let concurrency = DispatchSemaphore(value: 6)
    // Anonymous GitHub API access has a low hourly quota (60 requests) and is the more likely target
    // of abuse-detection throttling on bursty concurrent traffic, so it stays fully serial. A
    // request carrying a token (GITHUB_TOKEN/GH_TOKEN) has a much higher quota (5,000/hour) and is
    // not subject to that same anonymous-abuse heuristic, so it can safely overlap in flight.
    private static let githubConcurrencyAnonymous = DispatchSemaphore(value: 1)
    private static let githubConcurrencyAuthenticated = DispatchSemaphore(value: 4)
    private static let rateLimitLock = NSLock()
    nonisolated(unsafe) private static var githubBlockedUntil: [String: Date] = [:]

    private let database: Database
    private let session: URLSession
    private let delegate: MetadataHTTPSessionDelegate
    private let environment: [String: String]
    private let now: () -> Date

    public init(database: Database, configuration: URLSessionConfiguration = .ephemeral, environment: [String: String] = ProcessInfo.processInfo.environment, now: @escaping () -> Date = { .now }) {
        self.database = database
        self.environment = environment
        self.now = now
        delegate = MetadataHTTPSessionDelegate()
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public func fetch(_ url: URL, resource: MetadataResource) throws -> MetadataHTTPResponse {
        guard debug else { return try perform(url, policy: policy(for: resource)) }
        let started = Date()
        do {
            let response = try perform(url, policy: policy(for: resource))
            Self.trace("GET \(url.absoluteString) -> \(response.body.count) bytes in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            return response
        } catch {
            Self.trace("GET \(url.absoluteString) -> \(error.localizedDescription) after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            throw error
        }
    }

    /// Whether GitHub requests carry a token (and so have 5,000 requests an hour, not 60).
    var hasGitHubToken: Bool { githubToken() != nil }

    /// `SIFT_DEBUG=1` traces every metadata request and changelog decision to standard error.
    var debug: Bool { environment["SIFT_DEBUG"].map { !$0.isEmpty && $0 != "0" } ?? false }

    static func trace(_ message: String) {
        FileHandle.standardError.write(Data("sift: \(message.terminalInline)\n".utf8))
    }

    /// `derive` applied to the response, saved next to it: while the cached response is the same
    /// one (same ETag, or the same download when the server sends none), the saved value is reused
    /// instead of deriving it again. Fetching works exactly as `fetch` does.
    public func fetch<Value: Codable>(_ url: URL, resource: MetadataResource, derivedAs name: String, _ derive: (Data) throws -> Value) throws -> Value {
        let policy = policy(for: resource)
        let derivedKind = "\(policy.cacheKey)-derived-\(name)"
        // The response a saved value was derived from: its ETag, or the download itself when the
        // server sends none.
        func sourceKey(_ cached: CachedMetadataResponse) -> String { cached.etag ?? "validated:\(cached.validatedAt.timeIntervalSince1970)" }
        // JSON decodes about twice as fast as a property list here.
        func saved(for source: String?) -> Value? {
            guard let source, let saved = try? database.cachedMetadataResponse(url: url.absoluteString, resourceKind: derivedKind), saved.etag == source,
                  let compressed = saved.body, let data = try? (compressed as NSData).decompressed(using: .lzfse) as Data else { return nil }
            return try? JSONDecoder().decode(Value.self, from: data)
        }
        // While the cached response is fresh its body isn't needed at all: the saved value answers
        // without decompressing it (the cask catalog is 19 MB).
        if let cached = try database.cachedMetadataResponse(url: url.absoluteString, resourceKind: policy.cacheKey), cached.statusCode == 200,
           case let age = now().timeIntervalSince(cached.validatedAt), age >= 0, age < policy.maxAge,
           let value = saved(for: sourceKey(cached)) {
            return value
        }
        let body = try perform(url, policy: policy).body
        let source = (try? database.cachedMetadataResponse(url: url.absoluteString, resourceKind: policy.cacheKey)).flatMap { $0 }.map(sourceKey)
        if let value = saved(for: source) { return value }
        let value = try derive(body)
        if let source, let data = try? JSONEncoder().encode(value), let compressed = try? (data as NSData).compressed(using: .lzfse) as Data {
            try? database.storeMetadataResponse(url: url.absoluteString, resourceKind: derivedKind, statusCode: 200, body: compressed, etag: source, lastModified: nil, validatedAt: now())
        }
        return value
    }

    private func perform(_ url: URL, policy: MetadataHTTPPolicy) throws -> MetadataHTTPResponse {
        guard isAllowedMetadataURL(url, policy: policy) else { throw MetadataHTTPError.unsupportedURL }
        let deadline = DispatchTime.now() + policy.outerTimeout
        let timestamp = now()
        let cached = try database.cachedMetadataResponse(url: url.absoluteString, resourceKind: policy.cacheKey).map { decodedCache($0, policy: policy) }
        let age = cached.map { timestamp.timeIntervalSince($0.validatedAt) }
        if let cached, let age, age >= 0, age < policy.maxAge {
            if cached.statusCode == 404 { throw MetadataHTTPError.notFound }
            guard let body = cached.body else { throw MetadataHTTPError.invalidResponse }
            return MetadataHTTPResponse(body: body)
        }
        if policy.serialGitHub {
            let githubConcurrency = policy.token != nil ? Self.githubConcurrencyAuthenticated : Self.githubConcurrencyAnonymous
            guard githubConcurrency.wait(timeout: deadline) == .success else { throw MetadataHTTPError.timedOut }
            defer { githubConcurrency.signal() }
            if let retryAt = blockedUntil(for: policy) { throw MetadataHTTPError.rateLimited(retryAt: retryAt) }
        }
        guard Self.concurrency.wait(timeout: deadline) == .success else { throw MetadataHTTPError.timedOut }
        defer { Self.concurrency.signal() }
        var request = URLRequest(url: url)
        request.timeoutInterval = min(policy.timeout, remaining(until: deadline))
        request.setValue(policy.accept, forHTTPHeaderField: "Accept")
        for (name, value) in policy.headers { request.setValue(value, forHTTPHeaderField: name) }
        if let token = policy.token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let etag = cached?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified = cached?.lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let result = HTTPDataResult()
        let task = session.dataTask(with: request)
        delegate.register(task: task, policy: policy, result: result)
        task.resume()
        guard result.wait(timeout: deadline) else {
            task.cancel()
            _ = result.waitForCompletion(timeout: .now() + 2)
            throw MetadataHTTPError.timedOut
        }
        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try result.value().get() }
        catch {
            task.cancel()
            _ = result.waitForCompletion(timeout: .now() + 2)
            throw normalizedTransportError(error)
        }
        let validatedAt = now()
        if response.statusCode == 304, cached == nil { throw MetadataHTTPError.invalidResponse }
        if response.statusCode == 304, let cached {
            try database.storeMetadataResponse(url: url.absoluteString, resourceKind: policy.cacheKey, statusCode: cached.statusCode, body: encodedCacheBody(cached.body, policy: policy), etag: response.value(forHTTPHeaderField: "ETag") ?? cached.etag, lastModified: response.value(forHTTPHeaderField: "Last-Modified") ?? cached.lastModified, validatedAt: validatedAt)
            if cached.statusCode == 404 { throw MetadataHTTPError.notFound }
            guard let body = cached.body else { throw MetadataHTTPError.invalidResponse }
            return MetadataHTTPResponse(body: body)
        }
        if response.statusCode == 404 {
            try database.storeMetadataResponse(url: url.absoluteString, resourceKind: policy.cacheKey, statusCode: 404, body: nil, etag: response.value(forHTTPHeaderField: "ETag"), lastModified: response.value(forHTTPHeaderField: "Last-Modified"), validatedAt: validatedAt)
            throw MetadataHTTPError.notFound
        }
        if let error = statusError(response, now: validatedAt) {
            if case let .rateLimited(retryAt) = error { blockGitHub(for: policy, until: retryAt ?? validatedAt.addingTimeInterval(60)) }
            throw error
        }
        guard (200...299).contains(response.statusCode) else { throw MetadataHTTPError.transport("Metadata server returned HTTP \(response.statusCode).") }
        try database.storeMetadataResponse(url: url.absoluteString, resourceKind: policy.cacheKey, statusCode: response.statusCode, body: encodedCacheBody(data, policy: policy), etag: response.value(forHTTPHeaderField: "ETag"), lastModified: response.value(forHTTPHeaderField: "Last-Modified"), validatedAt: validatedAt)
        return MetadataHTTPResponse(body: data)
    }

    private func policy(for resource: MetadataResource) -> MetadataHTTPPolicy {
        switch resource {
        case .homebrewCaskCatalog:
            // ~19 MB of JSON (2 MB on the wire); cached compressed and revalidated with its ETag.
            return MetadataHTTPPolicy(cacheKey: "homebrew-cask-catalog-v1", allowedHosts: ["formulae.brew.sh"], responseLimit: 64 * 1_048_576, accept: "application/json", headers: ["User-Agent": SiftVersion.userAgent], token: nil, serialGitHub: false, rateLimitKey: nil, compressesCache: true, maxAge: 60 * 60)
        case let .electronUpdateFeed(host):
            return MetadataHTTPPolicy(cacheKey: "electron-update-feed-v1", allowedHosts: [host.lowercased()], responseLimit: 1_048_576, accept: "text/yaml, application/x-yaml, text/plain", headers: ["User-Agent": SiftVersion.userAgent], token: nil, serialGitHub: false, rateLimitKey: nil, redirectsToPublicHosts: true, maxAge: 60 * 60)
        case .cratesIndex:
            return MetadataHTTPPolicy(cacheKey: "crates-index-v1", allowedHosts: ["index.crates.io"], responseLimit: 16 * 1_048_576, accept: "application/json, text/plain", headers: ["User-Agent": SiftVersion.userAgent], token: nil, serialGitHub: false, rateLimitKey: nil, compressesCache: true, maxAge: 60 * 60)
        case .blackmagicDownloads:
            return MetadataHTTPPolicy(cacheKey: "blackmagic-downloads-v1", allowedHosts: ["www.blackmagicdesign.com"], responseLimit: 8 * 1_048_576, accept: "application/json", headers: ["User-Agent": SiftVersion.userAgent], token: nil, serialGitHub: false, rateLimitKey: nil, compressesCache: true, maxAge: 60 * 60)
        case .appStoreLookup:
            return MetadataHTTPPolicy(cacheKey: "app-store-lookup-v1", allowedHosts: ["itunes.apple.com"], responseLimit: 1_048_576, accept: "application/json", headers: ["User-Agent": SiftVersion.userAgent], token: nil, serialGitHub: false, rateLimitKey: nil, maxAge: 60 * 60)
        case let .sparkleAppcast(host):
            // Feeds commonly redirect to a CDN or object store (some go to S3), as Sparkle allows.
            return MetadataHTTPPolicy(cacheKey: "sparkle-appcast-v1", allowedHosts: [host.lowercased()], responseLimit: 4_194_304, accept: "application/rss+xml, application/xml, text/xml", headers: ["User-Agent": SiftVersion.userAgent], token: nil, serialGitHub: false, rateLimitKey: nil, redirectsToPublicHosts: true, maxAge: 60 * 60)
        case let .changelogPage(host):
            // Project sites move their changelogs behind redirects to docs hosts and CDNs.
            return MetadataHTTPPolicy(cacheKey: "changelog-page-v1", allowedHosts: [host.lowercased()], responseLimit: 8 * 1_048_576, accept: "text/html, text/markdown, text/plain;q=0.9, */*;q=0.5", headers: ["User-Agent": SiftVersion.userAgent], token: nil, serialGitHub: false, rateLimitKey: nil, compressesCache: true, redirectsToPublicHosts: true)
        case .packageRegistry:
            return MetadataHTTPPolicy(cacheKey: "package-registry-v1", allowedHosts: ["registry.npmjs.org", "pypi.org", "crates.io", "formulae.brew.sh"], responseLimit: 16 * 1_048_576, accept: "application/json", headers: ["User-Agent": SiftVersion.userAgent], token: nil, serialGitHub: false, rateLimitKey: nil, compressesCache: true, maxAge: 24 * 60 * 60)
        case .steamNews:
            return MetadataHTTPPolicy(cacheKey: "steam-news-v1", allowedHosts: ["api.steampowered.com"], responseLimit: 16 * 1_048_576, accept: "application/json", headers: ["User-Agent": SiftVersion.userAgent], token: nil, serialGitHub: false, rateLimitKey: nil, compressesCache: true, maxAge: 60 * 60)
        case .appStorePage:
            return MetadataHTTPPolicy(cacheKey: "app-store-page-v1", allowedHosts: ["apps.apple.com"], responseLimit: 8 * 1_048_576, accept: "text/html", headers: ["User-Agent": SiftVersion.userAgent], token: nil, serialGitHub: false, rateLimitKey: nil, compressesCache: true)
        case .githubChangelog:
            return MetadataHTTPPolicy(cacheKey: "github-changelog-v2", allowedHosts: ["raw.githubusercontent.com"], responseLimit: 2_097_152, accept: "text/plain", headers: [:], token: nil, serialGitHub: false, rateLimitKey: nil)
        case .githubReference: return githubPolicy("github-reference", responseLimit: 2_097_152)
        case .githubAnnotatedTag: return githubPolicy("github-annotated-tag", responseLimit: 2_097_152)
        case .githubReleaseByTag: return githubPolicy("github-release-by-tag", responseLimit: 2_097_152)
        case .githubLatestRelease: return githubPolicy("github-latest-release", responseLimit: 2_097_152, maxAge: 60 * 60)
        // A page of 100 releases with long notes (LLVM's) runs past 4 MB.
        case .githubReleaseList: return githubPolicy("github-release-list", responseLimit: 32 * 1_048_576)
        case .githubTree: return githubPolicy("github-tree", responseLimit: 4_194_304)
        case .githubBlob: return githubPolicy("github-blob", responseLimit: 4_194_304)
        }
    }

    /// GitHub API responses are cached per credential, so a token's wider view never answers an
    /// anonymous request or the reverse.
    private func githubPolicy(_ name: String, responseLimit limit: Int, maxAge: TimeInterval = 6 * 60 * 60) -> MetadataHTTPPolicy {
        let token = githubToken()
        let representation = token.map { "auth-\(tokenFingerprint($0))" } ?? "anonymous"
        return MetadataHTTPPolicy(cacheKey: "\(name)-v3-\(representation)", allowedHosts: ["api.github.com"], responseLimit: limit, accept: "application/vnd.github+json", headers: ["X-GitHub-Api-Version": "2022-11-28", "User-Agent": SiftVersion.userAgent], token: token, serialGitHub: true, rateLimitKey: representation, maxAge: maxAge)
    }

    /// Large catalogs are stored LZFSE-compressed; everything else is stored as received.
    private func encodedCacheBody(_ body: Data?, policy: MetadataHTTPPolicy) -> Data? {
        guard policy.compressesCache, let body else { return body }
        return (try? (body as NSData).compressed(using: .lzfse) as Data) ?? body
    }

    private func decodedCache(_ cached: CachedMetadataResponse, policy: MetadataHTTPPolicy) -> CachedMetadataResponse {
        guard policy.compressesCache, let body = cached.body else { return cached }
        // An undecodable body is treated as no body, which forces a fresh download.
        let decoded = try? (body as NSData).decompressed(using: .lzfse) as Data
        return CachedMetadataResponse(statusCode: cached.statusCode, body: decoded, etag: decoded == nil ? nil : cached.etag, lastModified: decoded == nil ? nil : cached.lastModified, validatedAt: decoded == nil ? .distantPast : cached.validatedAt)
    }

    private func githubToken() -> String? {
        if let token = [environment["GITHUB_TOKEN"], environment["GH_TOKEN"]].compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }).first { return token }
        guard environment["SIFT_NO_GH_TOKEN"] == nil else { return nil }
        return Self.ghToken.withLock { cached in
            if let cached { return cached.token }
            let token = Self.readGHToken(environment: environment)
            cached = (token, ())
            return token
        }
    }

    /// The GitHub CLI's login (`gh auth token`), read once per run: the user's own credential,
    /// which raises GitHub's limit from 60 to 5,000 requests an hour.
    private static let ghToken = GHTokenBox()

    private static func readGHToken(environment: [String: String]) -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/opt/local/bin/gh"].map { URL(filePath: $0) }
        guard let gh = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }),
              let result = try? CommandRunner().run(executable: gh, arguments: ["auth", "token", "--hostname", "github.com"], environment: environment.filter { ["HOME", "PATH", "XDG_CONFIG_HOME", "GH_CONFIG_DIR", "USER"].contains($0.key) }, timeout: 5, outputLimit: 4_096),
              result.status == 0 else { return nil }
        let token = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty || token.contains(where: \.isWhitespace) ? nil : token
    }

    private func tokenFingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func blockedUntil(for policy: MetadataHTTPPolicy) -> Date? {
        guard let key = policy.rateLimitKey else { return nil }
        let current = now()
        if let blocked = Self.rateLimitLock.withLock({ () -> Date? in
            Self.githubBlockedUntil = Self.githubBlockedUntil.filter { $0.value > current }
            return Self.githubBlockedUntil[key]
        }) { return blocked }
        // A block recorded by an earlier run still applies: asking again only spends a request.
        guard let stored = (try? database.setting(Self.rateLimitSettingPrefix + key)).flatMap({ $0.flatMap(TimeInterval.init) }) else { return nil }
        let blocked = Date(timeIntervalSince1970: stored)
        guard blocked > current else { return nil }
        Self.rateLimitLock.withLock { Self.githubBlockedUntil[key] = max(Self.githubBlockedUntil[key] ?? blocked, blocked) }
        return blocked
    }

    private static let rateLimitSettingPrefix = "github-rate-limited-until:"

    private func blockGitHub(for policy: MetadataHTTPPolicy, until retryAt: Date?) {
        guard let key = policy.rateLimitKey, let retryAt else { return }
        Self.rateLimitLock.withLock {
            if Self.githubBlockedUntil[key] == nil || Self.githubBlockedUntil[key]! < retryAt {
                Self.githubBlockedUntil[key] = retryAt
            }
        }
        try? database.setSetting(Self.rateLimitSettingPrefix + key, value: String(retryAt.timeIntervalSince1970))
    }

    private func statusError(_ response: HTTPURLResponse, now: Date) -> MetadataHTTPError? {
        switch response.statusCode {
        case 200...299: return nil
        case 304: return nil
        case 401: return .authenticationFailed
        case 403 where response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" || response.value(forHTTPHeaderField: "Retry-After") != nil: return .rateLimited(retryAt: retryAt(response, now: now))
        case 403: return .forbidden
        case 404: return .notFound
        case 429: return .rateLimited(retryAt: retryAt(response, now: now))
        case 500...599: return .serverFailure(statusCode: response.statusCode)
        default: return .transport("Metadata server returned HTTP \(response.statusCode).")
        }
    }

    private func retryAt(_ response: HTTPURLResponse, now: Date) -> Date? {
        var candidates: [Date] = []
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = TimeInterval(retryAfter), seconds >= 0 {
                candidates.append(now.addingTimeInterval(seconds))
            } else if let date = httpDate(retryAfter) {
                candidates.append(date)
            }
        }
        if let seconds = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init) {
            candidates.append(Date(timeIntervalSince1970: seconds))
        }
        return candidates.filter { $0 > now }.map { min($0, now.addingTimeInterval(60 * 60)) }.max()
    }

    private func normalizedTransportError(_ error: Error) -> MetadataHTTPError {
        if let error = error as? MetadataHTTPError { return error }
        guard let error = error as? URLError else { return .transport(error.localizedDescription) }
        if error.code == .timedOut { return .timedOut }
        // An application firewall's prompt left unanswered typically surfaces as a lost or
        // refused connection, so name the host-level cause rather than a bare error code.
        let reason: String = switch error.code {
        case .networkConnectionLost: "the network connection was lost"
        case .notConnectedToInternet: "the Mac is not connected to the internet"
        case .cannotFindHost, .dnsLookupFailed: "the host could not be found"
        case .cannotConnectToHost: "the host refused the connection"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot: "a secure connection could not be established"
        default: "the request failed"
        }
        let host = error.failingURL?.host.map { " to \($0)" } ?? ""
        return .transport("Metadata request\(host) failed: \(reason) (URL error \(error.code.rawValue)).")
    }

    private func remaining(until deadline: DispatchTime) -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline.uptimeNanoseconds > now else { return 0.001 }
        return TimeInterval(deadline.uptimeNanoseconds - now) / 1_000_000_000
    }

    private func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: value)
    }
}

/// Where a request may end up after redirects: an allowed host, or for policies that permit it, any
/// public HTTPS host.
private func isAllowedRedirectURL(_ url: URL?, policy: MetadataHTTPPolicy) -> Bool {
    if isAllowedMetadataURL(url, policy: policy) { return true }
    guard policy.redirectsToPublicHosts, let url else { return false }
    return isPublicHTTPSURL(url)
}

/// HTTPS on a named public host: no credentials, ports, IP literals, or local names.
func isPublicHTTPSURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil,
          let host = url.host?.lowercased(), host.contains("."), !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), host != "localhost",
          host.contains(where: \.isLetter), !host.contains(":") else { return false }
    return true
}

/// Shared by `MetadataHTTPClient` (initial request) and, through `isAllowedRedirectURL`,
/// `MetadataHTTPSessionDelegate` (each redirect hop and the final response), so the HTTPS/host
/// allowlist can't drift between the call sites.
private func isAllowedMetadataURL(_ url: URL?, policy: MetadataHTTPPolicy) -> Bool {
    guard let url else { return false }
    return url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil && url.port == nil && url.host.map { policy.allowedHosts.contains($0.lowercased()) } == true
}

private struct MetadataHTTPPolicy: Sendable {
    let cacheKey: String
    let allowedHosts: Set<String>
    let responseLimit: Int
    let accept: String
    let headers: [String: String]
    let token: String?
    let serialGitHub: Bool
    let rateLimitKey: String?
    var compressesCache = false
    /// Redirects may leave `allowedHosts` for any public HTTPS host (see `isPublicHTTPSURL`).
    var redirectsToPublicHosts = false
    /// How long a cached response is used without asking the server again. Release notes are
    /// pinned to a version and GitHub's anonymous quota is small, so they keep six hours; sources
    /// that announce new versions are asked again after an hour, as Homebrew's metadata is.
    var maxAge: TimeInterval = 6 * 60 * 60
    let timeout: TimeInterval = 30
    let outerTimeout: TimeInterval = 35
}

private final class MetadataHTTPSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct RequestState { let policy: MetadataHTTPPolicy; let result: HTTPDataResult; var redirectCount: Int }
    private let lock = NSLock()
    private var requests: [Int: RequestState] = [:]

    func register(task: URLSessionDataTask, policy: MetadataHTTPPolicy, result: HTTPDataResult) { lock.withLock { requests[task.taskIdentifier] = RequestState(policy: policy, result: result, redirectCount: 0) } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let state = lock.withLock { () -> RequestState? in
            guard var state = requests[task.taskIdentifier] else { return nil }
            guard state.redirectCount < 5, isAllowedRedirectURL(request.url, policy: state.policy) else { state.result.fail(MetadataHTTPError.unsupportedURL); requests[task.taskIdentifier] = state; return nil }
            state.redirectCount += 1
            requests[task.taskIdentifier] = state
            return state
        }
        completionHandler(state == nil ? nil : request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let state = lock.withLock({ requests[dataTask.taskIdentifier] }), isAllowedRedirectURL(response.url, policy: state.policy), let http = response as? HTTPURLResponse else { result(for: dataTask)?.fail(MetadataHTTPError.unsupportedURL); completionHandler(.cancel); return }
        state.result.setResponse(http)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = lock.withLock({ requests[dataTask.taskIdentifier] }) else { return }
        if !state.result.append(data, limit: state.policy.responseLimit) { state.result.fail(MetadataHTTPError.responseTooLarge); dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { lock.withLock { requests.removeValue(forKey: task.taskIdentifier)?.result }?.complete(error: error) }
    private func result(for task: URLSessionTask) -> HTTPDataResult? { lock.withLock { requests[task.taskIdentifier]?.result } }
}

private final class HTTPDataResult: @unchecked Sendable {
    private let lock = NSLock(); private let semaphore = DispatchSemaphore(value: 0); private let completionSemaphore = DispatchSemaphore(value: 0)
    private var data = Data(); private var response: HTTPURLResponse?; private var failure: Error?; private var completed = false; private var finished = false
    func setResponse(_ response: HTTPURLResponse) { lock.withLock { self.response = response } }
    func append(_ bytes: Data, limit: Int) -> Bool { lock.withLock { guard failure == nil, bytes.count <= limit, data.count <= limit - bytes.count else { return false }; data.append(bytes); return true } }
    func fail(_ error: Error) {
        let signal = lock.withLock { () -> Bool in
            guard !completed else { return false }
            failure = error
            completed = true
            return true
        }
        if signal { semaphore.signal() }
    }
    func complete(error: Error?) {
        let signals = lock.withLock { () -> (Bool, Bool) in
            let resultSignal: Bool
            if completed { resultSignal = false } else { completed = true; if failure == nil, let error { failure = error }; resultSignal = true }
            let completionSignal = !finished
            finished = true
            return (resultSignal, completionSignal)
        }
        if signals.0 { semaphore.signal() }
        if signals.1 { completionSemaphore.signal() }
    }
    func wait(timeout: DispatchTime) -> Bool { semaphore.wait(timeout: timeout) == .success }
    func waitForCompletion(timeout: DispatchTime) -> Bool { completionSemaphore.wait(timeout: timeout) == .success }
    func value() -> Result<(Data, HTTPURLResponse), Error> { lock.withLock { if let failure { return .failure(failure) }; guard let response else { return .failure(MetadataHTTPError.invalidResponse) }; return .success((data, response)) } }
}

/// A once-per-process cache for the GitHub CLI's token.
private final class GHTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (token: String?, Void)?
    func withLock<T>(_ body: (inout (token: String?, Void)?) -> T) -> T { lock.withLock { body(&value) } }
}
