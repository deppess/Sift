import Foundation

/// What a changelog is looked up for, from the catalog and the package's own metadata.
public struct ChangelogSubject: Sendable {
    public let item: CatalogItem
    /// The source URL Homebrew records for a formula or cask, when there is one.
    public let homebrewSourceURL: String?

    public init(item: CatalogItem, homebrewSourceURL: String? = nil) {
        self.item = item
        self.homebrewSourceURL = homebrewSourceURL
    }
}

public enum ChangelogResolution: Sendable {
    case resolved(source: String, sourceURL: String?, sourceKind: String, entries: [ChangelogEntry])
    /// Every place that was tried, in the user's words, and why each gave nothing.
    case unavailable([String])
    case failure(String)
}

/// Finds an item's changelog wherever its project keeps one, newest release first, as far back
/// as the source goes: a changelog file shipped with the package, the app's own update feed, the
/// App Store, Steam, Blackmagic, the project's GitHub releases or changelog file, or the
/// changelog page on its website. Placeholder text ("see our website") doesn't count; the next
/// source is tried instead.
public struct ChangelogResolver: Sendable {
    let client: MetadataHTTPClient
    let homeDirectory: String
    let storefront: String
    /// 100 releases a page; anonymous access has 60 requests an hour to spend.
    var githubPages: Int { client.hasGitHubToken ? 10 : 3 }
    /// Renders a script-built page to HTML (WebKit, in a child process); nil leaves such pages unread.
    let renderer: (@Sendable (URL) -> String?)?

    public init(
        client: MetadataHTTPClient, homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        storefront: String = Locale.current.region?.identifier.lowercased() ?? "us", environment: [String: String] = ProcessInfo.processInfo.environment,
        renderer: (@Sendable (URL) -> String?)? = nil
    ) {
        self.client = client
        self.renderer = renderer
        self.homeDirectory = homeDirectory
        self.storefront = storefront.count == 2 && storefront.allSatisfy(\.isLetter) ? storefront : "us"
    }

    public func resolve(_ subject: ChangelogSubject, preferredSourceKind: String? = nil, preferredSourceURL: String? = nil) -> ChangelogResolution {
        let resolution = resolveFromSources(subject, preferredSourceKind: preferredSourceKind, preferredSourceURL: preferredSourceURL)
        guard case let .resolved(source, sourceURL, sourceKind, entries) = resolution else { return resolution }
        return .resolved(source: source, sourceURL: sourceURL, sourceKind: sourceKind, entries: Self.deduplicated(entries))
    }

    /// One entry per version: a feed listing a release once per build (Miniconda's per-Python
    /// installers) keeps the first, with any different text from the others added.
    static func deduplicated(_ entries: [ChangelogEntry]) -> [ChangelogEntry] {
        var result: [ChangelogEntry] = []
        var positions: [String: Int] = [:]
        for entry in entries {
            guard let index = positions[entry.version] else {
                positions[entry.version] = result.count
                result.append(entry)
                continue
            }
            let kept = result[index]
            guard !kept.content.contains(entry.content) else { continue }
            let content = ChangelogDocument.isPlaceholder(kept.content) ? entry.content : kept.content + "\n\n" + entry.content
            result[index] = ChangelogEntry(
                version: kept.version, title: kept.title ?? entry.title, date: kept.date ?? entry.date, content: content,
                sourceURL: kept.sourceURL ?? entry.sourceURL)
        }
        return result
    }

