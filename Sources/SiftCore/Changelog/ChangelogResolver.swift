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
    case resolved(source: String, sourceURL: String?, entries: [ChangelogEntry])
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
    private let client: MetadataHTTPClient
    private let homeDirectory: String
    private let storefront: String
    /// 100 releases a page; anonymous access has 60 requests an hour to spend.
    private var githubPages: Int { client.hasGitHubToken ? 10 : 3 }
    /// Renders a script-built page to HTML (WebKit, in a child process); nil leaves such pages unread.
    private let renderer: (@Sendable (URL) -> String?)?

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

    public func resolve(_ subject: ChangelogSubject) -> ChangelogResolution {
        let resolution = resolveFromSources(subject)
        guard case let .resolved(source, sourceURL, entries) = resolution else { return resolution }
        return .resolved(source: source, sourceURL: sourceURL, entries: Self.deduplicated(entries))
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

    private func resolveFromSources(_ subject: ChangelogSubject) -> ChangelogResolution {
        var hints = Hints()
        hints.name = subject.item.name
        hints.installed = subject.item.installedVersion.map(ChangelogVersion.normalized)
        if let available = subject.item.availableVersion, available != subject.item.installedVersion { hints.latest = ChangelogVersion.normalized(available) }
        hints.commandLine = subject.item.kind == .homebrewFormula || subject.item.kind == .package
        gatherHints(subject, into: &hints)
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
                    let sameLine = ChangelogVersion.sameLine(entries, installed: hints.installed)
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
                    return .resolved(source: source.label, sourceURL: source.url, entries: entries)
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
        if let (source, entries) = versionsOnly { return .resolved(source: "\(source.label) (versions only)", sourceURL: source.url, entries: entries) }
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
        return .resolved(source: labels.joined(separator: " and "), sourceURL: lead.source.url, entries: entries)
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

    private func fetch(_ source: Source, hints: Hints) throws -> [ChangelogEntry] {
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

    // MARK: Local files

    private static let changelogFileNames = [
        "changelog", "changes", "history", "news", "releases", "release-notes", "release_notes", "releasenotes", "release notes", "whatsnew", "whats-new",
        "whats new"
    ]
    private static let changelogExtensions = ["", "md", "markdown", "txt", "rst", "html", "htm"]

    /// Changelog files inside an app bundle's resources (Tor Browser keeps one in
    /// Resources/TorBrowser/Docs), up to three folders deep.
    static func bundleChangelogFiles(_ bundlePath: String) -> [URL] {
        let resources = URL(filePath: bundlePath).appending(path: "Contents/Resources", directoryHint: .isDirectory)
        guard
            let enumerator = FileManager.default.enumerator(
                at: resources, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var found: [URL] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > 20_000 { break }
            if enumerator.level > 3 { enumerator.skipDescendants(); continue }
            let base = url.deletingPathExtension().lastPathComponent.lowercased()
            guard changelogFileNames.contains(base), changelogExtensions.contains(url.pathExtension.lowercased()),
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
                (values.fileSize ?? .max) <= 8 * 1_048_576
            else { continue }
            found.append(url)
        }
        return found
    }

    /// Changelog files a package shipped in `directory` or its doc folders.
    static func changelogFiles(in directory: URL) -> [URL] {
        var found: [URL] = []
        for folder in [directory, directory.appending(path: "doc"), directory.appending(path: "docs")] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names.sorted() {
                let url = folder.appending(path: name)
                let base = url.deletingPathExtension().lastPathComponent.lowercased()
                guard changelogFileNames.contains(base), changelogExtensions.contains(url.pathExtension.lowercased()),
                    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
                    (values.fileSize ?? .max) <= 8 * 1_048_576
                else { continue }
                found.append(url)
            }
        }
        // CHANGELOG before NEWS or HISTORY: it's the one most often kept current.
        return found.sorted {
            changelogFileNames.firstIndex(of: $0.deletingPathExtension().lastPathComponent.lowercased())! < changelogFileNames.firstIndex(
                of: $1.deletingPathExtension().lastPathComponent.lowercased())!
        }
    }

    /// The best of the installed changelog files: the one with the installed version, then the
    /// one with the most versions (a git-log ChangeLog loses to a release-by-release NEWS).
    private func localFiles(_ urls: [URL]) throws -> [ChangelogEntry] {
        let parsed = urls.map { url -> [ChangelogEntry] in
            guard let data = try? Data(contentsOf: url) else { return [] }
            let text = String(decoding: data, as: UTF8.self)
            return ["html", "htm"].contains(url.pathExtension.lowercased())
                ? Self.pageEntries(text, url: url) : ChangelogDocument.entries(fromMarkdown: text, sourceURL: nil)
        }
        // The fullest file leads and the others fill in what it lacks (Bash's CHANGES stops at
        // 5.3-rc2; its NEWS has 5.3 itself).
        let ordered = parsed.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        guard let lead = ordered.first else { return [] }
        return ordered.dropFirst().reduce(lead) { Self.merge($0, $1) }
    }

    // MARK: Sparkle

    private func sparkle(_ url: URL, padding: Bool) throws -> [ChangelogEntry] {
        guard let host = url.host?.lowercased() else { throw MetadataHTTPError.unsupportedURL }
        let items = try SparkleAppcastParser.parse(client.fetch(url, resource: .sparkleAppcast(host: host)).body)
            .filter(\.isDefaultChannel)
            .sorted { SparkleVersion.compare($0.version, $1.version, padding: padding) == .orderedDescending }
        var entries: [ChangelogEntry] = []
        var linkedPages = 0
        var linkedSplit: [ChangelogEntry]?
        for item in items {
            var content = item.releaseNotesHTML.map { HTMLMarkdown.convert($0) } ?? ""
            var source: String?
            // A feed that only links to its notes: the linked page, for the newest releases.
            // The link is the item's releaseNotesLink, or one inside the placeholder text itself.
            let embedded = item.releaseNotesHTML.flatMap { html in HTMLMarkdown.links(in: html, base: url).first?.url }
            if ChangelogDocument.isPlaceholder(content), let linkedSplit,
                let own = linkedSplit.first(where: { ChangelogVersion.matches($0.version, ChangelogVersion.normalized(item.displayVersion)) })
            {
                content = own.content
            } else if ChangelogDocument.isPlaceholder(content), linkedPages < 12,
                let link = item.releaseNotesURL.flatMap(URL.init(string:)) ?? embedded, isPublicHTTPSURL(link), let linkHost = link.host
            {
                linkedPages += 1
                if let html = try? fetchText(link, resource: .changelogPage(host: linkHost)) {
                    // A page that covers every version is split, and this version's part kept;
                    // a script-built page is rendered first.
                    let split = read(html, url: link, render: true)
                    let itemVersion = ChangelogVersion.normalized(item.displayVersion)
                    // This version's own section, or the newest section that says it covers later versions.
                    let own =
                        split.first { ChangelogVersion.matches($0.version, itemVersion) }?.content
                        ?? split.first(where: {
                            $0.title == ChangelogDocument.cumulativeTitle
                                && ChangelogVersion.token(in: $0.version).map { SparkleVersion.compare($0, itemVersion) != .orderedDescending } ?? false
                        })?.content
                    let whole = HTMLMarkdown.convert(html)
                    // One entry for a different version (iTerm2 links every item to the latest
                    // release's notes) isn't this item's; an unversioned page is.
                    // A single section for an older version is cumulative ("BetterTouchTool >= 6.943"
                    // for 6.990) and applies; one for a newer version doesn't.
                    let single: String? = {
                        guard split.count == 1 else { return nil }
                        guard let token = ChangelogVersion.token(in: split[0].version) else { return split[0].content }
                        return SparkleVersion.compare(token, ChangelogVersion.normalized(item.displayVersion)) != .orderedDescending ? split[0].content : nil
                    }()
                    let unsplit = split.isEmpty && !ChangelogDocument.isPlaceholder(whole) ? whole : nil
                    content = own ?? single ?? unsplit ?? content
                    source = link.absoluteString
                    // Older items in the same feed usually link to the same page.
                    if split.count > 1 { linkedSplit = split }
                } else if let linkedSplit,
                    let own = linkedSplit.first(where: { ChangelogVersion.matches($0.version, ChangelogVersion.normalized(item.displayVersion)) })
                {
                    content = own.content
                }
            }
            entries.append(ChangelogEntry(version: item.displayVersion, date: item.publishedAt.flatMap(Self.rfc822Date), content: content, sourceURL: source))
        }
        // The notes page the feed links to usually covers every version (Cyberduck's,
        // Postman's): its older sections fill in the history the feed no longer lists.
        if let linkedSplit, linkedSplit.count > entries.count, ChangelogDocument.isMeaningful(linkedSplit) { entries = Self.merge(entries, linkedSplit) }
        // A full-history page fills in the versions the feed itself no longer lists.
        if let full = items.lazy.compactMap({ $0.fullReleaseNotesURL?.trimmingCharacters(in: .whitespacesAndNewlines) }).compactMap(URL.init(string:)).first,
            isPublicHTTPSURL(full), let fullHost = full.host,
            let text = try? fetchText(full, resource: .changelogPage(host: fullHost))
        {
            let history = read(text, url: full, render: true)
            if ChangelogDocument.isMeaningful(history) { return Self.merge(entries, history) }
        }
        return entries
    }

    static func rfc822Date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in [
            "EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text.trimmingCharacters(in: .whitespaces)) { return date }
        }
        return ChangelogDocument.date(in: text)
    }

    // MARK: App Store

    private func appStore(_ bundleIdentifier: String) throws -> [ChangelogEntry] {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleIdentifier), URLQueryItem(name: "country", value: storefront),
            URLQueryItem(name: "entity", value: "macSoftware")
        ]
        let data = try client.fetch(components.url!, resource: .appStoreLookup).body
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any], let results = document["results"] as? [[String: Any]],
            let listing = results.first(where: { $0["bundleId"] as? String == bundleIdentifier && $0["kind"] as? String == "mac-software" })
                ?? results.first(where: { $0["bundleId"] as? String == bundleIdentifier })
        else { throw MetadataHTTPError.notFound }
        let storeURL = (listing["trackViewUrl"] as? String).flatMap(URL.init(string:))
        // The listing page carries the version history; the lookup only the latest release.
        if let storeURL, storeURL.host?.lowercased() == "apps.apple.com", let html = try? fetchText(storeURL, resource: .appStorePage) {
            let history = Self.appStoreHistory(html)
            if ChangelogDocument.isMeaningful(history) { return history }
        }
        guard let version = listing["version"] as? String else { return [] }
        let date = (listing["currentVersionReleaseDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return [ChangelogEntry(version: version, date: date, content: (listing["releaseNotes"] as? String) ?? "", sourceURL: storeURL?.absoluteString)]
    }

    /// Version history from the JSON an App Store page embeds: every object holding release
    /// notes beside a version string.
    static func appStoreHistory(_ html: String) -> [ChangelogEntry] {
        var entries: [ChangelogEntry] = []
        var seen = Set<String>()
        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                let version = (dictionary["versionDisplay"] ?? dictionary["primarySubtitle"] ?? dictionary["versionString"] ?? dictionary["version"]) as? String
                let notes = (dictionary["releaseNotes"] ?? dictionary["notes"] ?? dictionary["text"]) as? String
                if let version, ChangelogVersion.token(in: version) != nil, let notes, !notes.isEmpty, seen.insert(version).inserted {
                    let dateText = (dictionary["releaseDate"] ?? dictionary["date"] ?? dictionary["secondarySubtitle"]) as? String
                    let date = dateText.flatMap { ISO8601DateFormatter().date(from: $0) ?? ChangelogDocument.date(in: $0) }
                    entries.append(ChangelogEntry(version: ChangelogVersion.token(in: version) ?? version, date: date, content: notes))
                }
                dictionary.values.forEach(walk)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        for match in html.matches(of: #/(?is)<script[^>]*type\s*=\s*["']application/(?:ld\+)?json["'][^>]*>(.*?)</script>/#) {
            guard let data = HTMLText.decodeEntities(String(match.1)).data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }
            walk(json)
        }
        return entries.sorted { SparkleVersion.compare($0.version, $1.version) == .orderedDescending }
    }

    // MARK: Steam

    private func steamNews(_ appID: String) throws -> [ChangelogEntry] {
        guard appID.allSatisfy(\.isNumber) else { throw MetadataHTTPError.unsupportedURL }
        // Steam's own client posts its update notes to its blog feed, not as announcements.
        let feeds = appID == "593110" ? "" : "&feeds=steam_community_announcements"
        let url = URL(string: "https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/?appid=\(appID)&count=100&maxlength=0&format=json\(feeds)")!
        guard let document = try JSONSerialization.jsonObject(with: client.fetch(url, resource: .steamNews).body) as? [String: Any],
            let news = (document["appnews"] as? [String: Any])?["newsitems"] as? [[String: Any]]
        else { throw MetadataHTTPError.invalidResponse }
        let items = news.compactMap { item -> (entry: ChangelogEntry, patch: Bool)? in
            guard let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                let contents = item["contents"] as? String
            else { return nil }
            let date = (item["date"] as? Double).map(Date.init(timeIntervalSince1970:))
            let tags = (item["tags"] as? [String]) ?? []
            let lower = title.lowercased()
            let patch =
                tags.contains("patchnotes")
                || ["patch", "update", "hotfix", "fix", "release notes", "changelog", "version", "build"].contains { lower.contains($0) }
                || ChangelogVersion.token(in: title) != nil
            return (
                ChangelogEntry(
                    version: title, title: nil, date: date, content: ChangelogDocument.markdown(fromBBCode: contents), sourceURL: item["url"] as? String), patch
            )
        }
        // Patch notes when the game posts them; every announcement otherwise.
        let patches = items.filter(\.patch).map(\.entry)
        return patches.isEmpty ? items.map(\.entry) : patches
    }

    // MARK: Blackmagic

    private func blackmagic(_ product: String) throws -> [ChangelogEntry] {
        let data = try client.fetch(BlackmagicDownloads.url, resource: .blackmagicDownloads).body
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any], let downloads = document["downloads"] as? [[String: Any]] else {
            throw MetadataHTTPError.invalidResponse
        }
        var entries: [(ChangelogEntry, (Int, Int, Int))] = []
        for download in downloads {
            guard let name = download["name"] as? String, !name.localizedCaseInsensitiveContains("beta"),
                let urls = download["urls"] as? [String: Any], let mac = urls["Mac OS X"] as? [[String: Any]],
                let release = mac.first(where: { $0["product"] as? String == product }),
                let major = release["major"] as? Int, let minor = release["minor"] as? Int
            else { continue }
            let number = (major, minor, release["releaseNum"] as? Int ?? 0)
            let version = number.2 == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(number.2)"
            let html = (download["desc"] as? String) ?? ""
            let date = (download["date"] as? String).flatMap { ChangelogDocument.date(in: $0) ?? Self.rfc822Date($0) }
            entries.append((ChangelogEntry(version: version, title: name, date: date, content: HTMLMarkdown.convert(html)), number))
        }
        return entries.sorted { $0.1 > $1.1 }.map(\.0)
    }

    // MARK: GitHub

    private func githubReleases(_ repository: GitHubRepository, name currentName: String = "", preferCLI: Bool = false, prereleases: Bool = false) throws
        -> [ChangelogEntry]
    {
        guard let owner = encodeGitHubPathComponent(repository.owner), let name = encodeGitHubPathComponent(repository.name) else {
            throw MetadataHTTPError.unsupportedURL
        }
        var entries: [ChangelogEntry] = []
        for page in 1...githubPages {
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
                let items = ChangelogFeeds.entries(fromFeed: try client.fetch(feed, resource: .changelogPage(host: "github.com")).body)
                    .filter {
                        ChangelogVersion.token(in: $0.version) == $0.version
                            && $0.version.range(of: #"(?i)(alpha|beta|rc|pre|dev|nightly)"#, options: .regularExpression) == nil
                    }
                return Self.ownProductReleases(items, name: currentName, preferCLI: preferCLI)
            }
            guard let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw MetadataHTTPError.invalidResponse }
            for release in releases where release["draft"] as? Bool != true && (prereleases || release["prerelease"] as? Bool != true) {
                guard let tag = release["tag_name"] as? String else { continue }
                let title = (release["name"] as? String)?.trimmingCharacters(in: .whitespaces)
                let version = ChangelogVersion.token(in: tag) ?? title.flatMap(ChangelogVersion.token(in:)) ?? tag
                let date = (release["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
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
            if releases.count < 100 { break }
        }
        return Self.ownProductReleases(entries, name: currentName, preferCLI: preferCLI)
    }

    /// In a repository that releases several products (golang/tools' gopls/v0.17, taplo's
    /// release-taplo-cli-0.9, bash-language-server's vscode-client-1.0), the releases whose tag
    /// prefix names this item; with no prefix naming it, only the unprefixed tags.
    static func ownProductReleases(_ entries: [ChangelogEntry], name: String, preferCLI: Bool = false) -> [ChangelogEntry] {
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
            return only.isEmpty || key.isEmpty || key.contains(only) || only.contains(key) || generic.contains(only) ? entries : []
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
        return kept.sorted { left, right in
            guard let a = ChangelogVersion.token(in: left.version), let b = ChangelogVersion.token(in: right.version) else { return false }
            return SparkleVersion.compare(a, b) == .orderedDescending
        }
    }

    /// A repository's releases, with its changelog file filling in versions the releases don't
    /// cover (projects that started publishing releases late, or skip some).
    private func githubHistory(_ repository: GitHubRepository, installed: String?, name: String = "", preferCLI: Bool = false) throws -> [ChangelogEntry] {
        // A pre-release installed (PowerShell Preview's 7.7.0-rc.1) is documented among the pre-releases.
        let installedPrerelease = installed?.range(of: #"(?i)(alpha|beta|rc|preview|pre)"#, options: .regularExpression) != nil
        let releases = try githubReleases(repository, name: name, preferCLI: preferCLI, prereleases: installedPrerelease)
        let coversInstalled = installed.map { ChangelogVersion.installedIndex(in: releases, installed: $0) != nil } ?? true
        // Old releases without notes (kitty's) are filled from the repository's changelog too.
        let withText = releases.filter { !ChangelogDocument.isPlaceholder($0.content) }.count
        guard releases.count < 30 || !coversInstalled || withText * 10 < releases.count * 8 else { return releases }
        let file = (try? githubFile(repository)) ?? []
        guard !file.isEmpty else { return releases }
        return Self.merge(releases, file)
    }

    /// Entries from two sources for the same project, by version: the first source's text wins
    /// unless it is only a placeholder, and versions only the second has are added.
    static func merge(_ primary: [ChangelogEntry], _ secondary: [ChangelogEntry]) -> [ChangelogEntry] {
        var merged = primary
        for entry in secondary {
            if let index = merged.firstIndex(where: {
                ChangelogVersion.matches($0.version, entry.version) || ChangelogVersion.matches(entry.version, $0.version)
            }) {
                if ChangelogDocument.isPlaceholder(merged[index].content) {
                    let old = merged[index]
                    merged[index] = ChangelogEntry(
                        version: old.version, title: old.title ?? entry.title, date: old.date ?? entry.date, content: entry.content,
                        sourceURL: entry.sourceURL ?? old.sourceURL)
                }
            } else {
                merged.append(entry)
            }
        }
        return newestFirst(merged)
    }

    /// Versioned entries newest first, then the rest in their order (a sort comparing only
    /// versioned pairs isn't a consistent ordering and scrambles mixed lists).
    static func newestFirst(_ entries: [ChangelogEntry]) -> [ChangelogEntry] {
        let versioned = entries.enumerated().compactMap { offset, entry in ChangelogVersion.token(in: entry.version).map { (offset, $0, entry) } }
        let sorted = versioned.sorted { left, right in
            let order = SparkleVersion.compare(left.1, right.1)
            return order == .orderedSame ? left.0 < right.0 : order == .orderedDescending
        }.map(\.2)
        let unversioned = entries.filter { ChangelogVersion.token(in: $0.version) == nil }
        return sorted + unversioned
    }

    /// For a repository with no releases and no changelog: its version tags, newest first, each
    /// with the commits since the tag before it (for the newest few; GitHub's anonymous quota is
    /// small).
    private func githubTags(_ repository: GitHubRepository, name itemName: String = "", preferCLI: Bool = false) throws -> [ChangelogEntry] {
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
        var entries: [ChangelogEntry] = []
        for (index, tag) in versioned.enumerated() {
            var content = ""
            var date: Date?
            if index < described, index + 1 < versioned.count,
                let base = encodeGitHubPathComponent(versioned[index + 1].sha), let head = encodeGitHubPathComponent(tag.sha),
                let compare = URL(string: "https://api.github.com/repos/\(owner)/\(name)/compare/\(base)...\(head)"),
                let data = try? client.fetch(compare, resource: .githubReleaseList).body,
                let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let commits = document["commits"] as? [[String: Any]]
            {
                let messages = commits.compactMap { (($0["commit"] as? [String: Any])?["message"] as? String)?.split(separator: "\n").first.map(String.init) }
                    .filter { !$0.lowercased().hasPrefix("merge ") }
                content = messages.reversed().map { "- \($0)" }.joined(separator: "\n")
                date = ((commits.last?["commit"] as? [String: Any])?["committer"] as? [String: Any])?["date"].flatMap { $0 as? String }.flatMap {
                    ISO8601DateFormatter().date(from: $0)
                }
            }
            entries.append(
                ChangelogEntry(
                    version: tag.version, title: nil, date: date, content: content, sourceURL: "https://github.com/\(repository.path)/releases/tag/\(tag.name)")
            )
        }
        // Pre-release tags (Codex's 0.166.0-alpha.6) go when there are releases.
        let own = Self.ownProductReleases(entries, name: itemName, preferCLI: preferCLI)
        let stable = own.filter { $0.version.range(of: #"(?i)(alpha|beta|rc|pre|dev|nightly)"#, options: .regularExpression) == nil }
        return stable.isEmpty ? own : stable
    }

    // Raw file paths are case-sensitive, so the common spellings are each tried (a missing one
    // is a cached 404, and raw files don't count against the API quota).
    /// A JSON update endpoint: the notes it carries, or the page its `notes` field links to.
    private func updateFeed(_ url: URL, name: String) throws -> [ChangelogEntry] {
        guard let host = url.host?.lowercased() else { throw MetadataHTTPError.unsupportedURL }
        let feed = UpdateFeedJSON.read(try client.fetch(url, resource: .changelogPage(host: host)).body)
        for link in feed.links.prefix(1) where isPublicHTTPSURL(link) {
            let linked = (try? page(link, name: name)) ?? []
            if ChangelogDocument.isMeaningful(linked) { return Self.merge(feed.entries, linked) }
        }
        return feed.entries
    }

    private func filteredFeed(_ url: URL, title: String) throws -> [ChangelogEntry] {
        guard let host = url.host?.lowercased() else { throw MetadataHTTPError.unsupportedURL }
        let items = ChangelogFeeds.entries(fromFeed: try client.fetch(url, resource: .changelogPage(host: host)).body)
        return items.compactMap { item in
            guard (item.title ?? item.version).localizedCaseInsensitiveContains(title),
                var version = ChangelogVersion.token(in: String(item.content.prefix(600)))
            else { return nil }
            // "156.0.8078.79/.80 for Windows and Mac": the Mac build is the later one.
            if let alternative = item.content.firstMatch(of: try! Regex("\(NSRegularExpression.escapedPattern(for: version))/\\.(\\d+)")),
                let last = alternative.output[1].substring
            {
                version = version.split(separator: ".").dropLast().joined(separator: ".") + "." + last
            }
            return ChangelogEntry(version: version, title: item.title ?? item.version, date: item.date, content: item.content, sourceURL: item.sourceURL)
        }
    }

    struct VersionedURL: Equatable {
        let url: URL
        let version: String
    }

    /// Several versions' pages read together, newest first; a page that isn't up yet (the latest
    /// version's, sometimes) is skipped.
    private func versionPages(_ pages: [VersionedURL]) throws -> [ChangelogEntry] {
        var entries: [ChangelogEntry] = []
        var firstError: Error?
        for page in pages {
            do { entries = Self.merge(entries, try versionPage(page.url, version: page.version)) } catch { firstError = firstError ?? error }
        }
        if entries.isEmpty, let firstError { throw firstError }
        return entries
    }

    /// A page for one version: its own entry when the page splits by version, or else the whole
    /// page as that version's notes.
    private func versionPage(_ url: URL, version: String) throws -> [ChangelogEntry] {
        guard let host = url.host?.lowercased() else { throw MetadataHTTPError.unsupportedURL }
        let html = try fetchText(url, resource: .changelogPage(host: host))
        let split = read(html, url: url, render: true)
        // Split only when the sections say something (not VS Code's monthly page, whose
        // sub-headings carry versions of extensions with no text of their own).
        let withText = split.filter { !ChangelogDocument.isPlaceholder($0.content) }.count
        if withText * 2 > split.count,
            split.contains(where: { ChangelogVersion.matches($0.version, version) || ChangelogVersion.looselyMatches($0.version, version) })
        {
            return split
        }
        let whole = HTMLMarkdown.convert(html)
        return whole.isEmpty || ChangelogDocument.isPlaceholder(whole)
            ? split : [ChangelogEntry(version: version, content: whole, sourceURL: url.absoluteString)]
    }

    /// The latest few Temurin releases of a Java version, each with the OpenJDK issues it fixes.
    private func adoptium(major: Int) throws -> [ChangelogEntry] {
        guard
            let names = URL(
                string:
                    "https://api.adoptium.net/v3/info/release_names?version=%5B\(major)%2C\(major + 1)%29&release_type=ga&page_size=10&sort_order=DESC&vendor=eclipse&image_type=jdk"
            ),
            let list =
                (try JSONSerialization.jsonObject(with: client.fetch(names, resource: .changelogPage(host: "api.adoptium.net")).body) as? [String: Any])?[
                    "releases"] as? [String]
        else { throw MetadataHTTPError.invalidResponse }
        return list.prefix(10).compactMap { name -> ChangelogEntry? in
            guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-."))),
                let url = URL(string: "https://api.adoptium.net/v3/info/release_notes/\(encoded)"),
                let data = try? client.fetch(url, resource: .changelogPage(host: "api.adoptium.net")).body,
                let notes = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["release_notes"] as? [[String: Any]]
            else { return nil }
            // jdk-21.0.13+9 is 21.0.13; jdk8u462-b08 is 8.0.462.
            let version =
                name.firstMatch(of: #/^jdk-?(\d+(?:\.\d+)*)/#).map { String($0.1) }.flatMap {
                    $0.contains(".") ? $0 : name.firstMatch(of: #/^jdk(\d+)u(\d+)/#).map { "\($0.1).0.\($0.2)" } ?? $0
                } ?? name
            let lines = notes.compactMap { note -> String? in
                guard let title = note["title"] as? String, !title.hasPrefix("Bump update version") else { return nil }
                return "- \(title)\((note["id"] as? String).map { " (\($0))" } ?? "")"
            }
            return ChangelogEntry(
                version: version, title: name, content: lines.joined(separator: "\n"), sourceURL: "https://adoptium.net/temurin/release-notes/?version=\(name)")
        }
    }

    enum ForgeKind { case gitlab, forgejo }
    static let forgeKinds: [String: ForgeKind] = [
        "gitlab.com": .gitlab, "gitlab.gnome.org": .gitlab, "gitlab.freedesktop.org": .gitlab, "invent.kde.org": .gitlab,
        "salsa.debian.org": .gitlab, "gitlab.archlinux.org": .gitlab, "framagit.org": .gitlab, "gitlab.torproject.org": .gitlab,
        "codeberg.org": .forgejo, "gitea.com": .forgejo
    ]

    /// A GitLab or Forgejo repository's releases (with the changelog file filling gaps, as for
    /// GitHub), or its changelog file alone.
    private func forge(host: String, path: String, name: String) throws -> [ChangelogEntry] {
        let kind = Self.forgeKinds[host] ?? .gitlab
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path
        let api =
            kind == .gitlab ? "https://\(host)/api/v4/projects/\(encoded)/releases?per_page=100" : "https://\(host)/api/v1/repos/\(path)/releases?limit=50"
        var releases: [ChangelogEntry] = []
        if let url = URL(string: api), let data = try? client.fetch(url, resource: .changelogPage(host: host)).body,
            let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        {
            for release in list
            where release["draft"] as? Bool != true && release["prerelease"] as? Bool != true && release["upcoming_release"] as? Bool != true {
                guard let tag = release["tag_name"] as? String, let version = ChangelogVersion.token(in: tag) else { continue }
                let body = (release["description"] as? String) ?? (release["body"] as? String) ?? ""
                let date = ((release["released_at"] ?? release["published_at"] ?? release["created_at"]) as? String).flatMap {
                    ISO8601DateFormatter().date(from: $0.replacing(#/\.\d+/#, with: ""))
                }
                releases.append(
                    ChangelogEntry(
                        version: version, title: nil, date: date, content: ChangelogDocument.tidy(body),
                        sourceURL: "https://\(host)/\(path)/\(kind == .gitlab ? "-/" : "")releases/tag/\(tag)"))
            }
        }
        releases = Self.ownProductReleases(releases, name: name)
        let withText = releases.filter { !ChangelogDocument.isPlaceholder($0.content) }.count
        if releases.count >= 30, withText * 10 >= releases.count * 8 { return releases }
        for file in Self.repositoryChangelogPaths {
            let raw = kind == .gitlab ? "https://\(host)/\(path)/-/raw/HEAD/\(file)" : "https://\(host)/\(path)/raw/branch/main/\(file)"
            guard let url = URL(string: raw) else { continue }
            let text: String
            do { text = try fetchText(url, resource: .changelogPage(host: host)) } catch MetadataHTTPError.notFound { continue } catch { break }
            // A missing file can come back as the forge's sign-in or error page.
            guard !text.lowercased().contains("<html") else { continue }
            let entries = ChangelogDocument.entries(fromMarkdown: text, sourceURL: raw)
            if !entries.isEmpty { return releases.isEmpty ? entries : Self.merge(releases, entries) }
        }
        return releases
    }

    private static let repositoryChangelogPaths = [
        "CHANGELOG.md", "ChangeLog.md", "Changelog.md", "changelog.md", "CHANGES.md", "Changes.md", "HISTORY.md", "History.md", "NEWS.md", "RELEASES.md",
        "RELEASE_NOTES.md", "RELEASE-NOTES.md", "CHANGELOG", "ChangeLog", "Changelog", "CHANGES", "NEWS", "HISTORY", "docs/changelog.md", "docs/CHANGELOG.md",
        "docs/CHANGES.md", "CHANGELOG.rst", "CHANGES.rst", "HISTORY.rst", "NEWS.rst", "docs/changelog.rst", "CHANGELOG.txt", "NEWS.txt"
    ]

    private func githubFile(_ repository: GitHubRepository) throws -> [ChangelogEntry] {
        guard let owner = encodeGitHubPathComponent(repository.owner), let name = encodeGitHubPathComponent(repository.name) else {
            throw MetadataHTTPError.unsupportedURL
        }
        for path in Self.repositoryChangelogPaths {
            let url = URL(string: "https://raw.githubusercontent.com/\(owner)/\(name)/HEAD/\(path)")!
            let text: String
            do { text = try fetchText(url, resource: .githubChangelog) } catch MetadataHTTPError.notFound { continue }
            let entries = ChangelogDocument.entries(fromMarkdown: text, sourceURL: "https://github.com/\(repository.path)/blob/HEAD/\(path)")
            if !entries.isEmpty { return entries }
        }
        return []
    }

    // MARK: Web pages

    /// The page itself when it lists versions, or else the changelog its links point to. Each
    /// page is read as HTML, then through the feeds it advertises, then through the JSON it embeds
    /// for its scripts, and last rendered in WebKit when its content is built by scripts.
    func page(_ url: URL, name: String = "", installed: String? = nil, known: Bool = false) throws -> [ChangelogEntry] {
        guard let host = url.host?.lowercased() else { throw MetadataHTTPError.unsupportedURL }
        let html = try fetchText(url, resource: .changelogPage(host: host))
        let isChangelogPage = known || Self.looksLikeChangelogURL(url)
        // A homepage's own text, then its changelog links, and only then its feeds (often a
        // blog covering other products) and embedded data.
        // A homepage's dated news items (PostgreSQL's, Docker's) aren't its changelog.
        var entries = isChangelogPage ? read(html, url: url, render: true) : Self.withoutDayEntries(Self.pageEntries(html, url: url))
        // Versions of another product (a homepage listing the vendor's other app) don't stop the search.
        let fits = { (found: [ChangelogEntry]) in ChangelogVersion.sameLine(found, installed: installed) }
        // A homepage's own couple of versions (a "what's new" teaser) don't beat its changelog link.
        if fits(entries), entries.count >= (isChangelogPage ? 2 : 3) || ChangelogDocument.isMeaningful(entries) && isChangelogPage { return entries }
        // An index of years (Warp's /changelog links /changelog/2026, /changelog/2025): the newest two.
        if isChangelogPage, entries.count < 3 {
            let years = Self.yearSections(in: html, base: url)
            var found: [ChangelogEntry] = []
            for year in years.prefix(2) {
                guard let yearHost = year.host?.lowercased(), let text = try? fetchText(year, resource: .changelogPage(host: yearHost)) else { continue }
                found = Self.merge(found, read(text, url: year, render: true))
            }
            if ChangelogDocument.isMeaningful(found), found.count >= 3, fits(found) { return found }
        }
        // A changelog hub listing another product first (LM Studio's /changelog is Bionic's) links
        // the item's own section (/changelog/lmstudio).
        if isChangelogPage, let section = Self.productSection(in: html, base: url, name: name), let sectionHost = section.host?.lowercased(),
            let text = try? fetchText(section, resource: .changelogPage(host: sectionHost))
        {
            let found = read(text, url: section, render: true)
            if ChangelogDocument.isMeaningful(found), fits(found) { return found }
        }
        // A homepage that links the project's own GitHub repository (same name as the item):
        // its releases beat a blog the homepage also links, when they go back a while.
        var repositoryHistory: [ChangelogEntry] = []
        if !isChangelogPage, let repository = Self.ownRepositoryLink(in: html, base: url, name: name) {
            if client.debug { MetadataHTTPClient.trace("homepage links its repository \(repository.path)") }
            repositoryHistory = (try? githubHistory(repository, installed: nil)) ?? []
            if !ChangelogDocument.isMeaningful(repositoryHistory) { repositoryHistory = (try? githubFile(repository)) ?? [] }
            if ChangelogDocument.isMeaningful(repositoryHistory), repositoryHistory.count >= 5 { return repositoryHistory }
        }
        var linkError: Error?
        for link in Self.changelogLinks(in: html, base: url).prefix(4) {
            guard let linkHost = link.host?.lowercased() else { continue }
            if linkHost == "github.com", let github = GitHubSource.parse(Hints.repositoryRoot(link)) {
                let releases = (try? githubReleases(github.repository)) ?? []
                if ChangelogDocument.isMeaningful(releases) { return releases }
                let file = (try? githubFile(github.repository)) ?? []
                if ChangelogDocument.isMeaningful(file) { return file }
                continue
            }
            if client.debug { MetadataHTTPClient.trace("following changelog link \(link.absoluteString)") }
            let linked: String
            do { linked = try fetchText(link, resource: .changelogPage(host: linkHost)) } catch { linkError = linkError ?? error; continue }
            var linkedEntries = read(linked, url: link, render: true)
            if !fits(linkedEntries), let section = Self.productSection(in: linked, base: link, name: name),
                let text = try? fetchText(section, resource: .changelogPage(host: section.host?.lowercased() ?? linkHost))
            {
                let found = read(text, url: section, render: true)
                if ChangelogDocument.isMeaningful(found), fits(found) { return found }
                if linkedEntries.isEmpty { linkedEntries = found }
            }
            // A link that yields a real changelog wins; a couple of stray versions (a newsletter
            // page) only stands in if nothing better turns up.
            if ChangelogDocument.isMeaningful(linkedEntries), fits(linkedEntries) || !fits(entries) {
                if linkedEntries.count >= 3, fits(linkedEntries) { return linkedEntries }
                if linkedEntries.count > entries.count || !fits(entries) { entries = linkedEntries }
            }
        }
        // Only then the homepage's feeds and embedded data, keeping posts that name the item
        // (a company blog covers its other products too).
        if !isChangelogPage {
            let more = Self.withoutDayEntries(read(html, url: url, render: false, name: name))
            if ChangelogDocument.isMeaningful(more) && more.count >= 2 && fits(more) { return more }
            if entries.isEmpty { entries = more }
        }
        if ChangelogDocument.isMeaningful(repositoryHistory) { return repositoryHistory }
        // Still little or nothing: the changelog the vendor's sitemap or docs site lists.
        if !isChangelogPage, entries.count < 3 || !fits(entries) {
            // Of the top few, the one with the installed version, or else the most versions.
            var best: [ChangelogEntry] = []
            for candidate in discoverChangelogPages(near: url, name: name).prefix(6) {
                guard let candidateHost = candidate.host?.lowercased(), let text = try? fetchText(candidate, resource: .changelogPage(host: candidateHost))
                else { continue }
                var found = read(text, url: candidate, render: true)
                // An index of editions ("/release-notes" listing Mac, Windows, Linux) leads to the Mac one.
                if found.count < 3,
                    let mac = HTMLMarkdown.links(in: text, base: candidate).map(\.url).first(where: { link in
                        link.host == candidate.host && link.path.hasPrefix(candidate.path) && link.path != candidate.path
                            && ["mac", "macos", "osx"].contains(link.lastPathComponent.lowercased())
                    }), let macText = try? fetchText(mac, resource: .changelogPage(host: candidateHost))
                {
                    found = read(macText, url: mac, render: true)
                }
                guard ChangelogDocument.isMeaningful(found), found.count >= 3, fits(found) else { continue }
                if client.debug { MetadataHTTPClient.trace("discovered changelog page \(candidate.absoluteString): \(found.count) versions") }
                let covers = installed.map { ChangelogVersion.installedIndex(in: found, installed: $0) != nil } ?? false
                if covers { return found }
                if found.count > best.count { best = found }
            }
            if best.count > entries.count || !best.isEmpty && !fits(entries) { return best }
        }
        // The page itself may be built by scripts even though its address doesn't say changelog.
        if !ChangelogDocument.isMeaningful(entries), !Self.looksLikeChangelogURL(url), ChangelogFeeds.looksScriptBuilt(html) {
            let rendered = renderedEntries(url)
            if ChangelogDocument.isMeaningful(rendered) { return rendered }
        }
        if entries.isEmpty, let linkError { throw linkError }
        return entries
    }

    /// One page's entries: its HTML, its advertised feeds, its embedded JSON, then (when allowed
    /// and the page is script-built) WebKit's rendering of it.
    private func read(_ html: String, url: URL, render: Bool, name: String = "") -> [ChangelogEntry] {
        let entries = Self.pageEntries(html, url: url)
        // Two versions may be a teaser (Notion's two latest headlines over a full feed).
        if entries.count >= 3, ChangelogDocument.isMeaningful(entries) { return entries }
        for feed in ChangelogFeeds.advertisedFeeds(in: html, base: url).prefix(2) where isPublicHTTPSURL(feed) {
            guard let feedHost = feed.host, let data = try? client.fetch(feed, resource: .changelogPage(host: feedHost)).body else { continue }
            let items = ChangelogFeeds.entries(fromFeed: data)
            // A blog feed counts only when most of its posts are releases, and only those are kept.
            var releases = items.filter { ChangelogVersion.token(in: $0.version) == $0.version }
            // Read from a homepage, a feed's posts count only when they name the item.
            let key = BundleURLScanner.matchKey(name)
            if !key.isEmpty, !Self.looksLikeChangelogURL(url) {
                releases = releases.filter { BundleURLScanner.matchKey(($0.title ?? "") + " " + $0.version + " " + $0.content.prefix(200)).contains(key) }
            }
            // A changelog page's own feed whose posts are mostly titled by feature, not version
            // (Notion's /releases/rss.xml, Figma's, Linear's): a dated log of what changed.
            let ownFeed = Self.looksLikeChangelogURL(url) && Self.looksLikeChangelogURL(feed)
            if ownFeed, releases.count * 2 < items.count {
                let dated = ChangelogFeeds.datedEntries(items)
                if dated.count >= 3 {
                    if client.debug { MetadataHTTPClient.trace("read feed \(feed.absoluteString) by date: \(dated.count) days") }
                    return dated
                }
            }
            if releases.count >= 3 || releases.count >= 2 && releases.count * 5 >= items.count * 3 {
                if client.debug { MetadataHTTPClient.trace("read feed \(feed.absoluteString): \(releases.count) releases") }
                return releases
            }
        }
        // Docs sites (Mintlify and others) serve each page as Markdown at the same address plus ".md".
        if entries.count < 3, url.pathExtension.isEmpty, url.path.count > 1, url.query == nil, let host = url.host?.lowercased(),
            let markdownURL = URL(string: url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + ".md"),
            let markdown = try? fetchText(markdownURL, resource: .changelogPage(host: host)), markdown.range(of: "<html", options: .caseInsensitive) == nil
        {
            let fromMarkdown = ChangelogDocument.entries(fromMarkdown: markdown, sourceURL: url.absoluteString)
            if fromMarkdown.count >= 3, ChangelogDocument.isMeaningful(fromMarkdown) {
                if client.debug { MetadataHTTPClient.trace("read the Markdown copy \(markdownURL.absoluteString): \(fromMarkdown.count) versions") }
                return fromMarkdown
            }
        }
        let embedded = entries.count >= 2 ? [] : ChangelogFeeds.embeddedEntries(in: html)
        if ChangelogDocument.isMeaningful(embedded) {
            if client.debug { MetadataHTTPClient.trace("read embedded data on \(url.absoluteString): \(embedded.count) entries") }
            return embedded
        }
        if render, !ChangelogDocument.isMeaningful(entries), ChangelogFeeds.looksScriptBuilt(html) || entries.isEmpty {
            let rendered = renderedEntries(url)
            if ChangelogDocument.isMeaningful(rendered) { return rendered }
        }
        return entries
    }

    private func renderedEntries(_ url: URL) -> [ChangelogEntry] {
        guard let renderer else { return [] }
        if client.debug { MetadataHTTPClient.trace("rendering \(url.absoluteString) in WebKit") }
        guard let html = renderer(url) else {
            if client.debug { MetadataHTTPClient.trace("rendering \(url.absoluteString) failed") }
            return []
        }
        let entries = Self.pageEntries(html, url: url)
        return ChangelogDocument.isMeaningful(entries) ? entries : ChangelogFeeds.embeddedEntries(in: html)
    }

    static func pageEntries(_ text: String, url: URL) -> [ChangelogEntry] {
        let isHTML =
            text.range(of: "<html", options: .caseInsensitive) != nil || text.range(of: "<h[1-6]", options: [.regularExpression, .caseInsensitive]) != nil
        guard isHTML else { return ChangelogDocument.entries(fromMarkdown: text, sourceURL: url.absoluteString) }
        let entries = ChangelogDocument.entries(fromMarkdown: HTMLMarkdown.convert(text), sourceURL: url.absoluteString)
        // Content inside what looked like page chrome (ngrok's changelog sits in an unclosed <nav>):
        // the raw page has version headings the conversion lost.
        if entries.count < 3 {
            let rawVersionHeadings = text.matches(of: #/(?is)<h[1-4][^>]*>(.{0,200}?)</h[1-4]>/#).filter {
                ChangelogVersion.token(in: HTMLText.plainText(from: String($0.1))) != nil
            }.count
            if rawVersionHeadings >= 3 {
                let unskipped = ChangelogDocument.entries(fromMarkdown: HTMLMarkdown.convert(text, skipChrome: false), sourceURL: url.absoluteString)
                if unskipped.count > entries.count { return unskipped }
            }
        }
        return entries
    }

    private static let discoveryPaths = [
        "changelog", "release-notes", "releasenotes", "releases", "whats-new", "updates", "docs/changelog", "docs/release-notes", "support/changelog",
        "help/release-notes"
    ]

    /// Changelog pages on the vendor's own site the homepage doesn't link plainly: those its
    /// sitemaps list (from robots.txt, on the site and its docs subdomain), then common paths,
    /// ranked so the product's own Mac release notes come first. Bounded to a few requests.
    func discoverChangelogPages(near base: URL, name: String) -> [URL] {
        guard let host = base.host?.lowercased(), let domain = HomebrewCaskCatalog.vendorDomain(host) else { return [] }
        // The site, its docs subdomain, and a releases subdomain (releases.1password.com).
        let hosts = Array(Set([host, "docs.\(domain)", "releases.\(domain)"]))
        var candidates: [URL] = []
        // Subdomains that don't exist (most sites have no docs. or releases.) aren't guessed at further.
        var liveHosts = hosts
        for site in hosts {
            guard let robotsURL = URL(string: "https://\(site)/robots.txt") else { continue }
            let robots: String
            do { robots = try fetchText(robotsURL, resource: .changelogPage(host: site)) } catch let error as MetadataHTTPError
                where site != host && error.isUnreachableHost
            { liveHosts.removeAll { $0 == site }; continue } catch { robots = "" }
            var maps = robots.matches(of: #/(?im)^sitemap:\s*(\S+)/#).compactMap { URL(string: String($0.1)) }
            if maps.isEmpty, let fallback = URL(string: "https://\(site)/sitemap.xml") { maps = [fallback] }
            var fetched = 0
            var queue = Array(maps.prefix(3))
            while let map = queue.first, fetched < 6 {
                queue.removeFirst()
                fetched += 1
                guard let mapHost = map.host?.lowercased(), HomebrewCaskCatalog.vendorDomain(mapHost) == domain,
                    let xml = try? fetchText(map, resource: .changelogPage(host: mapHost))
                else { continue }
                for match in xml.matches(of: #/<loc>\s*([^<\s]+)\s*</loc>/#) {
                    guard let url = URL(string: HTMLText.decodeEntities(String(match.1))) else { continue }
                    if url.pathExtension.lowercased() == "xml" {
                        if Self.sitemapLooksRelevant(url) { queue.append(url) }
                    } else if Self.looksLikeChangelogURL(url) {
                        candidates.append(url)
                    }
                }
            }
        }
        var guesses: Set<String> = []
        func guess(_ url: URL?) { if let url { candidates.append(url); guesses.insert(url.absoluteString) } }
        for site in liveHosts { for path in Self.discoveryPaths { guess(URL(string: "https://\(site)/\(path)")) } }
        // Beside a homepage deep in a docs site: /docs/miniconda/main has /docs/miniconda/release-notes.
        let folder = base.deletingLastPathComponent()
        if base.pathComponents.count > 2, folder.path.count > 1 { for path in ["release-notes", "changelog"] { guess(folder.appending(path: path)) } }
        var seen = Set<String>()
        let unique = candidates.filter {
            isPublicHTTPSURL($0) && seen.insert($0.absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))).inserted
        }
        let ranked = unique.map { ($0, Self.discoveryScore($0, name: name)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map(\.0)
        // The common paths are guesses: keep only those that answer.
        return ranked.filter { url in
            guard guesses.contains(url.absoluteString) else { return true }
            guard let host = url.host?.lowercased() else { return false }
            return (try? client.fetch(url, resource: .changelogPage(host: host))) != nil
        }
    }

    /// Child sitemaps worth opening: pages, docs, or changelogs, not blog posts or products by locale.
    static func sitemapLooksRelevant(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        if ["blog", "post", "news", "article", "image", "video", "author", "tag", "categor", "customer", "event", "job", "career", "store", "shop"].contains(
            where: path.contains)
        {
            return false
        }
        return true
    }

    static func discoveryScore(_ url: URL, name: String) -> Int {
        let path = url.path.lowercased()
        let segments = path.split(separator: "/").map(String.init)
        guard let last = segments.last else { return 0 }
        var score = 0
        let exact = [
            "changelog", "release-notes", "releasenotes", "releases", "whats-new", "updates", "history", "changes", "release-history", "version-history"
        ]
        if exact.contains(last) || exact.contains(where: { segments.dropLast().last == $0 && ["mac", "macos", "osx", "desktop"].contains(last) }) {
            score += 50
        } else if looksLikeChangelogURL(url) {
            score += 15
        }
        // The product's own words in the path: "desktop" for docker-desktop.
        let words = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 }
        score += words.filter { path.contains($0) }.count * 15
        if ["mac", "macos", "osx"].contains(where: { segments.contains($0) }) { score += 10 }
        // What an installed package is, as opposed to a vendor's hosted services: ngrok's agent
        // changelog over its AI gateway's.
        if ["agent", "cli", "desktop", "app", "client"].contains(where: { word in segments.dropLast().contains(where: { $0.contains(word) }) }) { score += 10 }
        if ["windows", "linux", "ios", "android", "api", "sdk", "enterprise", "server"].contains(where: { word in
            segments.contains(where: { $0.contains(word) })
        }) {
            score -= 25
        }
        if ["blog", "news", "article", "post", "press", "community", "forum", "template", "collection", "customer", "webinar", "event"].contains(
            where: path.contains)
        {
            score -= 40
        }
        // Localized copies (/ja-jp/, /de/) and deep paths lose.
        if segments.contains(where: { $0.firstMatch(of: #/^[a-z]{2}(-[a-z]{2})?$/#) != nil && !["io", "go"].contains($0) }) { score -= 30 }
        score -= max(0, segments.count - 3) * 5
        if url.host?.hasPrefix("docs.") == true { score += 5 }
        return score
    }

    static func withoutDayEntries(_ entries: [ChangelogEntry]) -> [ChangelogEntry] {
        entries.filter { $0.version.firstMatch(of: #/^\d{4}-\d{2}-\d{2}$/#) == nil }
    }

    /// On a changelog page, links one level down named for a year, newest first: /changelog/2026.
    static func yearSections(in html: String, base: URL) -> [URL] {
        let folder = base.path.hasSuffix("/") ? base.path : base.path + "/"
        var seen = Set<Int>()
        return HTMLMarkdown.links(in: html, base: base).compactMap { link -> (Int, URL)? in
            guard link.url.host?.lowercased() == base.host?.lowercased(), link.url.path.hasPrefix(folder) else { return nil }
            let rest = link.url.path.dropFirst(folder.count).split(separator: "/")
            guard rest.count == 1, let year = Int(rest[0]), year >= 2000, year <= 2100, seen.insert(year).inserted else { return nil }
            return (year, link.url)
        }.sorted { $0.0 > $1.0 }.map(\.1)
    }

    /// On a changelog page, a link one level down named for the item: /changelog/lmstudio.
    static func productSection(in html: String, base: URL, name: String) -> URL? {
        let key = BundleURLScanner.matchKey(name)
        guard key.count >= 3 else { return nil }
        let folder = base.path.hasSuffix("/") ? base.path : base.path + "/"
        return HTMLMarkdown.links(in: html, base: base).map(\.url).first { link in
            guard link.host?.lowercased() == base.host?.lowercased(), link.path.hasPrefix(folder) else { return false }
            let rest = link.path.dropFirst(folder.count).split(separator: "/")
            return rest.count == 1 && BundleURLScanner.matchKey(String(rest[0])) == key
        }
    }

    /// A github.com/owner/repo link whose repository (or owner) is named like the item: mpv.io
    /// links mpv-player/mpv, getcomposer.org links composer/composer.
    static func ownRepositoryLink(in html: String, base: URL, name: String) -> GitHubRepository? {
        let key = BundleURLScanner.matchKey(name)
        guard key.count >= 2 else { return nil }
        var candidates: [GitHubRepository] = []
        for link in HTMLMarkdown.links(in: html, base: base) where link.url.host?.lowercased() == "github.com" {
            guard let source = GitHubSource.parse(Hints.repositoryRoot(link.url)) else { continue }
            let repo = BundleURLScanner.matchKey(source.repository.name)
            if repo == key || repo.hasPrefix(key) && repo.count <= key.count + 8 || key.hasPrefix(repo) && repo.count >= 3 {
                if !candidates.contains(source.repository) { candidates.append(source.repository) }
            }
        }
        return candidates.count == 1 ? candidates[0] : candidates.first { BundleURLScanner.matchKey($0.name) == key }
    }

    private static let changelogWords = [
        "changelog", "change log", "changes", "release notes", "release-notes", "releasenotes", "releases", "what's new", "whats-new", "whatsnew", "what’s new",
        "version history", "history", "news", "updates"
    ]

    static func looksLikeChangelogURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return changelogWords.contains {
            path.contains($0.replacingOccurrences(of: " ", with: "-")) || path.contains($0.replacingOccurrences(of: " ", with: ""))
        }
    }

    /// Links on the page that read like its changelog, same site (or its GitHub) first.
    static func changelogLinks(in html: String, base: URL) -> [URL] {
        let site = base.host.flatMap(HomebrewCaskCatalog.vendorDomain)
        var scored: [(URL, Int)] = []
        for link in HTMLMarkdown.links(in: html, base: base) {
            guard isPublicHTTPSURL(link.url), link.url != base else { continue }
            let text = link.text.lowercased()
            let path = link.url.path.lowercased()
            var score = 0
            for (rank, word) in changelogWords.enumerated() {
                if text.contains(word) { score = max(score, 40 - rank) }
                if path.contains(word.replacingOccurrences(of: " ", with: "-")) || path.contains(word.replacingOccurrences(of: " ", with: "")) {
                    score = max(score, 30 - rank)
                }
            }
            guard score > 0 else { continue }
            let host = link.url.host?.lowercased() ?? ""
            if site != nil, HomebrewCaskCatalog.vendorDomain(host) == site { score += 20 } else if host != "github.com" { score -= 25 }
            // On a site with several products, a link inside this product's section
            // (/products/microsnitch/…) wins, and one into a sibling product's section
            // (/products/littlesnitch/…) loses.
            if link.url.host?.lowercased() == base.host?.lowercased() {
                let baseFolders = base.deletingLastPathComponent().pathComponents
                let linkFolders = link.url.deletingLastPathComponent().pathComponents
                let shared = zip(baseFolders, linkFolders).prefix { $0 == $1 }.count
                if baseFolders.count > 2, shared == baseFolders.count {
                    score += 25
                } else if baseFolders.count > 2, shared == baseFolders.count - 1, linkFolders.count >= baseFolders.count {
                    score -= 60
                }
            }
            if score > 0 { scored.append((link.url, score)) }
        }
        var seen = Set<String>()
        return scored.sorted { $0.1 > $1.1 }.map(\.0).filter { seen.insert($0.absoluteString).inserted }
    }

    func fetchText(_ url: URL, resource: MetadataResource) throws -> String {
        let data = try client.fetch(url, resource: resource).body
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: - Hints

    private func gatherHints(_ subject: ChangelogSubject, into hints: inout Hints) {
        let item = subject.item
        for source in Self.knownSources(for: item) { hints.add(source) }
        switch item.kind {
        case .homebrewFormula, .homebrewCask:
            let isCask = item.kind == .homebrewCask
            if let prefix = item.prefix, let version = item.installedVersion, !isCask {
                let keg = URL(filePath: prefix).appending(path: "Cellar").appending(path: item.name).appending(path: version)
                for file in Self.changelogFiles(in: keg) + Self.changelogFiles(in: keg.appending(path: "share/doc").appending(path: item.name)) {
                    hints.add(.localFiles([file]))
                }
            }
            if let source = subject.homebrewSourceURL.flatMap(URL.init(string:)), let github = GitHubSource.parse(source) { hints.add(github.repository) }
            homebrewAPIHints(token: item.name, cask: isCask, into: &hints)
        case .package:
            packageHints(item, into: &hints)
        case .nativeApp:
            applicationHints(item, into: &hints)
        }
    }

    /// Where a few projects keep a changelog no metadata points to, like Homebrew's livecheck
    /// blocks do for versions.
    static func knownSources(for item: CatalogItem) -> [Source] {
        let version = item.installedVersion.map(ChangelogVersion.normalized) ?? ""
        let minor = version.split(separator: ".").prefix(2).joined(separator: ".")
        switch (item.kind, item.bundleIdentifier ?? item.name) {
        case (.homebrewFormula, "go"):
            return [.releaseNotes(URL(string: "https://go.dev/doc/devel/release")!)]
        case (.nativeApp, let id) where id.hasPrefix("org.python.") && minor.split(separator: ".").count == 2:
            return [.releaseNotes(URL(string: "https://docs.python.org/\(minor)/whatsnew/changelog.html")!)]
        case (.homebrewFormula, let name) where name.hasPrefix("python@"):
            return [.releaseNotes(URL(string: "https://docs.python.org/\(name.dropFirst(7))/whatsnew/changelog.html")!)]
        case (.nativeApp, "com.image-line.flstudio"), (.nativeApp, "com.image-line.fl-cloud-plugins"):
            return [.releaseNotes(URL(string: "https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/WhatsNew.htm")!)]
        case (.nativeApp, "com.valvesoftware.steam"):
            return [.steam(appID: "593110")]
        case (.homebrewCask, "claude-code"), (.homebrewFormula, "claude-code"):
            return [.githubFile(GitHubRepository(owner: "anthropics", name: "claude-code"))]
        case (.homebrewCask, "google-chrome"), (.nativeApp, "com.google.Chrome"):
            return [
                .filteredFeed(
                    URL(string: "https://chromereleases.googleblog.com/feeds/posts/default/-/Stable%20updates?redirect=false&max-results=25")!,
                    title: "Stable Channel Update for Desktop")
            ]
        case (.homebrewCask, "android-studio"), (.nativeApp, "com.google.android.studio"):
            return [.releaseNotes(URL(string: "https://developer.android.com/studio/releases")!)]
        case (.homebrewCask, "flutter"), (.homebrewFormula, "flutter"):
            return [.releaseNotes(URL(string: "https://docs.flutter.dev/release/release-notes")!)]
        case (.homebrewCask, "gcloud-cli"), (.homebrewCask, "google-cloud-sdk"):
            return [.releaseNotes(URL(string: "https://cloud.google.com/sdk/docs/release-notes")!)]
        case (.homebrewCask, "zoom"), (.nativeApp, "us.zoom.xos"):
            return [.releaseNotes(URL(string: "https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0061222")!)]
        case (.homebrewCask, "unity-hub"), (.nativeApp, "com.unity3d.unityhub"):
            return [.releaseNotes(URL(string: "https://unity.com/unity-hub/release-notes")!)]
        case (.homebrewCask, "postman"), (.nativeApp, "com.postmanlabs.mac"):
            return [.releaseNotes(URL(string: "https://www.postman.com/release-notes/postman-app/")!)]
        case (.homebrewCask, "warp"), (.nativeApp, "dev.warp.Warp-Stable"):
            return [.releaseNotes(URL(string: "https://docs.warp.dev/changelog")!)]
        case (.homebrewCask, "google-drive"), (.nativeApp, "com.google.drivefs"):
            return [.releaseNotes(URL(string: "https://support.google.com/a/answer/7577057?hl=en")!)]
        case (.homebrewCask, "chatgpt"), (.nativeApp, "com.openai.chat"):
            return [.releaseNotes(URL(string: "https://help.openai.com/en/articles/9703738-chatgpt-macos-app-release-notes")!)]
        case (.homebrewFormula, "zsh"):
            return [.githubFile(GitHubRepository(owner: "zsh-users", name: "zsh"))]
        case (.homebrewFormula, "glib"):
            return [.forge(host: "gitlab.gnome.org", path: "GNOME/glib")]
        case (.homebrewFormula, "docker"):
            return version.split(separator: ".").first.map { [.releaseNotes(URL(string: "https://docs.docker.com/engine/release-notes/\($0)/")!)] } ?? []
        case (.homebrewFormula, "ansible"):
            return version.split(separator: ".").first.map {
                [.releaseNotes(URL(string: "https://raw.githubusercontent.com/ansible-community/ansible-build-data/main/\($0)/CHANGELOG-v\($0).md")!)]
            } ?? []
        case (.homebrewCask, "signal"), (.nativeApp, "org.whispersystems.signal-desktop"):
            return [.githubReleases(GitHubRepository(owner: "signalapp", name: "Signal-Desktop"))]
        case (.homebrewCask, "emacs-app"), (.homebrewCask, "emacs"), (.nativeApp, "org.gnu.Emacs"):
            // This major's NEWS, then the previous major's (NEWS.30 beside it).
            guard let major = version.split(separator: ".").first.flatMap({ Int($0) }) else { return [] }
            return ["NEWS", "NEWS.\(major - 1)"].map {
                .releaseNotes(URL(string: "https://raw.githubusercontent.com/emacs-mirror/emacs/emacs-\(major)/etc/\($0)")!)
            }
        case (.homebrewCask, "steam"):
            return [.steam(appID: "593110")]
        case (.homebrewCask, "1password"), (.nativeApp, "com.1password.1password"):
            return [.releaseNotes(URL(string: "https://releases.1password.com/mac/stable/")!)]
        case (.homebrewCask, "claude"), (.nativeApp, "com.anthropic.claudefordesktop"):
            return [.releaseNotes(URL(string: "https://support.claude.com/en/articles/12138966-claude-desktop-release-notes")!)]
        case (.homebrewCask, "microsoft-edge"), (.nativeApp, "com.microsoft.edgemac"):
            return [.releaseNotes(URL(string: "https://learn.microsoft.com/en-us/deployedge/microsoft-edge-relnote-stable-channel")!)]
        case (.homebrewCask, "windows-app"), (.nativeApp, "com.microsoft.rdc.macos"):
            return [.releaseNotes(URL(string: "https://learn.microsoft.com/en-us/windows-app/whats-new?tabs=macos")!)]
        case (.homebrewCask, "miniconda"):
            return [.releaseNotes(URL(string: "https://www.anaconda.com/docs/getting-started/miniconda/release-notes")!)]
        case (.homebrewCask, "mongodb-compass"), (.nativeApp, "com.mongodb.compass"):
            return [.githubReleases(GitHubRepository(owner: "mongodb-js", name: "compass"))]
        case (.homebrewCask, let name) where name.hasPrefix("temurin"):
            // temurin@21, or the latest (unsuffixed) by its installed major version.
            let major = name.split(separator: "@").dropFirst().first.map(String.init) ?? version.split(separator: ".").first.map(String.init)
            return major.flatMap(Int.init).map { [.adoptium(major: $0)] } ?? []
        default:
            break
        }
        // Office for Mac's apps share one page of release notes, dated per update.
        let office = [
            "microsoft-word", "microsoft-excel", "microsoft-powerpoint", "microsoft-outlook", "microsoft-onenote", "microsoft-office",
            "microsoft-office-businesspro",
            "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint", "com.microsoft.Outlook", "com.microsoft.onenote.mac"
        ]
        if [.homebrewCask, .nativeApp].contains(item.kind), office.contains(item.bundleIdentifier ?? item.name) {
            return [.releaseNotes(URL(string: "https://learn.microsoft.com/en-us/officeupdates/release-notes-office-for-mac")!)]
        }
        // JetBrains' IDEs: the releases API carries each version's "what's new".
        if let code = jetBrainsProductCodes[item.bundleIdentifier ?? item.name],
            let url = URL(string: "https://data.services.jetbrains.com/products/releases?code=\(code)&type=release")
        {
            return [.updateFeed(url)]
        }
        // Release notes at an address built from the version, for the installed and latest versions.
        let versions = [item.availableVersion, item.installedVersion].compactMap { $0.map(ChangelogVersion.normalized) }.reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        // The latest and installed versions' pages, then (with `earlier`, which steps back one
        // release) the few before the installed one, for a history.
        func pages(earlier: (([Int]) -> [Int]?)? = nil, _ template: (String, [String]) -> String?) -> [Source] {
            var all = versions
            if let earlier, var parts = versions.last.map({ $0.split(separator: ".").compactMap { Int($0) } }) {
                for _ in 0..<5 {
                    guard let previous = earlier(parts) else { break }
                    parts = previous
                    let version = previous.map(String.init).joined(separator: ".")
                    if !all.contains(version) { all.append(version) }
                }
            }
            let urls = all.compactMap { version -> VersionedURL? in
                let parts = version.split(separator: ".").map(String.init)
                return template(version, parts).flatMap(URL.init(string:)).map { VersionedURL(url: $0, version: version) }
            }
            return urls.isEmpty ? [] : [.versionPages(urls)]
        }
        switch (item.kind, item.bundleIdentifier ?? item.name) {
        case (.homebrewCask, "firefox"), (.nativeApp, "org.mozilla.firefox"):
            return pages(earlier: { $0.count >= 2 && $0[0] > 1 ? [$0[0] - 1, 0] : nil }) { version, _ in
                "https://www.mozilla.org/en-US/firefox/\(version)/releasenotes/"
            }
        case (.homebrewCask, "visual-studio-code"), (.nativeApp, "com.microsoft.VSCode"):
            return pages(earlier: { $0.count >= 2 && $0[1] > 0 ? [$0[0], $0[1] - 1] : nil }) { _, parts in
                parts.count >= 2 ? "https://code.visualstudio.com/updates/v\(parts[0])_\(parts[1])" : nil
            }
        case (.homebrewCask, "blender"), (.nativeApp, "org.blenderfoundation.blender"):
            return pages(earlier: { $0.count >= 2 && $0[1] > 0 ? [$0[0], $0[1] - 1] : nil }) { _, parts in
                parts.count >= 2 ? "https://www.blender.org/download/releases/\(parts[0])-\(parts[1])/" : nil
            }
        case (.homebrewFormula, let name) where name.hasPrefix("postgresql") || name == "libpq":
            return pages(earlier: { $0.count >= 2 && $0[1] > 0 ? [$0[0], $0[1] - 1] : nil }) { version, _ in
                "https://www.postgresql.org/docs/release/\(version)/"
            }
        case (.homebrewFormula, "git"):
            return pages(earlier: { $0.count >= 2 && $0[1] > 0 ? [$0[0], $0[1] - 1, 0] : nil }) { version, _ in
                "https://raw.githubusercontent.com/git/git/master/Documentation/RelNotes/\(version).adoc"
            }
        case (.homebrewFormula, "gcc"):
            return pages(earlier: { $0.first.map { $0 > 10 ? [$0 - 1] : nil } ?? nil }) { _, parts in "https://gcc.gnu.org/gcc-\(parts[0])/changes.html" }
        case (.homebrewFormula, "qemu"):
            return pages(earlier: { $0.count >= 2 ? ($0[1] > 0 ? [$0[0], $0[1] - 1] : [$0[0] - 1, 2]) : nil }) { _, parts in
                parts.count >= 2 ? "https://wiki.qemu.org/ChangeLog/\(parts[0]).\(parts[1])" : nil
            }
        case (.homebrewCask, "libreoffice"), (.nativeApp, "org.libreoffice.script"):
            return pages { _, parts in parts.count >= 2 ? "https://wiki.documentfoundation.org/ReleaseNotes/\(parts[0]).\(parts[1])" : nil }
        case (.homebrewCask, let name) where name.hasPrefix("dotnet-sdk"):
            return versions.prefix(1).compactMap { version in
                let parts = version.split(separator: ".")
                return parts.count >= 2
                    ? URL(string: "https://raw.githubusercontent.com/dotnet/core/main/release-notes/\(parts[0]).\(parts[1])/releases.json").map {
                        .updateFeed($0)
                    } : nil
            }
        default:
            return []
        }
    }

    static let jetBrainsProductCodes: [String: String] = [
        "intellij-idea": "IIU", "com.jetbrains.intellij": "IIU", "intellij-idea-ce": "IIC", "com.jetbrains.intellij.ce": "IIC",
        "pycharm": "PCP", "com.jetbrains.pycharm": "PCP", "pycharm-ce": "PCC", "com.jetbrains.pycharm.ce": "PCC",
        "webstorm": "WS", "com.jetbrains.WebStorm": "WS", "goland": "GO", "com.jetbrains.goland": "GO",
        "clion": "CL", "com.jetbrains.CLion": "CL", "phpstorm": "PS", "com.jetbrains.PhpStorm": "PS",
        "rider": "RD", "com.jetbrains.rider": "RD", "rubymine": "RM", "com.jetbrains.rubymine": "RM",
        "datagrip": "DG", "com.jetbrains.datagrip": "DG", "rustrover": "RR", "com.jetbrains.rustrover": "RR",
        "dataspell": "DS", "com.jetbrains.dataspell": "DS", "jetbrains-toolbox": "TBA", "com.jetbrains.toolbox": "TBA"
    ]

    /// Homebrew's API: a formula's homepage and source, or a cask's homepage and download URL.
    private func homebrewAPIHints(token: String, cask: Bool, into hints: inout Hints) {
        guard let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))),
            let url = URL(string: "https://formulae.brew.sh/api/\(cask ? "cask" : "formula")/\(encoded).json"),
            let data = try? client.fetch(url, resource: .packageRegistry).body,
            let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let urls = document["urls"] as? [String: Any]
        let stable = (urls?["stable"] as? [String: Any])?["url"] as? String
        livecheckHints(document: document, cask: cask, stableURL: stable, into: &hints)
        let head = (urls?["head"] as? [String: Any])?["url"] as? String
        for link in [stable, head, document["url"] as? String] {
            guard let link, let url = URL(string: link) else { continue }
            if let github = GitHubSource.parse(url) {
                hints.add(github.repository)
            } else if let forge = Hints.forgeRepository(url) {
                hints.add(.forge(host: forge.host, path: forge.path))
            } else {
                registryHints(forDownload: url, into: &hints)
            }
        }
        hints.add(link: document["homepage"] as? String)
    }

    /// The update endpoint in the cask's or formula's `livecheck` block, read from its Ruby source
    /// on GitHub (raw files cost no API quota): a Sparkle feed, a JSON endpoint, or a repository.
    private func livecheckHints(document: [String: Any], cask: Bool, stableURL: String?, into hints: inout Hints) {
        guard let path = document["ruby_source_path"] as? String, !path.contains(".."),
            let url = URL(string: "https://raw.githubusercontent.com/Homebrew/\(cask ? "homebrew-cask" : "homebrew-core")/HEAD/\(path)"),
            let source = try? fetchText(url, resource: .githubChangelog)
        else { return }
        let version = cask ? document["version"] as? String : (document["versions"] as? [String: Any])?["stable"] as? String
        guard
            let livecheck = HomebrewLivecheck(
                source: source, version: version, downloadURL: cask ? document["url"] as? String : stableURL, homepage: document["homepage"] as? String)
        else { return }
        if client.debug { MetadataHTTPClient.trace("livecheck: \(livecheck.strategy) \(livecheck.url.absoluteString)") }
        switch livecheck.strategy {
        case .sparkle: hints.add(.sparkle(livecheck.url, padding: true))
        case .json: hints.add(.updateFeed(livecheck.url))
        case .github: if let github = GitHubSource.parse(Hints.repositoryRoot(livecheck.url)) { hints.add(github.repository) }
        case .page: if Self.looksLikeChangelogURL(livecheck.url) { hints.add(link: livecheck.url.absoluteString) }
        case .other: break
        }
    }

    /// A download from PyPI, npm, or crates.io names the package there, whose metadata names
    /// its repository: Homebrew's rich-cli downloads from PyPI, fish-lsp from npm.
    private func registryHints(forDownload url: URL, into hints: inout Hints) {
        let host = url.host?.lowercased() ?? ""
        let parts = url.path.split(separator: "/").map(String.init)
        if host == "files.pythonhosted.org" || host == "pypi.io" || host == "pypi.org", let file = parts.last,
            let match = file.firstMatch(of: #/^(.+?)-\d[^-]*\.(tar\.gz|zip|whl|tar\.bz2)$/#)
        {
            pypiHints(String(match.1), into: &hints)
        } else if host == "registry.npmjs.org", let dash = parts.firstIndex(of: "-"), dash > 0 {
            npmHints(parts[..<dash].joined(separator: "/"), into: &hints)
        } else if host == "static.crates.io" || host == "crates.io", let index = parts.firstIndex(of: "crates"), index + 1 < parts.count {
            cratesHints(parts[index + 1], into: &hints)
        }
    }

    private func pypiHints(_ name: String, into hints: inout Hints) {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "https://pypi.org/pypi/\(encoded)/json"),
            let data = try? client.fetch(url, resource: .packageRegistry).body, let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let info = document["info"] as? [String: Any]
        else { return }
        let links = ((info["project_urls"] as? [String: String]) ?? [:]).map { ($0.key, $0.value) } + [("Homepage", (info["home_page"] as? String) ?? "")]
        for (_, link) in Self.rankedProjectURLs(links) { hints.add(link: link) }
    }

    private func npmHints(_ name: String, into hints: inout Hints) {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let url = URL(string: "https://registry.npmjs.org/\(encoded)/latest"),
            let data = try? client.fetch(url, resource: .packageRegistry).body, let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        hints.add(link: (manifest["repository"] as? String) ?? ((manifest["repository"] as? [String: Any])?["url"] as? String))
        hints.add(link: manifest["homepage"] as? String)
    }

    private func cratesHints(_ name: String, into hints: inout Hints) {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let url = URL(string: "https://crates.io/api/v1/crates/\(encoded)"),
            let data = try? client.fetch(url, resource: .packageRegistry).body, let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let crate = document["crate"] as? [String: Any]
        else { return }
        hints.add(link: crate["repository"] as? String)
        hints.add(link: crate["homepage"] as? String)
    }

    private func packageHints(_ item: CatalogItem, into hints: inout Hints) {
        let scope = URL(filePath: item.prefix ?? "/nonexistent")
        switch item.updateSource {
        case RefreshProvider.npmGlobal.rawValue:
            let package = scope.appending(path: "lib/node_modules").appending(path: item.name)
            for file in Self.changelogFiles(in: package) { hints.add(.localFiles([file])) }
            if let data = try? Data(contentsOf: package.appending(path: "package.json")),
                let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                hints.add(link: (manifest["repository"] as? String) ?? ((manifest["repository"] as? [String: Any])?["url"] as? String))
                hints.add(link: manifest["homepage"] as? String)
            } else {
                npmHints(item.name, into: &hints)
            }
        case RefreshProvider.uvTools.rawValue:
            let links = Self.pythonProjectURLs(toolDirectory: scope.appending(path: item.name), name: item.name)
            for (_, link) in Self.rankedProjectURLs(links) { hints.add(link: link) }
            if links.isEmpty { pypiHints(item.name, into: &hints) }
        case RefreshProvider.cargo.rawValue:
            if let version = item.installedVersion,
                let sources = try? FileManager.default.contentsOfDirectory(atPath: scope.appending(path: "registry/src").path)
            {
                for registry in sources.sorted() {
                    let crate = scope.appending(path: "registry/src").appending(path: registry).appending(path: "\(item.name)-\(version)")
                    for file in Self.changelogFiles(in: crate) { hints.add(.localFiles([file])) }
                    if let manifest = try? String(contentsOf: crate.appending(path: "Cargo.toml"), encoding: .utf8) {
                        for key in ["repository", "homepage"] {
                            if let match = manifest.firstMatch(of: try! Regex("(?m)^\\s*\(key)\\s*=\\s*\"([^\"]+)\"")) {
                                hints.add(link: String(match.output[1].substring ?? ""))
                            }
                        }
                    }
                }
            }
            cratesHints(item.name, into: &hints)
        case RefreshProvider.steamGames.rawValue:
            // A cache from 1.0 has no app ID yet; Steam's own manifests have it.
            if let appID = item.identifier ?? steamAppID(named: item.name) { hints.add(.steam(appID: appID)) }
        case RefreshProvider.macPorts.rawValue:
            // Ports have no metadata Sift reads: a Python port is its PyPI project, and anything
            // else is usually the Homebrew formula of the same name.
            if let match = item.name.firstMatch(of: #/^py\d+-(.+)$/#) {
                pypiHints(String(match.1), into: &hints)
            } else {
                homebrewAPIHints(token: item.name.lowercased(), cask: false, into: &hints)
            }
        default:
            break
        }
    }

    /// Project-URL and Home-page lines from an installed Python package's metadata.
    static func pythonProjectURLs(toolDirectory: URL, name: String) -> [(String, String)] {
        let key = name.lowercased().replacingOccurrences(of: "-", with: "_")
        let lib = toolDirectory.appending(path: "lib")
        guard let pythons = try? FileManager.default.contentsOfDirectory(atPath: lib.path) else { return [] }
        for python in pythons where python.hasPrefix("python") {
            let site = lib.appending(path: python).appending(path: "site-packages")
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: site.path),
                let info = names.first(where: { $0.hasSuffix(".dist-info") && $0.lowercased().replacingOccurrences(of: "-", with: "_").hasPrefix(key + "-") }),
                let metadata = try? String(contentsOf: site.appending(path: info).appending(path: "METADATA"), encoding: .utf8)
            else { continue }
            var links: [(String, String)] = []
            for line in metadata.components(separatedBy: "\n") {
                if line.hasPrefix("Project-URL:") {
                    let value = line.dropFirst(12).split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if value.count == 2 { links.append((value[0], value[1])) }
                } else if line.hasPrefix("Home-page:") {
                    links.append(("Homepage", line.dropFirst(10).trimmingCharacters(in: .whitespaces)))
                } else if line.isEmpty {
                    break
                }
            }
            return links
        }
        return []
    }

    /// Changelog links first, then the source repository, then the homepage.
    static func rankedProjectURLs(_ links: [(String, String)]) -> [(String, String)] {
        func rank(_ label: String) -> Int {
            let lower = label.lowercased().filter(\.isLetter)
            if ["changelog", "changes", "releasenotes", "release", "releases", "history", "news", "whatsnew"].contains(where: lower.contains) { return 0 }
            if ["source", "repository", "code", "github"].contains(where: lower.contains) { return 1 }
            if ["homepage", "home"].contains(where: lower.contains) { return 2 }
            if lower.contains("documentation") || lower.contains("docs") { return 3 }
            return 4
        }
        return links.filter { !$0.1.isEmpty }.sorted { rank($0.0) < rank($1.0) }.filter { rank($0.0) < 4 }
    }

    private func applicationHints(_ item: CatalogItem, into hints: inout Hints) {
        guard let path = item.path else { return }
        let application = NativeApplicationProvider(homeDirectory: homeDirectory).application(atPath: path)
        let bundleIdentifier = item.bundleIdentifier ?? application?.bundleIdentifier
        switch item.updateSource {
        case NativeUpdateAuthority.appStore.rawValue:
            if let bundleIdentifier { hints.add(.appStore(bundleIdentifier: bundleIdentifier)) }
        case NativeUpdateAuthority.blackmagic.rawValue:
            if let bundleIdentifier, let product = BlackmagicDownloads.product(forBundleIdentifier: bundleIdentifier) {
                hints.add(.blackmagic(product: product))
            }
        default:
            break
        }
        if let application {
            if let feed = application.sparkleFeedURL.flatMap(URL.init(string:)), isPublicHTTPSURL(feed) {
                hints.add(.sparkle(feed, padding: !SparkleAppcastParser.bundlesSparkle1(application.bundlePath)))
            }
            if case let .github(repository)? = ElectronUpdateManifest(bundlePath: application.bundlePath)?.source { hints.add(repository) }
        }
        if path.contains("/steamapps/common/"), let appID = steamAppID(forPath: path) { hints.add(.steam(appID: appID)) }
        if let application {
            let bundled =
                Self.bundleChangelogFiles(application.bundlePath)
                + Self.appDataChangelogFiles(name: item.name, bundleIdentifier: bundleIdentifier, home: homeDirectory)
            if !bundled.isEmpty { hints.add(.localFiles(bundled)) }
            let urls = BundleURLScanner.urls(in: application)
            if let repository = BundleURLScanner.releaseRepository(in: urls, for: application) { hints.add(repository) }
            // A changelog page the app links to itself, on its own vendor's site (the domain its
            // bundle identifier names); links to other sites in a binary are often dependencies'.
            let vendor = bundleIdentifier.flatMap(Self.vendorDomain(bundleIdentifier:))
            for url in urls
            where isPublicHTTPSURL(url) && Self.looksLikeChangelogURL(url) && !url.path.hasSuffix(".xml") && !url.path.hasSuffix(".json")
                && !url.path.hasSuffix(".yml")
            {
                guard let host = url.host?.lowercased(), host != "github.com", let domain = HomebrewCaskCatalog.vendorDomain(host) else { continue }
                // The vendor's domain, or one named after the app (dynamiclake.com for DynamicLake Pro).
                let label = BundleURLScanner.matchKey(String(domain.split(separator: ".").first ?? ""))
                let appKey = BundleURLScanner.matchKey(item.name)
                guard domain == vendor || label.count >= 4 && appKey.hasPrefix(label) else { continue }
                hints.add(link: url.absoluteString)
            }
        }
        // Homebrew's cask for the same bundle: its homepage, and the GitHub project it downloads from.
        if let catalog = try? client.fetch(HomebrewCaskCatalog.url, resource: .homebrewCaskCatalog, derivedAs: "index-v2", HomebrewCaskCatalog.init(data:)) {
            let fileName = (path as NSString).lastPathComponent
            // By exact bundle identifier, or else (as the update check does) a cask with the
            // app's file name whose vendor domain the app references.
            let hosts = Set((application.map(BundleURLScanner.urls(in:)) ?? []).compactMap { $0.host?.lowercased() })
            if let entry = catalog.entry(bundleIdentifier: bundleIdentifier, bundleFileName: fileName)
                ?? catalog.entry(bundleFileName: fileName, referencedHosts: hosts)?.entry
            {
                homebrewAPIHints(token: entry.token, cask: true, into: &hints)
            }
        }
    }

    /// Changelog files an app keeps in its own data folders (VirtualDJ saves the one it downloads
    /// to Cache/changelog.txt), two levels deep.
    static func appDataChangelogFiles(name: String, bundleIdentifier: String?, home: String) -> [URL] {
        let homeURL = URL(filePath: home, directoryHint: .isDirectory)
        let names = [name, bundleIdentifier].compactMap { $0 }.filter { !$0.isEmpty && !$0.contains("/") && !$0.hasPrefix(".") }
        var folders: [URL] = []
        for folder in names {
            folders += [
                homeURL.appending(path: "Library/Application Support/\(folder)"), homeURL.appending(path: "Library/Caches/\(folder)"),
                homeURL.appending(path: "Documents/\(folder)")
            ]
        }
        var found: [URL] = []
        for folder in folders {
            found += changelogFiles(in: folder)
            for sub in ["Cache", "cache", "Resources", "Docs"] { found += changelogFiles(in: folder.appending(path: sub)) }
        }
        return found
    }

    /// "com.bjango.istatmenus" names bjango.com.
    static func vendorDomain(bundleIdentifier: String) -> String? {
        let parts = bundleIdentifier.lowercased().split(separator: ".")
        guard parts.count >= 2,
            ["com", "net", "org", "io", "app", "co", "de", "at", "ch", "fr", "uk", "dev", "ai", "me", "pl", "nl", "se"].contains(String(parts[0]))
        else { return nil }
        return "\(parts[1]).\(parts[0])"
    }

    private func steamAppID(named name: String) -> String? {
        let inventory = SteamProvider(
            steamDirectory: URL(filePath: homeDirectory).appending(path: "Library/Application Support/Steam", directoryHint: .isDirectory)
        ).discover()
        return inventory.libraries.flatMap(\.games).first { $0.name == name }?.appID
    }

    private func steamAppID(forPath path: String) -> String? {
        let inventory = SteamProvider(
            steamDirectory: URL(filePath: homeDirectory).appending(path: "Library/Application Support/Steam", directoryHint: .isDirectory)
        ).discover()
        return inventory.libraries.flatMap(\.games).first { path.hasPrefix($0.installDirectory + "/") }?.appID
    }
}
