import Foundation

public struct HomebrewReleaseNotes: Codable, Equatable, Sendable {
    public let name: String
    public let installedVersion: String
    public let availableVersion: String
    public let content: String
    public let sourceURL: String
    public let coverage: String
}

public struct ReleaseNotesResolver: HomebrewReleaseNotesResolving {
    private let metadataClient: MetadataHTTPClient?
    private let tagResolver: GitHubTagResolver
    private let releaseResolver: GitHubReleaseResolver
    private let compareResolver: GitHubCompareResolver

    public init(metadataClient: MetadataHTTPClient? = nil) {
        self.metadataClient = metadataClient
        tagResolver = GitHubTagResolver(metadataClient: metadataClient)
        releaseResolver = GitHubReleaseResolver(metadataClient: metadataClient)
        compareResolver = GitHubCompareResolver(metadataClient: metadataClient)
    }

    public func resolveReleaseNotes(for package: HomebrewPackage, target: HomebrewTarget) -> HomebrewReleaseNotesResolution {
        guard let source = target.sourceURL ?? package.sourceURL,
              let url = URL(string: source), GitHubSource.parse(url) != nil else {
            return .unsupported("No exact GitHub release-note source is available.")
        }
        do {
            guard let notes = try resolveExact(package: package, target: target) else {
                return .unavailable("The exact GitHub release and changelog contain no notes for this target.")
            }
            return .resolved(notes)
        } catch MetadataHTTPError.notFound {
            return .unavailable("The exact GitHub source has no release notes at the resolved target.")
        } catch {
            return .transientFailure(error.localizedDescription)
        }
    }

    private func resolveExact(package: HomebrewPackage, target: HomebrewTarget) throws -> HomebrewReleaseNotes? {
        guard let source = target.sourceURL ?? package.sourceURL,
              let sourceURL = URL(string: source),
              let github = GitHubSource.parse(sourceURL),
              let identity = try tagResolver.resolve(repository: github.repository, sourceTag: github.tag, upstreamVersion: target.upstreamVersion) else { return nil }
        let tag = identity.tag
        if let release = try releaseResolver.release(repository: github.repository, tag: tag),
           isMeaningfulReleaseBody(release.body) {
            return HomebrewReleaseNotes(
                name: package.fullName,
                installedVersion: package.installedVersion,
                availableVersion: target.version,
                content: release.body,
                sourceURL: releaseResolver.sourceURL(repository: github.repository, tag: tag),
                coverage: "targetOnly"
            )
        }
        guard let url = URL(string: "https://raw.githubusercontent.com/\(github.repository.path)/\(identity.commitSHA)/CHANGELOG.md") else { return nil }
        let document: String?
        do {
            document = try fetch(url)
        } catch MetadataHTTPError.notFound {
            document = nil
        }
        if let document {
            let content = extractRange(document, target: target.upstreamVersion, installed: HomebrewVersion.upstreamVersion(from: package.installedVersion))
            if !content.isEmpty {
                return HomebrewReleaseNotes(name: package.fullName, installedVersion: package.installedVersion, availableVersion: target.version, content: content, sourceURL: url.absoluteString, coverage: containsHeading(document, version: HomebrewVersion.upstreamVersion(from: package.installedVersion)) ? "complete" : "targetOnly")
            }
        }
        guard let installed = try tagResolver.resolve(repository: github.repository, sourceTag: nil, upstreamVersion: HomebrewVersion.upstreamVersion(from: package.installedVersion)),
              let comparison = try compareResolver.compare(repository: github.repository, installedCommit: installed.commitSHA, targetCommit: identity.commitSHA),
              !comparison.commits.isEmpty else { return nil }
        return HomebrewReleaseNotes(name: package.fullName, installedVersion: package.installedVersion, availableVersion: target.version, content: comparisonMarkdown(comparison), sourceURL: comparison.sourceURL, coverage: "repositoryCommits")
    }

    private func extractRange(_ document: String, target: String, installed: String) -> String {
        let lines = document.components(separatedBy: .newlines)
        let targetIndices = lines.indices.filter { headingVersion(lines[$0]) == target || headingVersion(lines[$0]) == "v\(target)" }
        guard targetIndices.count == 1, let start = targetIndices.first else { return "" }
        let end = lines.indices.dropFirst(start + 1).first { headingVersion(lines[$0]) == installed || headingVersion(lines[$0]) == "v\(installed)" } ?? lines.endIndex
        return lines[start..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsHeading(_ document: String, version: String) -> Bool {
        document.components(separatedBy: .newlines).contains { headingVersion($0) == version || headingVersion($0) == "v\(version)" }
    }

    private func headingVersion(_ line: String) -> String? {
        guard line.hasPrefix("## ") else { return nil }
        let heading = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
        let token: Substring
        if heading.hasPrefix("["), let closing = heading.firstIndex(of: "]") {
            token = heading[heading.index(after: heading.startIndex)..<closing]
        } else {
            token = heading.split(whereSeparator: { $0.isWhitespace }).first ?? ""
        }
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else { return nil }
        return String(token)
    }

    private func fetch(_ url: URL) throws -> String {
        guard let metadataClient else { throw MetadataHTTPError.invalidResponse }
        let data = try metadataClient.fetch(url, resource: .githubChangelog).body
        guard let text = String(data: data, encoding: .utf8) else { throw MetadataHTTPError.invalidResponse }
        return text
    }

    private func isMeaningfulReleaseBody(_ body: String) -> Bool {
        let lines = body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        guard lines.count == 1 else { return true }
        let normalized = lines[0].replacingOccurrences(of: "*", with: "").lowercased()
        return !(normalized.hasPrefix("full changelog:") && normalized.contains("github.com/") && normalized.contains("/compare/"))
    }

    private func comparisonMarkdown(_ comparison: GitHubComparison) -> String {
        var counts: [String: Int] = [:]
        var titlesInOrder: [String] = []
        for commit in comparison.commits {
            if counts[commit.title] == nil { titlesInOrder.append(commit.title) }
            counts[commit.title, default: 0] += 1
        }
        let entries = titlesInOrder.map { title -> String in
            let count = counts[title] ?? 1
            return "- \(title)\(count > 1 ? " × \(count)" : "")"
        }
        return "## Repository changes (\(comparison.commits.count) commits)\n\(entries.joined(separator: "\n"))"
    }
}
