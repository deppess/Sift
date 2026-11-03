import Foundation

// Changelogs from source repositories: GitHub's releases, tags, and files, and other forges'.
extension ChangelogResolver {
    // MARK: GitHub

    func githubReleases(_ repository: GitHubRepository, name currentName: String = "", preferCLI: Bool = false, prereleases: Bool = false) throws
        -> [ChangelogEntry]
    {
        guard let owner = encodeGitHubPathComponent(repository.owner), let name = encodeGitHubPathComponent(repository.name) else {
            throw MetadataHTTPError.unsupportedURL
        }
        var entries: [ChangelogEntry] = []
        // With a token, GraphQL answers with only the fields read below; REST's lists carry every
        // release's assets too (gh's 210 releases: 7 MB). REST stays the fallback.
        let listed = client.hasGitHubToken ? try? githubGraphQLReleases(repository) : nil
        for page in 1...githubPages {
            var releases = listed ?? []
            if listed == nil {
                let url = URL(string: "https://api.github.com/repos/\(owner)/\(name)/releases?per_page=100&page=\(page)")!
                let data: Data
                do { data = try client.fetch(url, resource: .githubReleaseList).body } catch  where page > 1 { break } catch MetadataHTTPError.serverFailure {
                    // A page of 100 long release notes can time out on GitHub's side (openai/codex): a
                    // smaller first page still answers.
                    let smaller = URL(string: "https://api.github.com/repos/\(owner)/\(name)/releases?per_page=30")!
                    guard let retried = try? client.fetch(smaller, resource: .githubReleaseList).body else {
                        throw MetadataHTTPError.serverFailure(statusCode: 504)
                    }
                    data = retried
                } catch MetadataHTTPError.rateLimited, MetadataHTTPError.forbidden {
                    // Out of API quota: the releases feed has the latest ten without spending any.
                    let feed = URL(string: "https://github.com/\(owner)/\(name)/releases.atom")!
                    // The feed lists pre-releases and drafts too; only versioned releases of this item stay.
                    let items = ChangelogFeeds.entries(fromFeed: try client.fetch(feed, resource: .changelogPage).body)
                        .filter {
                            ChangelogVersion.token(in: $0.version) == $0.version
                                && $0.version.range(of: #"(?i)(alpha|beta|rc|pre|dev|nightly)"#, options: .regularExpression) == nil
                        }
                    return Self.ownProductReleases(items, name: currentName, preferCLI: preferCLI, repository: repository.path)
                }
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw MetadataHTTPError.invalidResponse }
                releases = parsed
            }
            for release in releases where release["draft"] as? Bool != true && (prereleases || release["prerelease"] as? Bool != true) {
                guard let tag = release["tag_name"] as? String else { continue }
                let title = (release["name"] as? String)?.trimmingCharacters(in: .whitespaces)
                let version = ChangelogVersion.token(in: tag) ?? title.flatMap(ChangelogVersion.token(in:)) ?? tag
                let date = (release["published_at"] as? String).flatMap { ChangelogDocument.isoDate($0) }
                var body = ChangelogDocument.tidy((release["body"] as? String) ?? "")
                // Some projects paste their whole changelog file into every release.
                let sections = ChangelogDocument.entries(fromMarkdown: body, sourceURL: nil)
                if sections.count > 1, let own = sections.first(where: { ChangelogVersion.matches($0.version, version) }) { body = own.content }
                // "GitHub CLI 2.103.3" says nothing the version doesn't; "Christmas release" does.
                let titled = title.flatMap { $0.contains(version) || $0 == tag ? nil : $0.nonEmpty }
                entries.append(
                    ChangelogEntry(
                        version: version, title: titled, date: date, content: body,
                        sourceURL: release["html_url"] as? String ?? "https://github.com/\(repository.path)/releases/tag/\(tag)"))
            }
            if listed != nil || releases.count < 100 { break }
        }
        return Self.ownProductReleases(entries, name: currentName, preferCLI: preferCLI, repository: repository.path)
    }

