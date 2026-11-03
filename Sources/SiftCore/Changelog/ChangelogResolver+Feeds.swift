import Foundation

// Changelogs an item ships with or its vendor publishes: installed files, update feeds, stores, and release-notes endpoints.
extension ChangelogResolver {
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
    func localFiles(_ urls: [URL]) throws -> [ChangelogEntry] {
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

    func sparkle(_ url: URL, padding: Bool) throws -> [ChangelogEntry] {
        let items = try SparkleAppcastParser.parse(client.fetch(url, resource: .sparkleAppcast).body)
            .filter(\.isDefaultChannel)
            .sorted { SparkleVersion.compare($0.version, $1.version, padding: padding) == .orderedDescending }
        // Each item's own notes and, when those are a placeholder, the page they link to: the
        // item's releaseNotesLink, or one inside the placeholder text itself.
        let notes = items.map { item -> (content: String, link: URL?) in
            let content = item.releaseNotesHTML.map { HTMLMarkdown.convert($0) } ?? ""
            guard ChangelogDocument.isPlaceholder(content) else { return (content, nil) }
            let embedded = item.releaseNotesHTML.flatMap { html in HTMLMarkdown.links(in: html, base: url).first?.url }
            let link = item.releaseNotesURL.flatMap(URL.init(string:)) ?? embedded
            return (content, link.flatMap { isPublicHTTPSURL($0) && $0.host != nil ? $0 : nil })
        }
        var entries: [ChangelogEntry] = []
        var linkedPages = 0
        var linkedSplit: [ChangelogEntry]?
        // Linked pages read ahead of the loop, once the first shows that each item links a page
        // of its own (CleanShot's): reading one often means rendering it in WebKit, seconds each.
        var readAhead: [URL: LinkedPage] = [:]
        for (index, item) in items.enumerated() {
            var content = notes[index].content
            var source: String?
            // A feed that only links to its notes: the linked page, for the newest releases.
            if ChangelogDocument.isPlaceholder(content), let linkedSplit,
                let own = linkedSplit.first(where: { ChangelogVersion.matches($0.version, ChangelogVersion.normalized(item.displayVersion)) })
            {
                content = own.content
            } else if ChangelogDocument.isPlaceholder(content), linkedPages < 12, let link = notes[index].link {
                linkedPages += 1
                if let page = readAhead[link] ?? readLinkedPage(link) {
                    let html = page.html
                    // A page that covers every version is split, and this version's part kept;
                    // a script-built page is rendered first.
                    let split = page.split
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
                    // Pages for one version each: the rest are read together. Which one each item
                    // uses is still decided here, in feed order.
                    if linkedPages == 1, linkedSplit == nil {
                        var seen: Set<URL> = [link]
                        let upcoming = notes[(index + 1)...].compactMap(\.link).filter { seen.insert($0).inserted }.prefix(11)
                        readAhead = readLinkedPages(Array(upcoming))
                    }
                } else if let linkedSplit,
                    let own = linkedSplit.first(where: { ChangelogVersion.matches($0.version, ChangelogVersion.normalized(item.displayVersion)) })
                {
                    content = own.content
                }
            }
            entries.append(
                ChangelogEntry(version: item.displayVersion, date: item.publishedAt.flatMap(ChangelogDocument.rfc822Date), content: content, sourceURL: source))
        }
        // The notes page the feed links to usually covers every version (Cyberduck's,
        // Postman's): its older sections fill in the history the feed no longer lists.
        if let linkedSplit, linkedSplit.count > entries.count, ChangelogDocument.isMeaningful(linkedSplit) { entries = Self.merge(entries, linkedSplit) }
        // A full-history page fills in the versions the feed itself no longer lists.
        if let full = items.lazy.compactMap({ $0.fullReleaseNotesURL?.trimmingCharacters(in: .whitespacesAndNewlines) }).compactMap(URL.init(string:)).first,
            isPublicHTTPSURL(full),
            let text = try? fetchText(full, resource: .changelogPage)
        {
            let history = read(text, url: full, render: true)
            if ChangelogDocument.isMeaningful(history) { return Self.merge(entries, history) }
        }
        return entries
    }

    /// A release-notes page a feed item links to, and its entries.
    struct LinkedPage: Sendable {
        let html: String
        let split: [ChangelogEntry]
    }

    private func readLinkedPage(_ link: URL) -> LinkedPage? {
        guard let html = try? fetchText(link, resource: .changelogPage) else { return nil }
        return LinkedPage(html: html, split: read(html, url: link, render: true))
    }

    /// Several linked pages read at once; one that can't be fetched is left out and tried again
    /// when its item comes up.
    private func readLinkedPages(_ links: [URL]) -> [URL: LinkedPage] {
        let pages = UnsafeResults<LinkedPage?>(count: links.count)
        DispatchQueue.concurrentPerform(iterations: links.count) { index in pages[index] = .some(readLinkedPage(links[index])) }
        return Dictionary(zip(links, pages.values).compactMap { link, page in page.map { (link, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: App Store

    func appStore(_ bundleIdentifier: String) throws -> [ChangelogEntry] {
        let data = try client.fetch(AppStoreListing.lookupURL(bundleIdentifier, storefront: storefront), resource: .appStoreLookup).body
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
        let date = (listing["currentVersionReleaseDate"] as? String).flatMap { ChangelogDocument.isoDate($0) }
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
                    let date = dateText.flatMap { ChangelogDocument.isoDate($0) ?? ChangelogDocument.date(in: $0) }
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

    func steamNews(_ appID: String) throws -> [ChangelogEntry] {
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

    func blackmagic(_ product: String) throws -> [ChangelogEntry] {
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
            let date = (download["date"] as? String).flatMap { ChangelogDocument.date(in: $0) ?? ChangelogDocument.rfc822Date($0) }
            entries.append((ChangelogEntry(version: version, title: name, date: date, content: HTMLMarkdown.convert(html)), number))
        }
        return entries.sorted { $0.1 > $1.1 }.map(\.0)
    }

    // MARK: Vendor endpoints

    /// A JSON update endpoint: the notes it carries, or the page its `notes` field links to.
    func updateFeed(_ url: URL, name: String) throws -> [ChangelogEntry] {
        let feed = UpdateFeedJSON.read(try client.fetch(url, resource: .changelogPage).body)
        for link in feed.links.prefix(1) where isPublicHTTPSURL(link) {
            let linked = (try? page(link, name: name)) ?? []
            if ChangelogDocument.isMeaningful(linked) { return Self.merge(feed.entries, linked) }
        }
        return feed.entries
    }

    func filteredFeed(_ url: URL, title: String) throws -> [ChangelogEntry] {
        let items = ChangelogFeeds.entries(fromFeed: try client.fetch(url, resource: .changelogPage).body)
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
    func versionPages(_ pages: [VersionedURL]) throws -> [ChangelogEntry] {
        warm(pages.map(\.url), resource: .changelogPage)
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
        let html = try fetchText(url, resource: .changelogPage)
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
    func adoptium(major: Int) throws -> [ChangelogEntry] {
        guard
            let names = URL(
                string:
                    "https://api.adoptium.net/v3/info/release_names?version=%5B\(major)%2C\(major + 1)%29&release_type=ga&page_size=10&sort_order=DESC&vendor=eclipse&image_type=jdk"
            ),
            let list =
                (try JSONSerialization.jsonObject(with: client.fetch(names, resource: .changelogPage).body) as? [String: Any])?[
                    "releases"] as? [String]
        else { throw MetadataHTTPError.invalidResponse }
        let notesURL = { (name: String) in
            name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-."))).flatMap {
                URL(string: "https://api.adoptium.net/v3/info/release_notes/\($0)")
            }
        }
        warm(list.prefix(10).compactMap(notesURL), resource: .changelogPage)
        return list.prefix(10).compactMap { name -> ChangelogEntry? in
            guard let url = notesURL(name),
                let data = try? client.fetch(url, resource: .changelogPage).body,
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
}
