import Foundation

struct GitHubCompareResolver: Sendable {
    private let metadataClient: MetadataHTTPClient?

    init(metadataClient: MetadataHTTPClient?) {
        self.metadataClient = metadataClient
    }

    func compare(repository: GitHubRepository, installedCommit: String, targetCommit: String) throws -> GitHubComparison? {
        guard let metadataClient,
            let owner = encodeGitHubPathComponent(repository.owner),
            let name = encodeGitHubPathComponent(repository.name),
            let installed = encodeGitHubPathComponent(installedCommit),
            let target = encodeGitHubPathComponent(targetCommit),
            let url = URL(string: "https://api.github.com/repos/\(owner)/\(name)/compare/\(installed)...\(target)")
        else { return nil }
        let data = try metadataClient.fetch(url, resource: .githubReference).body
        let response = try JSONDecoder().decode(Response.self, from: data)
        return GitHubComparison(
            commits: response.commits.map { GitHubCommitSummary(sha: $0.sha, message: $0.commit.message) },
            sourceURL: "https://github.com/\(repository.path)/compare/\(installedCommit)...\(targetCommit)")
    }

    private struct Response: Decodable {
        let commits: [Commit]
    }
    private struct Commit: Decodable { let sha: String; let commit: Message }
    private struct Message: Decodable { let message: String }
}

struct GitHubComparison: Equatable, Sendable {
    let commits: [GitHubCommitSummary]
    let sourceURL: String
}

struct GitHubCommitSummary: Equatable, Sendable {
    let sha: String
    let message: String

    var title: String { message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message }
}