    private func resolveFromSources(_ subject: ChangelogSubject, preferredSourceKind: String?, preferredSourceURL: String?) -> ChangelogResolution {
        var hints = Hints()
        hints.name = subject.item.name
        hints.installed = subject.item.installedVersion.map(ChangelogVersion.normalized)
        if let available = subject.item.availableVersion, available != subject.item.installedVersion { hints.latest = ChangelogVersion.normalized(available) }
        hints.commandLine = subject.item.kind == .homebrewFormula || subject.item.kind == .package
        gatherHints(subject, into: &hints)
        if let preferred = Source.cached(kind: preferredSourceKind, url: preferredSourceURL), hints.authorizes(preferred) {
            // A prior success is only a scheduling hint. The reconstructed source remains subject
            // to normal URL validation and discovery is retained as a fallback.
            hints.prioritize(preferred)
        }
        var tried: [String] = []
        var lastError: String?
        // A source that lists versions and dates without saying what changed (a feed with no
        // descriptions) is still a version history; it's used when nothing better turns up.
        var versionsOnly: (Source, [ChangelogEntry])?
        var partials: [Candidate] = []
        var extraTries = 0
        if client.debug { MetadataHTTPClient.trace("changelog sources for \(subject.item.selector): \(hints.sources.map(\.label).joined(separator: ", "))") }
        for source in hints.sources {
            do {
                let fetched = try fetch(source, hints: hints)
                // The app's own feed counts with a single version: it records each release as it appears.
                let versionCount = fetched.filter { ChangelogVersion.token(in: $0.version) == $0.version }.count
                if versionsOnly == nil,
                    versionCount >= 2
                        || versionCount == 1
                            && {
                                if case .sparkle = source { return true }; return false
                            }()
                {
                    versionsOnly = (source, fetched)
                }
                let entries = fetched.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if client.debug {
                    MetadataHTTPClient.trace(
                        "\(source.label): \(entries.count) entries, \(entries.filter { !ChangelogDocument.isPlaceholder($0.content) }.count) with real content")
                }
                if ChangelogDocument.isMeaningful(entries) {
                    // A versioned changelog without the installed version may be a partial one
                    // (a short ChangeLog in the package, a feed of recent releases): the next
                    // source or two may cover more, and the better one wins.
                    let versioned =
                        entries.filter { ChangelogVersion.token(in: $0.version) == $0.version }.count * 2 >= entries.count
                        && !ChangelogVersion.isCalendarDated(entries, installed: hints.installed)
                    // Covered means the installed version and, when there is an update, the update:
                    // a changelog file installed with the package stops at the installed version.
                    let coversInstalled =
                        (hints.installed.map { ChangelogVersion.installedIndex(in: entries, installed: $0) != nil } ?? true)
                        && (hints.latest.map { latest in
                            ChangelogVersion.installedIndex(in: entries, installed: latest) != nil
                                || entries.first.flatMap { ChangelogVersion.token(in: $0.version) }.map {
                                    SparkleVersion.compare($0, latest) != .orderedAscending
                                } ?? false
                        } ?? true)
                    // A feed of only the latest release or two, or releases mostly without text,
                    // is a start that the next source may extend.
                    let withText = entries.filter { !ChangelogDocument.isPlaceholder($0.content) }.count
                    let thin = entries.count < 3 || withText * 2 < entries.count
                    // The update's line counts as the item's too: going from 7 to 8.3, 8.x notes are its own.
                    let sameLine =
                        ChangelogVersion.sameLine(entries, installed: hints.installed) || hints.latest.map { ChangelogVersion.sameLine(entries, installed: $0) } == true
                    let candidate = Candidate(source: source, entries: entries, covers: coversInstalled, sameLine: sameLine, thin: thin)
                    if versioned, !coversInstalled || thin || !sameLine, extraTries < 2 {
                        partials.append(candidate)
                        if client.debug {
                            MetadataHTTPClient.trace(
                                "\(source.label) is partial (covers: \(coversInstalled), thin: \(thin), same line: \(sameLine)): \(entries.prefix(6).map(\.version).joined(separator: " "))"
                            )
                        }
                        extraTries += 1
                        tried.append(
                            "\(source.label): \(entries.count) versions\(sameLine ? (coversInstalled ? ", little text" : ", not the installed one") : " of another release line")"
                        )
                        continue
                    }
                    if !partials.isEmpty { return Self.combine(partials + [candidate]) }
                    return .resolved(source: source.label, sourceURL: source.url, sourceKind: source.cacheKind, entries: entries)
                }
                tried.append("\(source.label): \(entries.isEmpty ? "no versions found" : "only links elsewhere")")
            } catch MetadataHTTPError.notFound {
                tried.append("\(source.label): not found")
            } catch {
                lastError = error.localizedDescription
                tried.append("\(source.label): \(error.localizedDescription)")
            }
        }
        // Versions all from another release line are another product's (Zoom's homepage numbers,
        // LM Studio's page for its Bionic product): no changelog beats the wrong one.
        if partials.contains(where: \.sameLine) { return Self.combine(partials) }
        if let (source, entries) = versionsOnly {
            return .resolved(source: "\(source.label) (versions only)", sourceURL: source.url, sourceKind: source.cacheKind, entries: entries)
        }
        if tried.isEmpty { return .unavailable(["No changelog source is known for this item."]) }
        // A source that failed outright may have the changelog; that's worth retrying sooner.
        if let lastError, tried.allSatisfy({ !$0.hasSuffix(": not found") && !$0.hasSuffix("no versions found") && !$0.hasSuffix("only links elsewhere") }) {
            return .failure(lastError)
        }
        return .unavailable(tried)
    }

