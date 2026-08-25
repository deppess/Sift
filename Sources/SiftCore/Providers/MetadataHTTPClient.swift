import CryptoKit
import Foundation

public enum MetadataResource: Sendable {
    case homebrewTarget
    case githubReference
    case githubAnnotatedTag
    case githubReleaseByTag
    case githubReleaseList
    case githubCommit
    case githubTree
    case githubBlob
    case githubChangelog
}

public struct MetadataHTTPResponse: Sendable {
    public let body: Data
    public let linkHeader: String?
    public let validatedAt: Date
    public let fromCache: Bool
}

public struct CachedMetadataResponse: Sendable {
    public let statusCode: Int
    public let body: Data?
    public let etag: String?
    public let lastModified: String?
    public let linkHeader: String?
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
    private static let githubConcurrency = DispatchSemaphore(value: 1)

    private let database: Database
    private let session: URLSession
    private let delegate: MetadataHTTPSessionDelegate
    private let environment: [String: String]
    private let now: () -> Date
    private let rateLimitLock = NSLock()
    private var githubBlockedUntil: Date?

    public init(database: Database, configuration: URLSessionConfiguration = .ephemeral, environment: [String: String] = ProcessInfo.processInfo.environment, now: @escaping () -> Date = { .now }) {
        self.database = database
        self.environment = environment
        self.now = now
        delegate = MetadataHTTPSessionDelegate()
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public func fetch(_ url: URL, resource: MetadataResource) throws -> MetadataHTTPResponse {
        try perform(url, policy: policy(for: resource))
    }

    private func perform(_ url: URL, policy: MetadataHTTPPolicy) throws -> MetadataHTTPResponse {
        guard isAllowed(url, policy: policy) else { throw MetadataHTTPError.unsupportedURL }
        let timestamp = now()
        let cached = try database.cachedMetadataResponse(url: url.absoluteString, resourceKind: policy.cacheKey)
        let age = cached.map { timestamp.timeIntervalSince($0.validatedAt) }
        if let cached, let age, age >= 0, age < policy.maxAge {
            if cached.statusCode == 404 { throw MetadataHTTPError.notFound }
            guard let body = cached.body else { throw MetadataHTTPError.invalidResponse }
            return MetadataHTTPResponse(body: body, linkHeader: cached.linkHeader, validatedAt: cached.validatedAt, fromCache: true)
        }
        guard Self.concurrency.wait(timeout: .now() + policy.outerTimeout) == .success else { throw MetadataHTTPError.timedOut }
        defer { Self.concurrency.signal() }
        if policy.serialGitHub {
            if let retryAt = blockedUntil() { throw MetadataHTTPError.rateLimited(retryAt: retryAt) }
            guard Self.githubConcurrency.wait(timeout: .now() + policy.outerTimeout) == .success else { throw MetadataHTTPError.timedOut }
        }
        defer { if policy.serialGitHub { Self.githubConcurrency.signal() } }
        var request = URLRequest(url: url)
        request.timeoutInterval = policy.timeout
        request.setValue(policy.accept, forHTTPHeaderField: "Accept")
        for (name, value) in policy.headers { request.setValue(value, forHTTPHeaderField: name) }
        if let token = policy.token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let etag = cached?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified = cached?.lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let result = HTTPDataResult()
        let task = session.dataTask(with: request)
        delegate.register(task: task, policy: policy, result: result)
        task.resume()
        guard result.wait(timeout: .now() + policy.outerTimeout) else { task.cancel(); _ = result.waitForCompletion(timeout: .now() + 2); throw MetadataHTTPError.timedOut }
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
            try database.storeMetadataResponse(url: url.absoluteString, resourceKind: policy.cacheKey, statusCode: cached.statusCode, body: cached.body, etag: response.value(forHTTPHeaderField: "ETag") ?? cached.etag, lastModified: response.value(forHTTPHeaderField: "Last-Modified") ?? cached.lastModified, validatedAt: validatedAt, linkHeader: response.value(forHTTPHeaderField: "Link") ?? cached.linkHeader)
            if cached.statusCode == 404 { throw MetadataHTTPError.notFound }
            guard let body = cached.body else { throw MetadataHTTPError.invalidResponse }
            return MetadataHTTPResponse(body: body, linkHeader: response.value(forHTTPHeaderField: "Link") ?? cached.linkHeader, validatedAt: validatedAt, fromCache: true)
        }
        if response.statusCode == 404 {
            try database.storeMetadataResponse(url: url.absoluteString, resourceKind: policy.cacheKey, statusCode: 404, body: nil, etag: response.value(forHTTPHeaderField: "ETag"), lastModified: response.value(forHTTPHeaderField: "Last-Modified"), validatedAt: validatedAt)
            throw MetadataHTTPError.notFound
        }
        if let error = statusError(response, now: validatedAt) {
            if case let .rateLimited(retryAt) = error { blockGitHub(until: retryAt ?? validatedAt.addingTimeInterval(60)) }
            throw error
        }
        guard (200...299).contains(response.statusCode) else { throw MetadataHTTPError.transport("Metadata server returned HTTP \(response.statusCode).") }
        try database.storeMetadataResponse(url: url.absoluteString, resourceKind: policy.cacheKey, statusCode: response.statusCode, body: data, etag: response.value(forHTTPHeaderField: "ETag"), lastModified: response.value(forHTTPHeaderField: "Last-Modified"), validatedAt: validatedAt, linkHeader: response.value(forHTTPHeaderField: "Link"))
        return MetadataHTTPResponse(body: data, linkHeader: response.value(forHTTPHeaderField: "Link"), validatedAt: validatedAt, fromCache: false)
    }