    /// A repository's releases from GitHub's GraphQL API, newest first, under the names its REST
    /// API uses. A later page that fails ends the list there, as with REST.
    private func githubGraphQLReleases(_ repository: GitHubRepository) throws -> [[String: Any]] {
        let query = """
            query($owner: String!, $name: String!, $after: String) { repository(owner: $owner, name: $name) {
            releases(first: 100, after: $after, orderBy: {field: CREATED_AT, direction: DESC}) {
            pageInfo { hasNextPage endCursor } nodes { tagName name publishedAt description url isDraft isPrerelease } } } }
            """
        let url = URL(string: "https://api.github.com/graphql")!
        var releases: [[String: Any]] = []
        var cursor: String?
        for page in 1...githubPages {
            let variables: [String: Any] = ["owner": repository.owner, "name": repository.name, "after": cursor ?? NSNull()]
            let list: [String: Any]
            do {
                let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables], options: .sortedKeys)
                let document = try JSONSerialization.jsonObject(with: client.fetch(url, resource: .githubReleaseList, body: body).body) as? [String: Any]
                guard document?["errors"] == nil,
                    let found = ((document?["data"] as? [String: Any])?["repository"] as? [String: Any])?["releases"] as? [String: Any]
                else { throw MetadataHTTPError.invalidResponse }
                list = found
            } catch  where page > 1 { break }
            for node in list["nodes"] as? [[String: Any]] ?? [] {
                releases.append([
                    "tag_name": node["tagName"] as Any, "name": node["name"] as Any, "published_at": node["publishedAt"] as Any,
                    "body": node["description"] as Any, "html_url": node["url"] as Any, "draft": node["isDraft"] as Any,
                    "prerelease": node["isPrerelease"] as Any
                ])
            }
            let info = list["pageInfo"] as? [String: Any]
            guard info?["hasNextPage"] as? Bool == true, let next = info?["endCursor"] as? String else { break }
            cursor = next
        }
        return releases
    }

    /// In a repository that releases several products (golang/tools' gopls/v0.17, taplo's
    /// release-taplo-cli-0.9, bash-language-server's vscode-client-1.0), the releases whose tag
    /// prefix names this item; with no prefix naming it, only the unprefixed tags.
    static func ownProductReleases(_ entries: [ChangelogEntry], name: String, preferCLI: Bool = false, repository: String = "") -> [ChangelogEntry] {
        func prefix(_ entry: ChangelogEntry) -> String {
            guard let tag = entry.sourceURL?.components(separatedBy: "/releases/tag/").dropFirst().first?.removingPercentEncoding else { return "" }
            return BundleURLScanner.matchKey(String(tag.prefix { !$0.isNumber }).replacingOccurrences(of: "release", with: ""))
                .replacing(#/v$/#, with: "")
        }
        let groups = Dictionary(grouping: entries, by: prefix)
        let key = BundleURLScanner.matchKey(name)
        // One kind of tag: unprefixed, or named for this item, is all the item's; one named for
        // something else (only gopls/ tags, for goimports) isn't.
        // A prefix that is a language or a generic word (Codex's rust-v0.166.0) isn't another product.
        let generic: Set<String> = [
            "rust", "go", "py", "python", "node", "js", "ts", "swift", "cli", "app", "desktop", "stable", "main", "core", "release", "macos", "mac"
        ]
        if groups.count == 1, let only = groups.keys.first {
            // A prefix naming the repository itself is its own (llvm/llvm-project's llvmorg-21.1.5).
            let repositoryKeys = repository.split(separator: "/").map { BundleURLScanner.matchKey(String($0)) }.filter { $0.count >= 3 }
            let own = only.isEmpty || key.isEmpty || key.contains(only) || only.contains(key) || generic.contains(only)
            return own || repositoryKeys.contains(where: only.contains) ? entries : []
        }
        let named = groups.keys.filter { !$0.isEmpty && (key.contains($0) || $0.contains(key)) }
        // The closest name: "server" for bash-language-server; for a command-line package, the
        // CLI's tags ("taplocli") over the library's ("taplo").
        let best = named.max { a, b in
            let score = { (p: String) in (preferCLI && p.contains("cli") ? 200 : 0) + (p == key ? 100 : 0) + p.count }
            return score(a) < score(b)
        }
        // Unprefixed tags are the repository's main product and stay with the chosen group;
        // other products' prefixed tags go.
        // Platform words (bitwarden/clients' cli-v and desktop-v) are products of their own: the
        // one matching what's installed is kept, not all of them.
        let platforms = ["cli", "desktop", "macos", "mac", "app"]
        let presentPlatforms = platforms.filter { groups[$0] != nil }
        let chosenPlatform =
            presentPlatforms.count > 1
            ? (preferCLI ? presentPlatforms.first { $0 == "cli" } : presentPlatforms.first { $0 != "cli" }) ?? presentPlatforms[0] : nil
        let genericGroups = groups.filter { generic.contains($0.key) && (chosenPlatform == nil || !platforms.contains($0.key) || $0.key == chosenPlatform) }
            .values.flatMap { $0 }
        let kept = (best.map { groups[$0] ?? [] } ?? []) + (groups[""] ?? []) + (best == nil ? genericGroups : [])
        return kept.sorted(by: ChangelogVersion.isNewer)
    }

    /// Releases that go back a while, mostly with notes, need no changelog file to fill them in;
    /// old releases without notes (kitty's) are filled from it.
    private static func releasesSuffice(_ releases: [ChangelogEntry]) -> Bool {
        releases.count >= 30 && releases.filter { !ChangelogDocument.isPlaceholder($0.content) }.count * 10 >= releases.count * 8
    }

    /// A repository's releases, with its changelog file filling in versions the releases don't
    /// cover (projects that started publishing releases late, or skip some).
    func githubHistory(_ repository: GitHubRepository, installed: String?, name: String = "", preferCLI: Bool = false) throws -> [ChangelogEntry] {
        // A pre-release installed (PowerShell Preview's 7.7.0-rc.1) is documented among the pre-releases.
        let installedPrerelease = installed?.range(of: #"(?i)(alpha|beta|rc|preview|pre)"#, options: .regularExpression) != nil
        let releases = try githubReleases(repository, name: name, preferCLI: preferCLI, prereleases: installedPrerelease)
        let coversInstalled = installed.map { ChangelogVersion.installedIndex(in: releases, installed: $0) != nil } ?? true
        if coversInstalled, Self.releasesSuffice(releases) { return releases }
        let file = (try? githubFile(repository)) ?? []
        guard !file.isEmpty else { return releases }
        return Self.merge(releases, file)
    }

    /// For a repository with no releases and no changelog: its version tags, newest first, each
    /// with the commits since the tag before it (for the newest few; GitHub's anonymous quota is
    /// small).
    func githubTags(_ repository: GitHubRepository, name itemName: String = "", preferCLI: Bool = false) throws -> [ChangelogEntry] {
        guard let owner = encodeGitHubPathComponent(repository.owner), let name = encodeGitHubPathComponent(repository.name) else {
            throw MetadataHTTPError.unsupportedURL
        }
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(name)/tags?per_page=100")!
        guard let tags = try JSONSerialization.jsonObject(with: client.fetch(url, resource: .githubReleaseList).body) as? [[String: Any]] else {
            throw MetadataHTTPError.invalidResponse
        }
        let versioned = tags.compactMap { tag -> (name: String, version: String, sha: String)? in
            guard let name = tag["name"] as? String, let version = ChangelogVersion.token(in: name),
                let sha = (tag["commit"] as? [String: Any])?["sha"] as? String
            else { return nil }
            return (name, version, sha)
        }.sorted { SparkleVersion.compare($0.version, $1.version) == .orderedDescending }
        let described = githubPages > 3 ? 12 : 4
        let compares = versioned.indices.map { index -> URL? in
            guard index < described, index + 1 < versioned.count, let base = encodeGitHubPathComponent(versioned[index + 1].sha),
                let head = encodeGitHubPathComponent(versioned[index].sha)
            else { return nil }
            return URL(string: "https://api.github.com/repos/\(owner)/\(name)/compare/\(base)...\(head)")
        }
        warm(compares.compactMap { $0 }, resource: .githubReleaseList)
        var entries: [ChangelogEntry] = []
        for (index, tag) in versioned.enumerated() {
            var content = ""
            var date: Date?
            if let compare = compares[index], let data = try? client.fetch(compare, resource: .githubReleaseList).body,
                let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let commits = document["commits"] as? [[String: Any]]
            {
                let messages = commits.compactMap { (($0["commit"] as? [String: Any])?["message"] as? String)?.split(separator: "\n").first.map(String.init) }
                    .filter { !$0.lowercased().hasPrefix("merge ") }
                content = messages.reversed().map { "- \($0)" }.joined(separator: "\n")
                date = ((commits.last?["commit"] as? [String: Any])?["committer"] as? [String: Any])?["date"].flatMap { $0 as? String }.flatMap {
                    ChangelogDocument.isoDate($0)
                }
            }
            entries.append(
                ChangelogEntry(
                    version: tag.version, title: nil, date: date, content: content, sourceURL: "https://github.com/\(repository.path)/releases/tag/\(tag.name)")
            )
        }
        // Pre-release tags (Codex's 0.166.0-alpha.6) go when there are releases.
        let own = Self.ownProductReleases(entries, name: itemName, preferCLI: preferCLI, repository: repository.path)
        let stable = own.filter { $0.version.range(of: #"(?i)(alpha|beta|rc|pre|dev|nightly)"#, options: .regularExpression) == nil }
        return stable.isEmpty ? own : stable
    }

    enum ForgeKind { case gitlab, forgejo }
    static let forgeKinds: [String: ForgeKind] = [
        "gitlab.com": .gitlab, "gitlab.gnome.org": .gitlab, "gitlab.freedesktop.org": .gitlab, "invent.kde.org": .gitlab,
        "salsa.debian.org": .gitlab, "gitlab.archlinux.org": .gitlab, "framagit.org": .gitlab, "gitlab.torproject.org": .gitlab,
        "codeberg.org": .forgejo, "gitea.com": .forgejo
    ]

    /// A GitLab or Forgejo repository's releases (with the changelog file filling gaps, as for
    /// GitHub), or its changelog file alone.
    func forge(host: String, path: String, name: String) throws -> [ChangelogEntry] {
        let kind = Self.forgeKinds[host] ?? .gitlab
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path
        let api =
            kind == .gitlab ? "https://\(host)/api/v4/projects/\(encoded)/releases?per_page=100" : "https://\(host)/api/v1/repos/\(path)/releases?limit=50"
        var releases: [ChangelogEntry] = []
        if let url = URL(string: api), let data = try? client.fetch(url, resource: .changelogPage).body,
            let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        {
            for release in list
            where release["draft"] as? Bool != true && release["prerelease"] as? Bool != true && release["upcoming_release"] as? Bool != true {
                guard let tag = release["tag_name"] as? String, let version = ChangelogVersion.token(in: tag) else { continue }
                let body = (release["description"] as? String) ?? (release["body"] as? String) ?? ""
                let date = ((release["released_at"] ?? release["published_at"] ?? release["created_at"]) as? String).flatMap {
                    ChangelogDocument.isoDate($0.replacing(#/\.\d+/#, with: ""))
                }
                releases.append(
                    ChangelogEntry(
                        version: version, title: nil, date: date, content: ChangelogDocument.tidy(body),
                        sourceURL: "https://\(host)/\(path)/\(kind == .gitlab ? "-/" : "")releases/tag/\(tag)"))
            }
        }
        releases = Self.ownProductReleases(releases, name: name, repository: path)
        if Self.releasesSuffice(releases) { return releases }
        let rawURL = { (file: String) in kind == .gitlab ? "https://\(host)/\(path)/-/raw/HEAD/\(file)" : "https://\(host)/\(path)/raw/branch/main/\(file)" }
        for (offset, file) in Self.repositoryChangelogPaths.enumerated() {
            let raw = rawURL(file)
            if offset % Self.warmBatch == 0 {
                warm(Self.repositoryChangelogPaths.dropFirst(offset).prefix(Self.warmBatch).compactMap { URL(string: rawURL($0)) }, resource: .changelogPage)
            }
            guard let url = URL(string: raw) else { continue }
            let text: String
            do { text = try fetchText(url, resource: .changelogPage) } catch MetadataHTTPError.notFound { continue } catch { break }
            // A missing file can come back as the forge's sign-in or error page.
            guard !text.lowercased().contains("<html") else { continue }
            let entries = ChangelogDocument.entries(fromMarkdown: text, sourceURL: raw)
            if !entries.isEmpty { return releases.isEmpty ? entries : Self.merge(releases, entries) }
        }
        return releases
    }

    // Raw file paths are case-sensitive, so the common spellings are each tried (a missing one
    // is a cached 404, and raw files don't count against the API quota).
    private static let repositoryChangelogPaths = [
        "CHANGELOG.md", "ChangeLog.md", "Changelog.md", "changelog.md", "CHANGES.md", "Changes.md", "HISTORY.md", "History.md", "NEWS.md", "RELEASES.md",
        "RELEASE_NOTES.md", "RELEASE-NOTES.md", "CHANGELOG", "ChangeLog", "Changelog", "CHANGES", "NEWS", "HISTORY", "docs/changelog.md", "docs/CHANGELOG.md",
        "docs/CHANGES.md", "CHANGELOG.rst", "CHANGES.rst", "HISTORY.rst", "NEWS.rst", "docs/changelog.rst", "CHANGELOG.txt", "NEWS.txt"
    ]

    func githubFile(_ repository: GitHubRepository) throws -> [ChangelogEntry] {
        guard let owner = encodeGitHubPathComponent(repository.owner), let name = encodeGitHubPathComponent(repository.name) else {
            throw MetadataHTTPError.unsupportedURL
        }
        let rawURL = { (path: String) in URL(string: "https://raw.githubusercontent.com/\(owner)/\(name)/HEAD/\(path)")! }
        for (offset, path) in Self.repositoryChangelogPaths.enumerated() {
            let url = rawURL(path)
            // Most spellings are missing, and each miss was a round trip of its own.
            if offset % Self.warmBatch == 0 {
                warm(Self.repositoryChangelogPaths.dropFirst(offset).prefix(Self.warmBatch).map(rawURL), resource: .githubChangelog)
            }
            let text: String
            do { text = try fetchText(url, resource: .githubChangelog) } catch MetadataHTTPError.notFound { continue }
            let entries = ChangelogDocument.entries(fromMarkdown: text, sourceURL: "https://github.com/\(repository.path)/blob/HEAD/\(path)")
            if !entries.isEmpty { return entries }
        }
        return []
    }
}
