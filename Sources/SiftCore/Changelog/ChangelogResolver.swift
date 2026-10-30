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

    public init(client: MetadataHTTPClient, homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path, storefront: String = Locale.current.region?.identifier.lowercased() ?? "us", environment: [String: String] = ProcessInfo.processInfo.environment, renderer: (@Sendable (URL) -> String?)? = nil) {
        self.client = client
        self.renderer = renderer
        self.homeDirectory = homeDirectory
        self.storefront = storefront.count == 2 && storefront.allSatisfy(\.isLetter) ? storefront : "us"
    }

    public func resolve(_ subject: ChangelogSubject) -> ChangelogResolution {
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
        var partial: (Source, [ChangelogEntry])?
        var extraTries = 0
        if client.debug { MetadataHTTPClient.trace("changelog sources for \(subject.item.selector): \(hints.sources.map(\.label).joined(separator: ", "))") }
        for source in hints.sources {
            do {
                let fetched = try fetch(source, hints: hints)
                // The app's own feed counts with a single version: it records each release as it appears.
                let versionCount = fetched.filter { ChangelogVersion.token(in: $0.version) == $0.version }.count
                if versionsOnly == nil, versionCount >= 2 || versionCount == 1 && { if case .sparkle = source { return true }; return false }() { versionsOnly = (source, fetched) }
                let entries = fetched.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if client.debug { MetadataHTTPClient.trace("\(source.label): \(entries.count) entries, \(entries.filter { !ChangelogDocument.isPlaceholder($0.content) }.count) with real content") }
                if ChangelogDocument.isMeaningful(entries) {
                    // A versioned changelog without the installed version may be a partial one
                    // (a short ChangeLog in the package, a feed of recent releases): the next
                    // source or two may cover more, and the better one wins.
                    let versioned = entries.filter { ChangelogVersion.token(in: $0.version) == $0.version }.count * 2 >= entries.count
                    // Covered means the installed version and, when there is an update, the update:
                    // a changelog file installed with the package stops at the installed version.
                    let coversInstalled = (hints.installed.map { ChangelogVersion.installedIndex(in: entries, installed: $0) != nil } ?? true)
                        && (hints.latest.map { latest in ChangelogVersion.installedIndex(in: entries, installed: latest) != nil || entries.first.flatMap { ChangelogVersion.token(in: $0.version) }.map { SparkleVersion.compare($0, latest) != .orderedAscending } ?? false } ?? true)
                    if versioned, !coversInstalled, extraTries < 2 {
                        if partial.map({ entries.count > $0.1.count }) ?? true { partial = (source, entries) }
                        extraTries += 1
                        tried.append("\(source.label): \(entries.count) versions, not the installed one")
                        continue
                    }
                    if let (better, betterEntries) = partial {
                        // A fuller source seen first is kept and this one fills in what it lacks
                        // (bash-language-server's releases plus the tags that reach its version).
                        if coversInstalled { return .resolved(source: "\(better.label) and \(source.label)", sourceURL: better.url, entries: Self.merge(betterEntries, entries)) }
                        if betterEntries.count > entries.count { return .resolved(source: better.label, sourceURL: better.url, entries: betterEntries) }
                    }
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
        if let (source, entries) = partial { return .resolved(source: source.label, sourceURL: source.url, entries: entries) }
        if let (source, entries) = versionsOnly { return .resolved(source: "\(source.label) (versions only)", sourceURL: source.url, entries: entries) }
        if tried.isEmpty { return .unavailable(["No changelog source is known for this item."]) }
        // A source that failed outright may have the changelog; that's worth retrying sooner.
        if let lastError, tried.allSatisfy({ !$0.hasSuffix(": not found") && !$0.hasSuffix("no versions found") && !$0.hasSuffix("only links elsewhere") }) { return .failure(lastError) }
        return .unavailable(tried)
    }

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
        case page(URL)

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
            case let .page(url): url.host.map { "\($0)\(url.path.count > 1 ? url.path : "")" } ?? url.absoluteString
            }
        }

        var url: String? {
            switch self {
            case let .localFiles(urls): urls.first?.path
            case let .sparkle(url, _): url.absoluteString
            case .appStore, .blackmagic: nil
            case let .steam(appID): "https://store.steampowered.com/news/app/\(appID)"
            case let .githubReleases(repository): "https://github.com/\(repository.path)/releases"
            case let .githubFile(repository), let .githubTags(repository): "https://github.com/\(repository.path)"
            case let .page(url): url.absoluteString
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
        case let .localFiles(urls): try localFiles(urls, installed: hints.installed)
        case let .sparkle(url, padding): try sparkle(url, padding: padding)
        case let .appStore(bundleIdentifier): try appStore(bundleIdentifier)
        case let .steam(appID): try steamNews(appID)
        case let .blackmagic(product): try blackmagic(product)
        case let .githubReleases(repository): try githubHistory(repository, installed: hints.installed, name: hints.name, preferCLI: hints.commandLine)
        case let .githubFile(repository): try githubFile(repository)
        case let .githubTags(repository): try githubTags(repository)
        case let .page(url): try page(url, name: hints.name)
        }
    }

    // MARK: Local files

    private static let changelogFileNames = ["changelog", "changes", "history", "news", "releases", "release-notes", "release_notes", "releasenotes", "release notes", "whatsnew", "whats-new", "whats new"]
    private static let changelogExtensions = ["", "md", "markdown", "txt", "rst", "html", "htm"]

    /// Changelog files inside an app bundle's resources (Tor Browser keeps one in
    /// Resources/TorBrowser/Docs), up to three folders deep.
    static func bundleChangelogFiles(_ bundlePath: String) -> [URL] {
        let resources = URL(filePath: bundlePath).appending(path: "Contents/Resources", directoryHint: .isDirectory)
        guard let enumerator = FileManager.default.enumerator(at: resources, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > 20_000 { break }
            if enumerator.level > 3 { enumerator.skipDescendants(); continue }
            let base = url.deletingPathExtension().lastPathComponent.lowercased()
            guard changelogFileNames.contains(base), changelogExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true, (values.fileSize ?? .max) <= 8 * 1_048_576 else { continue }
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
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true, (values.fileSize ?? .max) <= 8 * 1_048_576 else { continue }
                found.append(url)
            }
        }
        // CHANGELOG before NEWS or HISTORY: it's the one most often kept current.
        return found.sorted { changelogFileNames.firstIndex(of: $0.deletingPathExtension().lastPathComponent.lowercased())! < changelogFileNames.firstIndex(of: $1.deletingPathExtension().lastPathComponent.lowercased())! }
    }

    /// The best of the installed changelog files: the one with the installed version, then the
    /// one with the most versions (a git-log ChangeLog loses to a release-by-release NEWS).
    private func localFiles(_ urls: [URL], installed: String?) throws -> [ChangelogEntry] {
        let parsed = urls.map { url -> [ChangelogEntry] in
            guard let data = try? Data(contentsOf: url) else { return [] }
            let text = String(decoding: data, as: UTF8.self)
            return ["html", "htm"].contains(url.pathExtension.lowercased()) ? Self.pageEntries(text, url: url) : ChangelogDocument.entries(fromMarkdown: text, sourceURL: nil)
        }
        return parsed.max { left, right in
            let a = installed.map { ChangelogVersion.installedIndex(in: left, installed: $0) != nil } ?? false
            let b = installed.map { ChangelogVersion.installedIndex(in: right, installed: $0) != nil } ?? false
            return a == b ? left.count < right.count : !a
        } ?? []
    }

    // MARK: Sparkle

    private func sparkle(_ url: URL, padding: Bool) throws -> [ChangelogEntry] {
        guard let host = url.host?.lowercased() else { throw MetadataHTTPError.unsupportedURL }
        let items = try SparkleAppcastParser.parse(client.fetch(url, resource: .sparkleAppcast(host: host)).body)
            .filter { $0.channel == nil }
            .sorted { SparkleVersion.compare($0.version, $1.version, padding: padding) == .orderedDescending }
        var entries: [ChangelogEntry] = []
        var linkedPages = 0
        var linkedSplit: [ChangelogEntry]?
        for item in items {
            var content = item.releaseNotesHTML.map(HTMLMarkdown.convert) ?? ""
            var source: String?
            // A feed that only links to its notes: the linked page, for the newest releases.
            // The link is the item's releaseNotesLink, or one inside the placeholder text itself.
            let embedded = item.releaseNotesHTML.flatMap { html in HTMLMarkdown.links(in: html, base: url).first?.url }
            if ChangelogDocument.isPlaceholder(content), let linkedSplit, let own = linkedSplit.first(where: { ChangelogVersion.matches($0.version, ChangelogVersion.normalized(item.displayVersion)) }) {
                content = own.content
            } else if ChangelogDocument.isPlaceholder(content), linkedPages < 12,
               let link = item.releaseNotesURL.flatMap(URL.init(string:)) ?? embedded, isPublicHTTPSURL(link), let linkHost = link.host {
                linkedPages += 1
                if let html = try? fetchText(link, resource: .changelogPage(host: linkHost)) {
                    // A page that covers every version is split, and this version's part kept;
                    // a script-built page is rendered first.
                    let split = read(html, url: link, render: true)
                    let own = split.first { ChangelogVersion.matches($0.version, ChangelogVersion.normalized(item.displayVersion)) }?.content
                    let whole = HTMLMarkdown.convert(html)
                    content = own ?? (split.count == 1 ? split[0].content : ChangelogDocument.isPlaceholder(whole) ? content : whole)
                    source = link.absoluteString
                    // Older items in the same feed usually link to the same page.
                    if split.count > 1 { linkedSplit = split }
                } else if let linkedSplit, let own = linkedSplit.first(where: { ChangelogVersion.matches($0.version, ChangelogVersion.normalized(item.displayVersion)) }) {
                    content = own.content
                }
            }
            entries.append(ChangelogEntry(version: item.displayVersion, date: item.publishedAt.flatMap(Self.rfc822Date), content: content, sourceURL: source))
        }
        return entries
    }

    static func rfc822Date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text.trimmingCharacters(in: .whitespaces)) { return date }
        }
        return ChangelogDocument.date(in: text)
    }

    // MARK: App Store

    private func appStore(_ bundleIdentifier: String) throws -> [ChangelogEntry] {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [URLQueryItem(name: "bundleId", value: bundleIdentifier), URLQueryItem(name: "country", value: storefront), URLQueryItem(name: "entity", value: "macSoftware")]
        let data = try client.fetch(components.url!, resource: .appStoreLookup).body
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any], let results = document["results"] as? [[String: Any]],
              let listing = results.first(where: { $0["bundleId"] as? String == bundleIdentifier && $0["kind"] as? String == "mac-software" }) ?? results.first(where: { $0["bundleId"] as? String == bundleIdentifier }) else { throw MetadataHTTPError.notFound }
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
            guard let data = HTMLText.decodeEntities(String(match.1)).data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { continue }
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
              let news = (document["appnews"] as? [String: Any])?["newsitems"] as? [[String: Any]] else { throw MetadataHTTPError.invalidResponse }
        let items = news.compactMap { item -> (entry: ChangelogEntry, patch: Bool)? in
            guard let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, let contents = item["contents"] as? String else { return nil }
            let date = (item["date"] as? Double).map(Date.init(timeIntervalSince1970:))
            let tags = (item["tags"] as? [String]) ?? []
            let lower = title.lowercased()
            let patch = tags.contains("patchnotes") || ["patch", "update", "hotfix", "fix", "release notes", "changelog", "version", "build"].contains { lower.contains($0) } || ChangelogVersion.token(in: title) != nil
            return (ChangelogEntry(version: title, title: nil, date: date, content: ChangelogDocument.markdown(fromBBCode: contents), sourceURL: item["url"] as? String), patch)
        }
        // Patch notes when the game posts them; every announcement otherwise.
        let patches = items.filter(\.patch).map(\.entry)
        return patches.isEmpty ? items.map(\.entry) : patches
    }

    // MARK: Blackmagic

    private func blackmagic(_ product: String) throws -> [ChangelogEntry] {
        let data = try client.fetch(BlackmagicDownloads.url, resource: .blackmagicDownloads).body
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any], let downloads = document["downloads"] as? [[String: Any]] else { throw MetadataHTTPError.invalidResponse }
        var entries: [(ChangelogEntry, (Int, Int, Int))] = []
        for download in downloads {
            guard let name = download["name"] as? String, !name.localizedCaseInsensitiveContains("beta"),
                  let urls = download["urls"] as? [String: Any], let mac = urls["Mac OS X"] as? [[String: Any]],
                  let release = mac.first(where: { $0["product"] as? String == product }),
                  let major = release["major"] as? Int, let minor = release["minor"] as? Int else { continue }
            let number = (major, minor, release["releaseNum"] as? Int ?? 0)
            let version = number.2 == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(number.2)"
            let html = (download["desc"] as? String) ?? ""
            let date = (download["date"] as? String).flatMap { ChangelogDocument.date(in: $0) ?? Self.rfc822Date($0) }
            entries.append((ChangelogEntry(version: version, title: name, date: date, content: HTMLMarkdown.convert(html)), number))
        }
        return entries.sorted { $0.1 > $1.1 }.map(\.0)
    }

    // MARK: GitHub

    private func githubReleases(_ repository: GitHubRepository, name currentName: String = "", preferCLI: Bool = false) throws -> [ChangelogEntry] {
        guard let owner = encodeGitHubPathComponent(repository.owner), let name = encodeGitHubPathComponent(repository.name) else { throw MetadataHTTPError.unsupportedURL }
        var entries: [ChangelogEntry] = []
        for page in 1...githubPages {
            let url = URL(string: "https://api.github.com/repos/\(owner)/\(name)/releases?per_page=100&page=\(page)")!
            let data: Data
            do { data = try client.fetch(url, resource: .githubReleaseList).body }
            catch where page > 1 { break }
            catch MetadataHTTPError.rateLimited, MetadataHTTPError.forbidden {
                // Out of API quota: the releases feed has the latest ten without spending any.
                let feed = URL(string: "https://github.com/\(owner)/\(name)/releases.atom")!
                return ChangelogFeeds.entries(fromFeed: try client.fetch(feed, resource: .changelogPage(host: "github.com")).body)
            }
            guard let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw MetadataHTTPError.invalidResponse }
            for release in releases where release["draft"] as? Bool != true && release["prerelease"] as? Bool != true {
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
                entries.append(ChangelogEntry(version: version, title: titled, date: date, content: body, sourceURL: release["html_url"] as? String ?? "https://github.com/\(repository.path)/releases/tag/\(tag)"))
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
        if groups.count == 1, let only = groups.keys.first {
            return only.isEmpty || key.isEmpty || key.contains(only) || only.contains(key) ? entries : []
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
        let kept = (best.map { groups[$0] ?? [] } ?? []) + (groups[""] ?? [])
        return kept.sorted { left, right in
            guard let a = ChangelogVersion.token(in: left.version), let b = ChangelogVersion.token(in: right.version) else { return false }
            return SparkleVersion.compare(a, b) == .orderedDescending
        }
    }

    /// A repository's releases, with its changelog file filling in versions the releases don't
    /// cover (projects that started publishing releases late, or skip some).
    private func githubHistory(_ repository: GitHubRepository, installed: String?, name: String = "", preferCLI: Bool = false) throws -> [ChangelogEntry] {
        let releases = try githubReleases(repository, name: name, preferCLI: preferCLI)
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
            if let index = merged.firstIndex(where: { ChangelogVersion.matches($0.version, entry.version) || ChangelogVersion.matches(entry.version, $0.version) }) {
                if ChangelogDocument.isPlaceholder(merged[index].content) {
                    let old = merged[index]
                    merged[index] = ChangelogEntry(version: old.version, title: old.title ?? entry.title, date: old.date ?? entry.date, content: entry.content, sourceURL: entry.sourceURL ?? old.sourceURL)
                }
            } else {
                merged.append(entry)
            }
        }
        return merged.sorted { left, right in
            guard let a = ChangelogVersion.token(in: left.version), let b = ChangelogVersion.token(in: right.version) else { return false }
            return SparkleVersion.compare(a, b) == .orderedDescending
        }
    }

    /// For a repository with no releases and no changelog: its version tags, newest first, each
    /// with the commits since the tag before it (for the newest few; GitHub's anonymous quota is
    /// small).
    private func githubTags(_ repository: GitHubRepository) throws -> [ChangelogEntry] {
        guard let owner = encodeGitHubPathComponent(repository.owner), let name = encodeGitHubPathComponent(repository.name) else { throw MetadataHTTPError.unsupportedURL }
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(name)/tags?per_page=100")!
        guard let tags = try JSONSerialization.jsonObject(with: client.fetch(url, resource: .githubReleaseList).body) as? [[String: Any]] else { throw MetadataHTTPError.invalidResponse }
        let versioned = tags.compactMap { tag -> (name: String, version: String, sha: String)? in
            guard let name = tag["name"] as? String, let version = ChangelogVersion.token(in: name), let sha = (tag["commit"] as? [String: Any])?["sha"] as? String else { return nil }
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
               let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let commits = document["commits"] as? [[String: Any]] {
                let messages = commits.compactMap { (($0["commit"] as? [String: Any])?["message"] as? String)?.split(separator: "\n").first.map(String.init) }
                    .filter { !$0.lowercased().hasPrefix("merge ") }
                content = messages.reversed().map { "- \($0)" }.joined(separator: "\n")
                date = ((commits.last?["commit"] as? [String: Any])?["committer"] as? [String: Any])?["date"].flatMap { $0 as? String }.flatMap { ISO8601DateFormatter().date(from: $0) }
            }
            entries.append(ChangelogEntry(version: tag.version, title: nil, date: date, content: content, sourceURL: "https://github.com/\(repository.path)/releases/tag/\(tag.name)"))
        }
        return entries
    }

    // Raw file paths are case-sensitive, so the common spellings are each tried (a missing one
    // is a cached 404, and raw files don't count against the API quota).
    private static let repositoryChangelogPaths = ["CHANGELOG.md", "ChangeLog.md", "Changelog.md", "changelog.md", "CHANGES.md", "Changes.md", "HISTORY.md", "History.md", "NEWS.md", "RELEASES.md", "RELEASE_NOTES.md", "RELEASE-NOTES.md", "CHANGELOG", "ChangeLog", "Changelog", "CHANGES", "NEWS", "HISTORY", "docs/changelog.md", "docs/CHANGELOG.md", "docs/CHANGES.md", "CHANGELOG.rst", "CHANGES.rst", "HISTORY.rst", "NEWS.rst", "docs/changelog.rst", "CHANGELOG.txt", "NEWS.txt"]

    private func githubFile(_ repository: GitHubRepository) throws -> [ChangelogEntry] {
        guard let owner = encodeGitHubPathComponent(repository.owner), let name = encodeGitHubPathComponent(repository.name) else { throw MetadataHTTPError.unsupportedURL }
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
    func page(_ url: URL, name: String = "") throws -> [ChangelogEntry] {
        guard let host = url.host?.lowercased() else { throw MetadataHTTPError.unsupportedURL }
        let html = try fetchText(url, resource: .changelogPage(host: host))
        let isChangelogPage = Self.looksLikeChangelogURL(url)
        // A homepage's own text, then its changelog links, and only then its feeds (often a
        // blog covering other products) and embedded data.
        var entries = isChangelogPage ? read(html, url: url, render: true) : Self.pageEntries(html, url: url)
        if entries.count >= 2 || ChangelogDocument.isMeaningful(entries) && isChangelogPage { return entries }
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
            let linkedEntries = read(linked, url: link, render: true)
            if ChangelogDocument.isMeaningful(linkedEntries) { return linkedEntries }
        }
        if !isChangelogPage {
            let more = read(html, url: url, render: false)
            if ChangelogDocument.isMeaningful(more) && more.count >= 2 { return more }
            if entries.isEmpty { entries = more }
        }
        if ChangelogDocument.isMeaningful(repositoryHistory) { return repositoryHistory }
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
    private func read(_ html: String, url: URL, render: Bool) -> [ChangelogEntry] {
        let entries = Self.pageEntries(html, url: url)
        if entries.count >= 2, ChangelogDocument.isMeaningful(entries) { return entries }
        for feed in ChangelogFeeds.advertisedFeeds(in: html, base: url).prefix(2) where isPublicHTTPSURL(feed) {
            guard let feedHost = feed.host, let data = try? client.fetch(feed, resource: .changelogPage(host: feedHost)).body else { continue }
            let items = ChangelogFeeds.entries(fromFeed: data)
            // A blog feed counts only when most of its posts are releases, and only those are kept.
            let releases = items.filter { ChangelogVersion.token(in: $0.version) == $0.version }
            if releases.count >= 3 || releases.count >= 2 && releases.count * 5 >= items.count * 3 {
                if client.debug { MetadataHTTPClient.trace("read feed \(feed.absoluteString): \(releases.count) releases") }
                return releases
            }
        }
        let embedded = ChangelogFeeds.embeddedEntries(in: html)
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
        let isHTML = text.range(of: "<html", options: .caseInsensitive) != nil || text.range(of: "<h[1-6]", options: [.regularExpression, .caseInsensitive]) != nil
        return ChangelogDocument.entries(fromMarkdown: isHTML ? HTMLMarkdown.convert(text) : text, sourceURL: url.absoluteString)
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

    private static let changelogWords = ["changelog", "change log", "changes", "release notes", "release-notes", "releasenotes", "releases", "what's new", "whats-new", "whatsnew", "what’s new", "version history", "history", "news", "updates"]

    static func looksLikeChangelogURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return changelogWords.contains { path.contains($0.replacingOccurrences(of: " ", with: "-")) || path.contains($0.replacingOccurrences(of: " ", with: "")) }
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
                if path.contains(word.replacingOccurrences(of: " ", with: "-")) || path.contains(word.replacingOccurrences(of: " ", with: "")) { score = max(score, 30 - rank) }
            }
            guard score > 0 else { continue }
            let host = link.url.host?.lowercased() ?? ""
            if site != nil, HomebrewCaskCatalog.vendorDomain(host) == site { score += 20 } else if host != "github.com" { score -= 25 }
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
                for file in Self.changelogFiles(in: keg) + Self.changelogFiles(in: keg.appending(path: "share/doc").appending(path: item.name)) { hints.add(.localFiles([file])) }
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
            return [.page(URL(string: "https://go.dev/doc/devel/release")!)]
        case (.nativeApp, let id) where id.hasPrefix("org.python.") && minor.split(separator: ".").count == 2:
            return [.page(URL(string: "https://docs.python.org/\(minor)/whatsnew/changelog.html")!)]
        case (.homebrewFormula, let name) where name.hasPrefix("python@"):
            return [.page(URL(string: "https://docs.python.org/\(name.dropFirst(7))/whatsnew/changelog.html")!)]
        case (.nativeApp, "com.image-line.flstudio"), (.nativeApp, "com.image-line.fl-cloud-plugins"):
            return [.page(URL(string: "https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/WhatsNew.htm")!)]
        case (.nativeApp, "com.valvesoftware.steam"):
            return [.steam(appID: "593110")]
        case (.homebrewCask, "claude-code"), (.homebrewFormula, "claude-code"):
            return [.githubFile(GitHubRepository(owner: "anthropics", name: "claude-code"))]
        default:
            return []
        }
    }

    /// Homebrew's API: a formula's homepage and source, or a cask's homepage and download URL.
    private func homebrewAPIHints(token: String, cask: Bool, into hints: inout Hints) {
        guard let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))),
              let url = URL(string: "https://formulae.brew.sh/api/\(cask ? "cask" : "formula")/\(encoded).json"),
              let data = try? client.fetch(url, resource: .packageRegistry).body,
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let urls = document["urls"] as? [String: Any]
        let stable = (urls?["stable"] as? [String: Any])?["url"] as? String
        let head = (urls?["head"] as? [String: Any])?["url"] as? String
        for link in [stable, head, document["url"] as? String] {
            guard let link, let url = URL(string: link) else { continue }
            if let github = GitHubSource.parse(url) { hints.add(github.repository) } else { registryHints(forDownload: url, into: &hints) }
        }
        hints.add(link: document["homepage"] as? String)
    }

    /// A download from PyPI, npm, or crates.io names the package there, whose metadata names
    /// its repository: Homebrew's rich-cli downloads from PyPI, fish-lsp from npm.
    private func registryHints(forDownload url: URL, into hints: inout Hints) {
        let host = url.host?.lowercased() ?? ""
        let parts = url.path.split(separator: "/").map(String.init)
        if host == "files.pythonhosted.org" || host == "pypi.io" || host == "pypi.org", let file = parts.last,
           let match = file.firstMatch(of: #/^(.+?)-\d[^-]*\.(tar\.gz|zip|whl|tar\.bz2)$/#) {
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
              let info = document["info"] as? [String: Any] else { return }
        let links = ((info["project_urls"] as? [String: String]) ?? [:]).map { ($0.key, $0.value) } + [("Homepage", (info["home_page"] as? String) ?? "")]
        for (_, link) in Self.rankedProjectURLs(links) { hints.add(link: link) }
    }

    private func npmHints(_ name: String, into hints: inout Hints) {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "https://registry.npmjs.org/\(encoded)/latest"),
              let data = try? client.fetch(url, resource: .packageRegistry).body, let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        hints.add(link: (manifest["repository"] as? String) ?? ((manifest["repository"] as? [String: Any])?["url"] as? String))
        hints.add(link: manifest["homepage"] as? String)
    }

    private func cratesHints(_ name: String, into hints: inout Hints) {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "https://crates.io/api/v1/crates/\(encoded)"),
              let data = try? client.fetch(url, resource: .packageRegistry).body, let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let crate = document["crate"] as? [String: Any] else { return }
        hints.add(link: crate["repository"] as? String)
        hints.add(link: crate["homepage"] as? String)
    }

    private func packageHints(_ item: CatalogItem, into hints: inout Hints) {
        let scope = URL(filePath: item.prefix ?? "/nonexistent")
        switch item.updateSource {
        case RefreshProvider.npmGlobal.rawValue:
            let package = scope.appending(path: "lib/node_modules").appending(path: item.name)
            for file in Self.changelogFiles(in: package) { hints.add(.localFiles([file])) }
            if let data = try? Data(contentsOf: package.appending(path: "package.json")), let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
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
            if let version = item.installedVersion, let sources = try? FileManager.default.contentsOfDirectory(atPath: scope.appending(path: "registry/src").path) {
                for registry in sources.sorted() {
                    let crate = scope.appending(path: "registry/src").appending(path: registry).appending(path: "\(item.name)-\(version)")
                    for file in Self.changelogFiles(in: crate) { hints.add(.localFiles([file])) }
                    if let manifest = try? String(contentsOf: crate.appending(path: "Cargo.toml"), encoding: .utf8) {
                        for key in ["repository", "homepage"] {
                            if let match = manifest.firstMatch(of: try! Regex("(?m)^\\s*\(key)\\s*=\\s*\"([^\"]+)\"")) { hints.add(link: String(match.output[1].substring ?? "")) }
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
                  let metadata = try? String(contentsOf: site.appending(path: info).appending(path: "METADATA"), encoding: .utf8) else { continue }
            var links: [(String, String)] = []
            for line in metadata.components(separatedBy: "\n") {
                if line.hasPrefix("Project-URL:") {
                    let value = line.dropFirst(12).split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if value.count == 2 { links.append((value[0], value[1])) }
                } else if line.hasPrefix("Home-page:") {
                    links.append(("Homepage", line.dropFirst(10).trimmingCharacters(in: .whitespaces)))
                } else if line.isEmpty { break }
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
            if let bundleIdentifier, let product = BlackmagicDownloads.product(forBundleIdentifier: bundleIdentifier) { hints.add(.blackmagic(product: product)) }
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
            let bundled = Self.bundleChangelogFiles(application.bundlePath)
            if !bundled.isEmpty { hints.add(.localFiles(bundled)) }
            let urls = BundleURLScanner.urls(in: application)
            if let repository = BundleURLScanner.releaseRepository(in: urls, for: application) { hints.add(repository) }
            // A changelog page the app links to itself, on its own vendor's site (the domain its
            // bundle identifier names); links to other sites in a binary are often dependencies'.
            let vendor = bundleIdentifier.flatMap(Self.vendorDomain(bundleIdentifier:))
            for url in urls where isPublicHTTPSURL(url) && Self.looksLikeChangelogURL(url) && !url.path.hasSuffix(".xml") && !url.path.hasSuffix(".json") && !url.path.hasSuffix(".yml") {
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
            if let entry = catalog.entry(bundleIdentifier: bundleIdentifier, bundleFileName: fileName) ?? catalog.entry(bundleFileName: fileName, referencedHosts: hosts)?.entry {
                homebrewAPIHints(token: entry.token, cask: true, into: &hints)
            }
        }
    }

    /// "com.bjango.istatmenus" names bjango.com.
    static func vendorDomain(bundleIdentifier: String) -> String? {
        let parts = bundleIdentifier.lowercased().split(separator: ".")
        guard parts.count >= 2, ["com", "net", "org", "io", "app", "co", "de", "at", "ch", "fr", "uk", "dev", "ai", "me", "pl", "nl", "se"].contains(String(parts[0])) else { return nil }
        return "\(parts[1]).\(parts[0])"
    }

    private func steamAppID(named name: String) -> String? {
        let inventory = SteamProvider(steamDirectory: URL(filePath: homeDirectory).appending(path: "Library/Application Support/Steam", directoryHint: .isDirectory)).discover()
        return inventory.libraries.flatMap(\.games).first { $0.name == name }?.appID
    }

    private func steamAppID(forPath path: String) -> String? {
        let inventory = SteamProvider(steamDirectory: URL(filePath: homeDirectory).appending(path: "Library/Application Support/Steam", directoryHint: .isDirectory)).discover()
        return inventory.libraries.flatMap(\.games).first { path.hasPrefix($0.installDirectory + "/") }?.appID
    }
}