    /// A source's result that may be incomplete, kept while the next sources are tried.
    struct Candidate {
        let source: Source
        let entries: [ChangelogEntry]
        let covers: Bool
        let sameLine: Bool
        let thin: Bool

        var rank: Int { (sameLine ? 1_000_000 : 0) + (covers ? 100_000 : 0) + (thin ? 0 : 10_000) + entries.count }
    }

    /// The better of two results for the same item, merged when both are its own: the one
    /// covering the installed version leads, and the other fills in versions it lacks (a
    /// Sparkle feed of the latest release plus GitHub's history).
    static func combine(_ candidates: [Candidate]) -> ChangelogResolution {
        let ranked = candidates.sorted { $0.rank > $1.rank }
        guard let lead = ranked.first else { return .unavailable([]) }
        var entries = lead.entries
        var labels = [lead.source.label]
        // Same origin (two files of one repository, Emacs' NEWS and NEWS.30) is the same project
        // even when its versions are an older line.
        func origin(_ candidate: Candidate) -> String? {
            guard let url = candidate.source.url.flatMap(URL.init(string:)), let host = url.host?.lowercased() else { return nil }
            return ([host] + url.pathComponents.dropFirst().prefix(2)).joined(separator: "/")
        }
        for other in ranked.dropFirst() where lead.sameLine && (other.sameLine || origin(other) != nil && origin(other) == origin(lead)) {
            let merged = merge(entries, other.entries)
            if merged.count > entries.count { entries = merged; labels.append(other.source.label) }
        }
        return .resolved(source: labels.joined(separator: " and "), sourceURL: lead.source.url, sourceKind: lead.source.cacheKind, entries: entries)
    }

    static func combine(_ first: Candidate, _ second: Candidate) -> ChangelogResolution { combine([first, second]) }

    // MARK: - Sources

    enum Source: Equatable {
        case localFiles([URL])
        case sparkle(URL, padding: Bool)
        case appStore(bundleIdentifier: String)
        case steam(appID: String)
        case blackmagic(product: String)
        case githubReleases(GitHubRepository)
        case githubFile(GitHubRepository)
        case githubTags(GitHubRepository)
        /// A repository on a GitLab (gitlab.com, gitlab.gnome.org, …) or Forgejo/Gitea
        /// (codeberg.org, …) host: its releases, then its changelog file.
        case forge(host: String, path: String)
        /// A vendor's JSON update endpoint (from Homebrew's livecheck) that carries release notes.
        case updateFeed(URL)
        /// A feed of posts for several products, kept to the posts whose title has `title`, each
        /// versioned by the first version in its text (Chrome's releases blog).
        case filteredFeed(URL, title: String)
        /// One version's release-notes page at an address that follows a pattern (Firefox's
        /// /firefox/159.0/releasenotes/).
        case versionPages([VersionedURL])
        /// Eclipse Temurin's releases of one Java version, with the issues each fixes (Adoptium's API).
        case adoptium(major: Int)
        case page(URL)
        /// A page known to be the item's release notes, whatever its address says.
        case releaseNotes(URL)