    private func policy(for resource: MetadataResource) -> MetadataHTTPPolicy {
        switch resource {
        case .homebrewTarget:
            return MetadataHTTPPolicy(cacheKey: "homebrew-target-v2", allowedHosts: ["formulae.brew.sh"], responseLimit: 1_048_576, accept: "application/json", headers: [:], token: nil, serialGitHub: false)
        case .githubChangelog:
            return MetadataHTTPPolicy(cacheKey: "github-changelog-v2", allowedHosts: ["raw.githubusercontent.com"], responseLimit: 2_097_152, accept: "text/plain", headers: [:], token: nil, serialGitHub: false)
        case .githubReference, .githubAnnotatedTag, .githubReleaseByTag, .githubReleaseList, .githubCommit, .githubTree, .githubBlob:
            let token = githubToken()
            let name: String
            switch resource {
            case .githubReference: name = "github-reference"
            case .githubAnnotatedTag: name = "github-annotated-tag"
            case .githubReleaseByTag: name = "github-release-by-tag"
            case .githubReleaseList: name = "github-release-list"
            case .githubCommit: name = "github-commit"
            case .githubTree: name = "github-tree"
            case .githubBlob: name = "github-blob"
            default: fatalError("Non-GitHub API resource")
            }
            let limit = resource == .githubReleaseList || resource == .githubTree || resource == .githubBlob ? 4_194_304 : 2_097_152
            let representation = token.map { "auth-\(tokenFingerprint($0))" } ?? "anonymous"
            return MetadataHTTPPolicy(cacheKey: "\(name)-v3-\(representation)", allowedHosts: ["api.github.com"], responseLimit: limit, accept: "application/vnd.github+json", headers: ["X-GitHub-Api-Version": "2022-11-28", "User-Agent": "sift-pre-v1"], token: token, serialGitHub: true)
        }
    }

    private func githubToken() -> String? {
        [environment["GITHUB_TOKEN"], environment["GH_TOKEN"]].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }.first
    }

    private func tokenFingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func blockedUntil() -> Date? {
        rateLimitLock.withLock {
            guard let blocked = githubBlockedUntil else { return nil }
            if blocked <= now() { githubBlockedUntil = nil; return nil }
            return blocked
        }
    }

    private func blockGitHub(until retryAt: Date?) {
        guard let retryAt else { return }
        rateLimitLock.withLock { if githubBlockedUntil == nil || githubBlockedUntil! < retryAt { githubBlockedUntil = retryAt } }
    }

    private func isAllowed(_ url: URL, policy: MetadataHTTPPolicy) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil && url.port == nil && url.host.map { policy.allowedHosts.contains($0.lowercased()) } == true
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
        if let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) { return now.addingTimeInterval(seconds) }
        if let seconds = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init) { return Date(timeIntervalSince1970: seconds) }
        return nil
    }

    private func normalizedTransportError(_ error: Error) -> MetadataHTTPError {
        guard let error = error as? URLError else { return .transport(error.localizedDescription) }
        return error.code == .timedOut ? .timedOut : .transport("Metadata transport failed: \(error.code.rawValue).")
    }
}

private struct MetadataHTTPPolicy: Sendable {
    let cacheKey: String
    let allowedHosts: Set<String>
    let responseLimit: Int
    let accept: String
    let headers: [String: String]
    let token: String?
    let serialGitHub: Bool
    let maxAge: TimeInterval = 6 * 60 * 60
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
            guard state.redirectCount < 5, isAllowed(request.url, policy: state.policy) else { state.result.fail(MetadataHTTPError.unsupportedURL); requests[task.taskIdentifier] = state; return nil }
            state.redirectCount += 1
            requests[task.taskIdentifier] = state
            return state
        }
        completionHandler(state == nil ? nil : request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let state = lock.withLock({ requests[dataTask.taskIdentifier] }), isAllowed(response.url, policy: state.policy), let http = response as? HTTPURLResponse else { result(for: dataTask)?.fail(MetadataHTTPError.unsupportedURL); completionHandler(.cancel); return }
        state.result.setResponse(http)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = lock.withLock({ requests[dataTask.taskIdentifier] }) else { return }
        if !state.result.append(data, limit: state.policy.responseLimit) { state.result.fail(MetadataHTTPError.responseTooLarge); dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { lock.withLock { requests.removeValue(forKey: task.taskIdentifier)?.result }?.complete(error: error) }
    private func result(for task: URLSessionTask) -> HTTPDataResult? { lock.withLock { requests[task.taskIdentifier]?.result } }
    private func isAllowed(_ url: URL?, policy: MetadataHTTPPolicy) -> Bool { guard let url else { return false }; return url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil && url.port == nil && url.host.map { policy.allowedHosts.contains($0.lowercased()) } == true }
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

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
