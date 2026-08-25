import Foundation

public struct GitHubRelease: Equatable, Sendable {
    public let id: Int64
    public let body: String
}

public struct GitHubReleaseResolver: Sendable {
    private let metadataClient: MetadataHTTPClient?

    public init(metadataClient: MetadataHTTPClient?) {
        self.metadataClient = metadataClient
    }

    public func release(repository: GitHubRepository, tag: String) throws -> GitHubRelease? {
        guard let metadataClient, let url = apiURL(repository: repository, tag: tag) else { return nil }
        do {
            let data = try metadataClient.fetch(url, resource: .githubReleaseByTag).body
            let release = try JSONDecoder().decode(ReleaseResponse.self, from: data)
            guard !release.draft else { return nil }
            return GitHubRelease(id: release.id, body: release.body ?? "")
        } catch MetadataHTTPError.notFound {
            return nil
        } catch {
            throw error
        }
    }

    public func sourceURL(repository: GitHubRepository, tag: String) -> String {
        "https://github.com/\(repository.path)/releases/tag/\(encodePathComponent(tag) ?? tag)"
    }

    private func apiURL(repository: GitHubRepository, tag: String) -> URL? {
        guard let owner = encodePathComponent(repository.owner),
              let name = encodePathComponent(repository.name),
              let tag = encodePathComponent(tag) else { return nil }
        return URL(string: "https://api.github.com/repos/\(owner)/\(name)/releases/tags/\(tag)")
    }

    private func encodePathComponent(_ value: String) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}

private struct ReleaseResponse: Decodable {
    let id: Int64
    let body: String?
    let draft: Bool
}