        var label: String {
            switch self {
            case let .localFiles(urls): urls.count == 1 ? urls[0].lastPathComponent : "installed changelog files"
            case .sparkle: "the app's update feed"
            case .appStore: "the App Store"
            case .steam: "Steam news"
            case .blackmagic: "Blackmagic's downloads"
            case let .githubReleases(repository): "GitHub releases (\(repository.path))"
            case let .githubFile(repository): "changelog in \(repository.path)"
            case let .githubTags(repository): "GitHub tags and commits (\(repository.path))"
            case let .forge(host, path): "\(host)/\(path)"
            case let .updateFeed(url): "the update feed at \(url.host ?? "its vendor")"
            case let .filteredFeed(url, _): url.host ?? "the vendor's feed"
            case let .versionPages(pages): "\(pages.first?.url.host ?? "the vendor")'s release notes"
            case .adoptium: "Adoptium's release notes"
            case let .page(url), let .releaseNotes(url): url.host.map { "\($0)\(url.path.count > 1 ? url.path : "")" } ?? url.absoluteString
            }
        }

        var url: String? {
            switch self {
            case let .localFiles(urls): urls.first?.path
            case let .sparkle(url, _): url.absoluteString
            case .appStore, .blackmagic: nil
            case let .adoptium(major): "https://adoptium.net/temurin/release-notes/?version=\(major)"
            case let .steam(appID): "https://store.steampowered.com/news/app/\(appID)"
            case let .githubReleases(repository): "https://github.com/\(repository.path)/releases"
            case let .githubFile(repository), let .githubTags(repository): "https://github.com/\(repository.path)"
            case let .forge(host, path): "https://\(host)/\(path)"
            case let .updateFeed(url), let .filteredFeed(url, _): url.absoluteString
            case let .versionPages(pages): pages.first?.url.absoluteString
            case let .page(url), let .releaseNotes(url): url.absoluteString
            }
        }

        /// Stable, declarative source type stored in the local cache. It never contains parser
        /// code; cached data is reconstructed only into source types already implemented here.
        var cacheKind: String {
            switch self {
            case .localFiles: "local-files"
            case .sparkle: "sparkle"
            case .appStore: "app-store"
            case .steam: "steam"
            case .blackmagic: "blackmagic"
            case .githubReleases: "github-releases"
            case .githubFile: "github-file"
            case .githubTags: "github-tags"
            case .forge: "forge"
            case .updateFeed: "update-feed"
            case .filteredFeed: "filtered-feed"
            case .versionPages: "version-pages"
            case .adoptium: "adoptium"
            case .page: "page"
            case .releaseNotes: "release-notes"
            }
        }

        static func cached(kind: String?, url: String?) -> Source? {
            guard let kind, let url, let value = URL(string: url), isPublicHTTPSURL(value) else { return nil }
            switch kind {
            case "sparkle": return .sparkle(value, padding: true)
            case "update-feed": return .updateFeed(value)
            case "page": return .page(value)
            case "release-notes": return .releaseNotes(value)
            case "github-releases", "github-file", "github-tags":
                guard let repository = GitHubSource.parse(Hints.repositoryRoot(value))?.repository else { return nil }
                switch kind {
                case "github-releases": return .githubReleases(repository)
                case "github-file": return .githubFile(repository)
                default: return .githubTags(repository)
                }
            case "forge":
                guard let forge = Hints.forgeRepository(value) else { return nil }
                return .forge(host: forge.host, path: forge.path)
            default:
                // These source kinds need non-URL evidence (an app ID, title filter, or version
                // template), so they are rediscovered instead of broadening the trust boundary.
                return nil
            }
        }
    }

    struct Hints {
        var name = ""
        var installed: String?
        /// The available update, which a complete changelog must also cover.
        var latest: String?
        /// A command-line package (a formula, a cargo, npm, or uv tool), not an app.
        var commandLine = false
        private var ordered: [Source] = []
        private var repositories: [String] = []
        private var files: [URL] = []

        /// Installed changelog files first (read together, the best one wins), then every other
        /// source in the order found, with commit histories from tags last.
        var sources: [Source] {
            let tags = repositories.compactMap { path -> Source? in
                let parts = path.split(separator: "/").map(String.init)
                return parts.count == 2 ? .githubTags(GitHubRepository(owner: parts[0], name: parts[1])) : nil
            }
            return (files.isEmpty ? [] : [.localFiles(files)]) + ordered + tags
        }

