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
    private let githubPages: Int
    /// Renders a script-built page to HTML (WebKit, in a child process); nil leaves such pages unread.
    private let renderer: (@Sendable (URL) -> String?)?

    public init(client: MetadataHTTPClient, homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path, storefront: String = Locale.current.region?.identifier.lowercased() ?? "us", environment: [String: String] = ProcessInfo.processInfo.environment, renderer: (@Sendable (URL) -> String?)? = nil) {
        self.client = client
        self.renderer = renderer
        self.homeDirectory = homeDirectory
        self.storefront = storefront.count == 2 && storefront.allSatisfy(\.isLetter) ? storefront : "us"
        // 100 releases a page; anonymous access has 60 requests an hour to spend.
        githubPages = environment["GITHUB_TOKEN"] ?? environment["GH_TOKEN"] != nil ? 10 : 3
    }

    public func resolve(_ subject: ChangelogSubject) -> ChangelogResolution {
        var hints = Hints()
        gatherHints(subject, into: &hints)
        var tried: [String] = []
        var lastError: String?
        if client.debug { MetadataHTTPClient.trace("changelog sources for \(subject.item.selector): \(hints.sources.map(\.label).joined(separator: ", "))") }
        for source in hints.sources {
            do {
                let entries = try fetch(source).filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if client.debug { MetadataHTTPClient.trace("\(source.label): \(entries.count) entries, \(entries.filter { !ChangelogDocument.isPlaceholder($0.content) }.count) with real content") }
                if ChangelogDocument.isMeaningful(entries) {
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
        if tried.isEmpty { return .unavailable(["No changelog source is known for this item."]) }
        // A source that failed outright may have the changelog; that's worth retrying sooner.
        if let lastError, tried.allSatisfy({ !$0.hasSuffix(": not found") && !$0.hasSuffix("no versions found") && !$0.hasSuffix("only links elsewhere") }) { return .failure(lastError) }
        return .unavailable(tried)
    }

    // MARK: - Sources

    enum Source: Equatable {
        case localFile(URL)
        case sparkle(URL, padding: Bool)
        case appStore(bundleIdentifier: String)
        case steam(appID: String)
        case blackmagic(product: String)
        case githubReleases(GitHubRepository)
        case githubFile(GitHubRepository)
        case page(URL)

        var label: String {
            switch self {
            case let .localFile(url): url.lastPathComponent
            case .sparkle: "the app's update feed"
            case .appStore: "the App Store"
            case .steam: "Steam news"
            case .blackmagic: "Blackmagic's downloads"
            case let .githubReleases(repository): "GitHub releases (\(repository.path))"
            case let .githubFile(repository): "changelog in \(repository.path)"
            case let .page(url): url.host.map { "\($0)\(url.path.count > 1 ? url.path : "")" } ?? url.absoluteString
            }
        }

        var url: String? {
            switch self {
            case let .localFile(url): url.path
            case let .sparkle(url, _): url.absoluteString
            case .appStore, .blackmagic: nil
            case let .steam(appID): "https://store.steampowered.com/news/app/\(appID)"
            case let .githubReleases(repository): "https://github.com/\(repository.path)/releases"
            case let .githubFile(repository): "https://github.com/\(repository.path)"
            case let .page(url): url.absoluteString
            }
        }
    }

    struct Hints {
        private(set) var sources: [Source] = []
        private var repositories: [String] = []

        mutating func add(_ source: Source) {
            if !sources.contains(source) { sources.append(source) }
        }

        /// A repository adds its releases first, then its changelog file.
        mutating func add(_ repository: GitHubRepository) {
            guard !repositories.contains(repository.path.lowercased()) else { return }
            repositories.append(repository.path.lowercased())
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

    private func fetch(_ source: Source) throws -> [ChangelogEntry] {
        switch source {
        case let .localFile(url): try localFile(url)
        case let .sparkle(url, padding): try sparkle(url, padding: padding)
        case let .appStore(bundleIdentifier): try appStore(bundleIdentifier)
        case let .steam(appID): try steamNews(appID)
        case let .blackmagic(product): try blackmagic(product)
        case let .githubReleases(repository): try githubReleases(repository)
        case let .githubFile(repository): try githubFile(repository)
        case let .page(url): try page(url)
        }
    }

    // MARK: Local files

    private static let changelogFileNames = ["changelog", "changes", "history", "news", "releases", "release-notes", "release_notes", "releasenotes", "whatsnew", "whats-new"]
    private static let changelogExtensions = ["", "md", "markdown", "txt", "rst"]

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

    private func localFile(_ url: URL) throws -> [ChangelogEntry] {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        return ChangelogDocument.entries(fromMarkdown: text, sourceURL: nil)
    }

    // MARK: Sparkle

    private func sparkle(_ url: URL, padding: Bool) throws -> [ChangelogEntry] {
        guard let host = url.host?.lowercased() else { throw MetadataHTTPError.unsupportedURL }
        let items = try SparkleAppcastParser.parse(client.fetch(url, resource: .sparkleAppcast(host: host)).body)
            .filter { $0.channel == nil }
            .sorted { SparkleVersion.compare($0.version, $1.version, padding: padding) == .orderedDescending }
        var entries: [ChangelogEntry] = []
        var linkedPages = 0
        for item in items {
            var content = item.releaseNotesHTML.map(HTMLMarkdown.convert) ?? ""
            var source: String?
            // A feed that only links to its notes: the linked page, for the newest releases.
            // The link is the item's releaseNotesLink, or one inside the placeholder text itself.
            let embedded = item.releaseNotesHTML.flatMap { html in HTMLMarkdown.links(in: html, base: url).first?.url }
            if ChangelogDocument.isPlaceholder(content), linkedPages < 12,
               let link = item.releaseNotesURL.flatMap(URL.init(string:)) ?? embedded, isPublicHTTPSURL(link), let linkHost = link.host {
                linkedPages += 1
                if let html = try? fetchText(link, resource: .changelogPage(host: linkHost)) {
                    let converted = HTMLMarkdown.convert(html)
                    // A page that covers every version is split, and this version's part kept.
                    let split = ChangelogDocument.entries(fromMarkdown: converted, sourceURL: link.absoluteString)
                    content = split.first { ChangelogVersion.matches($0.version, ChangelogVersion.normalized(item.displayVersion)) }?.content ?? converted
                    source = link.absoluteString
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
        let url = URL(string: "https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/?appid=\(appID)&count=100&maxlength=0&format=json&feeds=steam_community_announcements")!
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

    private func githubReleases(_ repository: GitHubRepository) throws -> [ChangelogEntry] {
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
                entries.append(ChangelogEntry(version: version, title: titled, date: date, content: body, sourceURL: release["html_url"] as? String))
            }
            if releases.count < 100 { break }
        }
        return entries
    }

    private static let repositoryChangelogPaths = ["CHANGELOG.md", "CHANGES.md", "HISTORY.md", "NEWS.md", "RELEASES.md", "RELEASE_NOTES.md", "CHANGELOG", "NEWS", "docs/changelog.md", "docs/CHANGELOG.md", "CHANGELOG.rst", "CHANGES.rst", "HISTORY.rst", "NEWS.rst", "docs/changelog.rst"]

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
    func page(_ url: URL) throws -> [ChangelogEntry] {
        guard let host = url.host?.lowercased() else { throw MetadataHTTPError.unsupportedURL }
        let html = try fetchText(url, resource: .changelogPage(host: host))
        let entries = read(html, url: url, render: Self.looksLikeChangelogURL(url))
        if entries.count >= 2 || ChangelogDocument.isMeaningful(entries) && Self.looksLikeChangelogURL(url) { return entries }
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
            // A blog feed counts only when its posts are releases.
            if items.filter({ ChangelogVersion.token(in: $0.version) == $0.version }).count >= 2 {
                if client.debug { MetadataHTTPClient.trace("read feed \(feed.absoluteString): \(items.count) items") }
                return items
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
        switch item.kind {
        case .homebrewFormula, .homebrewCask:
            let isCask = item.kind == .homebrewCask
            if let prefix = item.prefix, let version = item.installedVersion, !isCask {
                let keg = URL(filePath: prefix).appending(path: "Cellar").appending(path: item.name).appending(path: version)
                for file in Self.changelogFiles(in: keg) + Self.changelogFiles(in: keg.appending(path: "share/doc").appending(path: item.name)) { hints.add(.localFile(file)) }
            }
            if let source = subject.homebrewSourceURL.flatMap(URL.init(string:)), let github = GitHubSource.parse(source) { hints.add(github.repository) }
            homebrewAPIHints(token: item.name, cask: isCask, into: &hints)
        case .package:
            packageHints(item, into: &hints)
        case .nativeApp:
            applicationHints(item, into: &hints)
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
            if let link, let url = URL(string: link), let github = GitHubSource.parse(url) { hints.add(github.repository) }
        }
        hints.add(link: document["homepage"] as? String)
    }

    private func packageHints(_ item: CatalogItem, into hints: inout Hints) {
        let scope = URL(filePath: item.prefix ?? "/nonexistent")
        switch item.updateSource {
        case RefreshProvider.npmGlobal.rawValue:
            let package = scope.appending(path: "lib/node_modules").appending(path: item.name)
            for file in Self.changelogFiles(in: package) { hints.add(.localFile(file)) }
            if let data = try? Data(contentsOf: package.appending(path: "package.json")), let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                hints.add(link: (manifest["repository"] as? String) ?? ((manifest["repository"] as? [String: Any])?["url"] as? String))
                hints.add(link: manifest["homepage"] as? String)
            } else if let encoded = item.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "https://registry.npmjs.org/\(encoded)/latest"),
                      let data = try? client.fetch(url, resource: .packageRegistry).body, let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                hints.add(link: (manifest["repository"] as? String) ?? ((manifest["repository"] as? [String: Any])?["url"] as? String))
                hints.add(link: manifest["homepage"] as? String)
            }
        case RefreshProvider.uvTools.rawValue:
            var links = Self.pythonProjectURLs(toolDirectory: scope.appending(path: item.name), name: item.name)
            if links.isEmpty, let encoded = item.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "https://pypi.org/pypi/\(encoded)/json"),
               let data = try? client.fetch(url, resource: .packageRegistry).body, let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let info = document["info"] as? [String: Any] {
                links = ((info["project_urls"] as? [String: String]) ?? [:]).map { ($0.key, $0.value) } + [("Homepage", (info["home_page"] as? String) ?? "")]
            }
            for (_, link) in Self.rankedProjectURLs(links) { hints.add(link: link) }
        case RefreshProvider.cargo.rawValue:
            if let version = item.installedVersion, let sources = try? FileManager.default.contentsOfDirectory(atPath: scope.appending(path: "registry/src").path) {
                for registry in sources.sorted() {
                    let crate = scope.appending(path: "registry/src").appending(path: registry).appending(path: "\(item.name)-\(version)")
                    for file in Self.changelogFiles(in: crate) { hints.add(.localFile(file)) }
                    if let manifest = try? String(contentsOf: crate.appending(path: "Cargo.toml"), encoding: .utf8) {
                        for key in ["repository", "homepage"] {
                            if let match = manifest.firstMatch(of: try! Regex("(?m)^\\s*\(key)\\s*=\\s*\"([^\"]+)\"")) { hints.add(link: String(match.output[1].substring ?? "")) }
                        }
                    }
                }
            }
            if let encoded = item.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "https://crates.io/api/v1/crates/\(encoded)"),
               let data = try? client.fetch(url, resource: .packageRegistry).body, let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let crate = document["crate"] as? [String: Any] {
                hints.add(link: crate["repository"] as? String)
                hints.add(link: crate["homepage"] as? String)
            }
        case RefreshProvider.steamGames.rawValue:
            if let appID = item.identifier { hints.add(.steam(appID: appID)) }
        case RefreshProvider.macPorts.rawValue:
            // Ports have no metadata Sift reads; Homebrew's formula of the same name usually is
            // the same project.
            let base = item.name.replacing(#/^py\d+-/#, with: "")
            homebrewAPIHints(token: base.lowercased(), cask: false, into: &hints)
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
            let urls = BundleURLScanner.urls(in: application)
            if let repository = BundleURLScanner.releaseRepository(in: urls, for: application) { hints.add(repository) }
            // A changelog or release-notes page the app links to itself.
            for url in urls where isPublicHTTPSURL(url) && Self.looksLikeChangelogURL(url) && !url.path.hasSuffix(".xml") && !url.path.hasSuffix(".json") && !url.path.hasSuffix(".yml") {
                hints.add(link: url.absoluteString)
            }
        }
        // Homebrew's cask for the same bundle: its homepage, and the GitHub project it downloads from.
        if let catalog = try? client.fetch(HomebrewCaskCatalog.url, resource: .homebrewCaskCatalog, derivedAs: "index-v2", HomebrewCaskCatalog.init(data:)),
           let entry = catalog.entry(bundleIdentifier: bundleIdentifier, bundleFileName: (path as NSString).lastPathComponent) {
            homebrewAPIHints(token: entry.token, cask: true, into: &hints)
        }
    }

    private func steamAppID(forPath path: String) -> String? {
        let inventory = SteamProvider(steamDirectory: URL(filePath: homeDirectory).appending(path: "Library/Application Support/Steam", directoryHint: .isDirectory)).discover()
        return inventory.libraries.flatMap(\.games).first { path.hasPrefix($0.installDirectory + "/") }?.appID
    }
}
