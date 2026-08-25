import Foundation

public struct GitHubRepository: Equatable, Sendable {
    public let owner: String
    public let name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    public var path: String { "\(owner)/\(name)" }
}

public struct GitHubSource: Equatable, Sendable {
    public let repository: GitHubRepository
    public let tag: String?

    public init(repository: GitHubRepository, tag: String?) {
        self.repository = repository
        self.tag = tag
    }

    public static func parse(_ url: URL) -> GitHubSource? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        switch host {
        case "github.com":
            return parseGitHubPath(path)
        case "codeload.github.com":
            return parseCodeloadPath(path)
        default:
            return nil
        }
    }

    private static func parseGitHubPath(_ path: [String]) -> GitHubSource? {
        guard let repository = repository(from: path) else { return nil }
        let suffix = Array(path.dropFirst(2))
        guard !suffix.isEmpty else { return GitHubSource(repository: repository, tag: nil) }
        if suffix.starts(with: ["archive", "refs", "tags"]) {
            return tagged(repository, encodedTag: suffix.dropFirst(3).joined(separator: "/"), archive: true)
        }
        if suffix.first == "archive" {
            return tagged(repository, encodedTag: suffix.dropFirst().joined(separator: "/"), archive: true)
        }
        if suffix.starts(with: ["releases", "download"]) {
            return tagged(repository, encodedTag: suffix.dropFirst(2).first ?? "", archive: false)
        }
        if suffix.starts(with: ["releases", "tag"]) {
            return tagged(repository, encodedTag: suffix.dropFirst(2).joined(separator: "/"), archive: false)
        }
        return GitHubSource(repository: repository, tag: nil)
    }

    private static func parseCodeloadPath(_ path: [String]) -> GitHubSource? {
        guard let repository = repository(from: path), path.count >= 5,
              path[2] == "tar.gz", path[3] == "refs", path[4] == "tags" else { return nil }
        return tagged(repository, encodedTag: path.dropFirst(5).joined(separator: "/"), archive: false)
    }

    private static func repository(from path: [String]) -> GitHubRepository? {
        guard path.count >= 2,
              let owner = decode(path[0]),
              let name = decode(path[1]),
              isPathComponent(owner), isPathComponent(name) else { return nil }
        let repository = name.hasSuffix(".git") ? String(name.dropLast(4)) : name
        guard isPathComponent(repository) else { return nil }
        return GitHubRepository(owner: owner, name: repository)
    }

    private static func tagged(_ repository: GitHubRepository, encodedTag: String, archive: Bool) -> GitHubSource? {
        let suffixes = archive ? [".tar.gz", ".zip"] : []
        let unarchived = suffixes.first(where: { encodedTag.hasSuffix($0) }).map { String(encodedTag.dropLast($0.count)) } ?? encodedTag
        guard let tag = decode(unarchived), isTag(tag) else { return nil }
        return GitHubSource(repository: repository, tag: tag)
    }

    private static func decode(_ value: String) -> String? {
        guard let decoded = value.removingPercentEncoding, !decoded.isEmpty else { return nil }
        return decoded
    }

    private static func isPathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    }

    private static func isTag(_ value: String) -> Bool {
        !value.hasPrefix("/") && !value.hasSuffix("/") && !value.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    }
}