        mutating func add(_ source: Source) {
            if case let .localFiles(urls) = source {
                for url in urls where !files.contains(url) { files.append(url) }
                return
            }
            if !ordered.contains(source) { ordered.append(source) }
        }

        mutating func prioritize(_ source: Source) {
            ordered.removeAll { $0 == source }
            ordered.insert(source, at: 0)
        }

        /// A cached URL is not authority by itself. It may only influence ordering when the
        /// current item independently produced the same source from its bundle/package metadata,
        /// provider record, or Sift's bundled source rules.
        func authorizes(_ candidate: Source) -> Bool {
            sources.contains { source in
                if case let (.sparkle(left, _), .sparkle(right, _)) = (source, candidate) { return left == right }
                return source == candidate
            }
        }

        /// A repository adds its releases first, then its changelog file.
        mutating func add(_ repository: GitHubRepository) {
            guard !repositories.contains(where: { $0.lowercased() == repository.path.lowercased() }) else { return }
            repositories.append(repository.path)
            add(.githubReleases(repository))
            add(.githubFile(repository))
        }

        /// A homepage or changelog link; a GitHub link counts as its repository.
        mutating func add(link: String?) {
            guard let link, let url = Self.normalizedURL(link) else { return }
            if let github = GitHubSource.parse(Self.repositoryRoot(url)) { add(github.repository); return }
            guard isPublicHTTPSURL(url) else { return }
            if let forge = Self.forgeRepository(url) { add(.forge(host: forge.host, path: forge.path)); return }
            // A GNU package's NEWS file in its Savannah repository (gnu.org/software/wget).
            if ["gnu.org", "www.gnu.org"].contains(url.host?.lowercased() ?? ""), let package = url.path.firstMatch(of: #/^/software/([a-z0-9_+-]+)/#)?.1,
                let news = URL(string: "https://cgit.git.savannah.gnu.org/cgit/\(package).git/plain/NEWS")
            {
                add(.releaseNotes(news))
            }
            add(.page(url))
        }

        static func normalizedURL(_ text: String) -> URL? {
            var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("git+") { value.removeFirst(4) }
            if value.hasPrefix("git://") { value = "https://" + value.dropFirst(6) }
            if value.hasPrefix("http://") { value = "https://" + value.dropFirst(7) }
            if value.hasPrefix("github:") { value = "https://github.com/" + value.dropFirst(7) }
            if value.hasPrefix("git@github.com:") { value = "https://github.com/" + value.dropFirst(15) }
            if value.hasSuffix(".git") { value.removeLast(4) }
            guard var components = URLComponents(string: value), components.scheme == "https", components.host != nil else { return nil }
            components.fragment = nil
            return components.url
        }

        /// A repository on a known GitLab or Forgejo host: gitlab.gnome.org/GNOME/librsvg(.git).
        static func forgeRepository(_ url: URL) -> (host: String, path: String)? {
            guard let host = url.host?.lowercased(), ChangelogResolver.forgeKinds[host] != nil || host.hasPrefix("gitlab.") else { return nil }
            var parts = url.path.split(separator: "/").map(String.init)
            if let dash = parts.firstIndex(of: "-") { parts = Array(parts[..<dash]) }
            guard parts.count >= 2 else { return nil }
            // gitlab.com allows subgroups (group/sub/project); Forgejo has owner/repo only.
            let kept =
                ChangelogResolver.forgeKinds[host] == .forgejo
                ? Array(parts.prefix(2)) : parts.prefix(4).filter { !["tree", "blob", "releases", "tags", "issues"].contains($0) }
            var path = kept.joined(separator: "/")
            if path.hasSuffix(".git") { path.removeLast(4) }
            return (host, path)
        }

        /// github.com/owner/repo/tree/main/docs reads as github.com/owner/repo.
        static func repositoryRoot(_ url: URL) -> URL {
            guard url.host?.lowercased() == "github.com" else { return url }
            let parts = url.path.split(separator: "/").prefix(2)
            guard parts.count == 2 else { return url }
            return URL(string: "https://github.com/\(parts.joined(separator: "/"))") ?? url
        }
    }

