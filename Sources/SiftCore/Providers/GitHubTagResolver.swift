import Foundation

public struct GitHubTagIdentity: Equatable, Sendable {
    public let tag: String
    public let commitSHA: String
}

public struct GitHubTagResolver: Sendable {
    private let metadataClient: MetadataHTTPClient?

    public init(metadataClient: MetadataHTTPClient?) {
        self.metadataClient = metadataClient
    }

    public func resolve(repository: GitHubRepository, sourceTag: String?, upstreamVersion: String) throws -> GitHubTagIdentity? {
        let candidates = sourceTag.map { [$0] } ?? versionCandidates(upstreamVersion)
        var matches: [GitHubTagIdentity] = []
        for candidate in candidates {
            do {
                if let identity = try resolveExactTag(repository: repository, tag: candidate) { matches.append(identity) }
            } catch MetadataHTTPError.notFound {
                continue
            }
        }
        // Both "1.2.3" and "v1.2.3" resolving is treated as ambiguous rather than guessed at,
        // consistent with PROJECT.md: weak evidence must not be used to establish ownership.
        return matches.count == 1 ? matches[0] : nil
    }

    private func versionCandidates(_ version: String) -> [String] {
        let alternate = version.hasPrefix("v") ? String(version.dropFirst()) : "v\(version)"
        return alternate == version || alternate.isEmpty ? [version] : [version, alternate]
    }

    private func resolveExactTag(repository: GitHubRepository, tag: String) throws -> GitHubTagIdentity? {
        guard let metadataClient, let referenceURL = apiURL(repository: repository, path: ["git", "ref", "tags", tag]) else { return nil }
        let reference = try decode(GitReference.self, from: metadataClient.fetch(referenceURL, resource: .githubReference).body)
        var object = reference.object
        for _ in 0..<5 {
            guard isSHA(object.sha) else { throw MetadataHTTPError.invalidResponse }
            if object.type == "commit" { return GitHubTagIdentity(tag: tag, commitSHA: object.sha) }
            guard object.type == "tag", let tagURL = apiURL(repository: repository, path: ["git", "tags", object.sha]) else { throw MetadataHTTPError.invalidResponse }
            object = try decode(GitTag.self, from: metadataClient.fetch(tagURL, resource: .githubAnnotatedTag).body).object
        }
        throw MetadataHTTPError.invalidResponse
    }

    private func apiURL(repository: GitHubRepository, path: [String]) -> URL? {
        let components = ["repos", repository.owner, repository.name] + path
        let encoded = components.compactMap(encodeGitHubPathComponent)
        guard encoded.count == components.count else { return nil }
        return URL(string: "https://api.github.com/\(encoded.joined(separator: "/"))")
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw MetadataHTTPError.invalidResponse }
    }

    private func isSHA(_ value: String) -> Bool {
        (40...64).contains(value.count) && value.unicodeScalars.allSatisfy { ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102) }
    }
}

private struct GitReference: Decodable {
    let object: GitObject
}

private struct GitTag: Decodable {
    let object: GitObject
}

private struct GitObject: Decodable {
    let type: String
    let sha: String
}