    func fetch(_ source: Source, hints: Hints) throws -> [ChangelogEntry] {
        switch source {
        case let .localFiles(urls): try localFiles(urls)
        case let .sparkle(url, padding): try sparkle(url, padding: padding)
        case let .appStore(bundleIdentifier): try appStore(bundleIdentifier)
        case let .steam(appID): try steamNews(appID)
        case let .blackmagic(product): try blackmagic(product)
        case let .githubReleases(repository): try githubHistory(repository, installed: hints.installed, name: hints.name, preferCLI: hints.commandLine)
        case let .githubFile(repository): try githubFile(repository)
        case let .githubTags(repository): try githubTags(repository, name: hints.name, preferCLI: hints.commandLine)
        case let .forge(host, path): try forge(host: host, path: path, name: hints.name)
        case let .updateFeed(url): try updateFeed(url, name: hints.name)
        case let .filteredFeed(url, title): try filteredFeed(url, title: title)
        case let .versionPages(pages): try versionPages(pages)
        case let .adoptium(major): try adoptium(major: major)
        case let .page(url): try page(url, name: hints.name, installed: hints.installed)
        case let .releaseNotes(url): try page(url, name: hints.name, installed: hints.installed, known: true)
        }
    }

    /// Entries from two sources for the same project, by version: the first source's text wins
    /// unless it is only a placeholder, and versions only the second has are added.
    static func merge(_ primary: [ChangelogEntry], _ secondary: [ChangelogEntry]) -> [ChangelogEntry] {
        var merged = primary
        // Each entry's version token, found once: comparing every pair would find it again each time.
        var tokens = merged.map { ChangelogVersion.token(in: $0.version) }
        for entry in secondary {
            let token = ChangelogVersion.token(in: entry.version)
            if let index = merged.indices.first(where: {
                ChangelogVersion.matches(merged[$0].version, token: tokens[$0], entry.version)
                    || ChangelogVersion.matches(entry.version, token: token, merged[$0].version)
            }) {
                if ChangelogDocument.isPlaceholder(merged[index].content) {
                    let old = merged[index]
                    merged[index] = ChangelogEntry(
                        version: old.version, title: old.title ?? entry.title, date: old.date ?? entry.date, content: entry.content,
                        sourceURL: entry.sourceURL ?? old.sourceURL)
                }
            } else {
                merged.append(entry)
                tokens.append(token)
            }
        }
        return newestFirst(merged, tokens: tokens)
    }

    /// Versioned entries newest first, then the rest in their order (a sort comparing only
    /// versioned pairs isn't a consistent ordering and scrambles mixed lists).
    static func newestFirst(_ entries: [ChangelogEntry]) -> [ChangelogEntry] {
        newestFirst(entries, tokens: entries.map { ChangelogVersion.token(in: $0.version) })
    }

    private static func newestFirst(_ entries: [ChangelogEntry], tokens: [String?]) -> [ChangelogEntry] {
        let versioned = entries.indices.compactMap { offset in tokens[offset].map { (offset, $0, entries[offset]) } }
        let sorted = versioned.sorted { left, right in
            let order = SparkleVersion.compare(left.1, right.1)
            return order == .orderedSame ? left.0 < right.0 : order == .orderedDescending
        }.map(\.2)
        let unversioned = entries.indices.filter { tokens[$0] == nil }.map { entries[$0] }
        return sorted + unversioned
    }

    func fetchText(_ url: URL, resource: MetadataResource) throws -> String {
        let data = try client.fetch(url, resource: resource).body
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// As many requests at once as the HTTP client allows, so the reading that follows finds
    /// them cached: which result is used, and in what order, stays the reader's. A failure isn't
    /// cached and is met again there.
    func warm(_ urls: [URL], resource: MetadataResource) {
        guard urls.count > 1 else { return }
        DispatchQueue.concurrentPerform(iterations: urls.count) { index in _ = try? client.fetch(urls[index], resource: resource) }
    }

    /// Requests a loop may stop early in, warmed a few at a time: ahead of the loop, but not far ahead.
    static let warmBatch = 6
}
