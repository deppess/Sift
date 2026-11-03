import Foundation

// Changelogs on web pages: read, followed, rendered, and discovered on the vendor's site.
extension ChangelogResolver {
    // MARK: Web pages

    /// The page itself when it lists versions, or else the changelog its links point to. Each
    /// page is read as HTML, then through the feeds it advertises, then through the JSON it embeds
    /// for its scripts, and last rendered in WebKit when its content is built by scripts.
    func page(_ url: URL, name: String = "", installed: String? = nil, known: Bool = false) throws -> [ChangelogEntry] {
        let html = try fetchText(url, resource: .changelogPage)
        let isChangelogPage = known || Self.looksLikeChangelogURL(url)
        // A homepage's own text, then its changelog links, and only then its feeds (often a
        // blog covering other products) and embedded data.
        // A homepage's dated news items (PostgreSQL's, Docker's) aren't its changelog.
        var entries = isChangelogPage ? read(html, url: url, render: true) : Self.withoutDayEntries(Self.pageEntries(html, url: url))
        // Versions of another product (a homepage listing the vendor's other app) don't stop the search.
        let fits = { (found: [ChangelogEntry]) in ChangelogVersion.sameLine(found, installed: installed) }
        // A homepage's own couple of versions (a "what's new" teaser) don't beat its changelog link.
        if fits(entries), entries.count >= (isChangelogPage ? 2 : 3) || ChangelogDocument.isMeaningful(entries) && isChangelogPage {
            // A homepage's versions without the installed one (OnyX's newest for each macOS) give
            // way to a changelog it links that has it.
            if !isChangelogPage, let installed, ChangelogVersion.installedIndex(in: entries, installed: installed) == nil {
                for link in Self.changelogLinks(in: html, base: url).prefix(2) {
                    guard let text = try? fetchText(link, resource: .changelogPage) else { continue }
                    let linked = read(text, url: link, render: true)
                    if fits(linked), ChangelogVersion.installedIndex(in: linked, installed: installed) != nil { return linked }
                }
            }
            return entries
        }
        // An index of years (Warp's /changelog links /changelog/2026, /changelog/2025): the newest two.
        if isChangelogPage, entries.count < 3 {
            let years = Self.yearSections(in: html, base: url)
            var found: [ChangelogEntry] = []
            for year in years.prefix(2) {
                guard let text = try? fetchText(year, resource: .changelogPage) else { continue }
                found = Self.merge(found, read(text, url: year, render: true))
            }
            if ChangelogDocument.isMeaningful(found), found.count >= 3, fits(found) { return found }
        }
        // A changelog hub listing another product first (LM Studio's /changelog is Bionic's) links
        // the item's own section (/changelog/lmstudio).
        if isChangelogPage, let section = Self.productSection(in: html, base: url, name: name),
            let text = try? fetchText(section, resource: .changelogPage)
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
            do { linked = try fetchText(link, resource: .changelogPage) } catch { linkError = linkError ?? error; continue }
            var linkedEntries = read(linked, url: link, render: true)
            if !fits(linkedEntries), let section = Self.productSection(in: linked, base: link, name: name),
                let text = try? fetchText(section, resource: .changelogPage)
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
                guard let text = try? fetchText(candidate, resource: .changelogPage)
                else { continue }
                var found = read(text, url: candidate, render: true)
                // An index of editions ("/release-notes" listing Mac, Windows, Linux) leads to the Mac one.
                if found.count < 3,
                    let mac = HTMLMarkdown.links(in: text, base: candidate).map(\.url).first(where: { link in
                        link.host == candidate.host && link.path.hasPrefix(candidate.path) && link.path != candidate.path
                            && ["mac", "macos", "osx"].contains(link.lastPathComponent.lowercased())
                    }), let macText = try? fetchText(mac, resource: .changelogPage)
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
    func read(_ html: String, url: URL, render: Bool, name: String = "") -> [ChangelogEntry] {
        let entries = Self.pageEntries(html, url: url)
        // Two versions may be a teaser (Notion's two latest headlines over a full feed).
        if entries.count >= 3, ChangelogDocument.isMeaningful(entries) { return entries }
        for feed in ChangelogFeeds.advertisedFeeds(in: html, base: url).prefix(2) where isPublicHTTPSURL(feed) {
            guard let data = try? client.fetch(feed, resource: .changelogPage).body else { continue }
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
        if entries.count < 3, url.pathExtension.isEmpty, url.path.count > 1, url.query == nil,
            let markdownURL = URL(string: url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + ".md"),
            let markdown = try? fetchText(markdownURL, resource: .changelogPage), markdown.range(of: "<html", options: .caseInsensitive) == nil
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
        if render, !ChangelogDocument.isMeaningful(entries), ChangelogFeeds.looksScriptBuilt(html) || entries.isEmpty && !ChangelogFeeds.isStaticDocument(html)
        {
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
        warm(hosts.compactMap { URL(string: "https://\($0)/robots.txt") }, resource: .changelogPage)
        for site in hosts {
            guard let robotsURL = URL(string: "https://\(site)/robots.txt") else { continue }
            let robots: String
            do { robots = try fetchText(robotsURL, resource: .changelogPage) } catch let error as MetadataHTTPError
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
                    let xml = try? fetchText(map, resource: .changelogPage)
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
        // The common paths are guesses: keep only those that answer with a page of their own. A
        // site that answers every address with its homepage (folivora.ai) has none of them, and
        // reading the homepage again under each address rendered it in WebKit every time.
        warm(ranked.filter { guesses.contains($0.absoluteString) }, resource: .changelogPage)
        var bodies = Set([try? client.fetch(base, resource: .changelogPage).body].compactMap { $0 })
        return ranked.filter { url in
            guard guesses.contains(url.absoluteString) else { return true }
            guard let body = try? client.fetch(url, resource: .changelogPage).body else { return false }
            return bodies.insert(body).inserted
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
    private static let genericChangelogWords: Set<String> = ["changes", "history", "news", "updates"]
    private static let downloadExtensions: Set<String> = ["zip", "dmg", "pkg", "gz", "bz2", "xz", "tgz", "exe", "msi", "deb", "rpm", "appimage", "7z"]

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
            // A download under /releases/ (folivora.ai/releases/KeyboardCleanTool.zip) isn't a page.
            guard !Self.downloadExtensions.contains(link.url.pathExtension.lowercased()) else { continue }
            var score = 0
            // Generic words also name other things ("Hacker News", "Browse clipboard history"):
            // in a link's text they count only when they are most of it, and alone they don't
            // make another site's page a changelog.
            let shortText = text.split(whereSeparator: \.isWhitespace).count <= 3
            var specific = false
            for (rank, word) in changelogWords.enumerated() {
                let generic = genericChangelogWords.contains(word)
                if text.contains(word), !generic || shortText { score = max(score, 40 - rank); specific = specific || !generic }
                if path.contains(word.replacingOccurrences(of: " ", with: "-")) || path.contains(word.replacingOccurrences(of: " ", with: "")) {
                    score = max(score, 30 - rank)
                    specific = specific || !generic
                }
            }
            guard score > 0 else { continue }
            let host = link.url.host?.lowercased() ?? ""
            if site != nil, HomebrewCaskCatalog.vendorDomain(host) == site {
                score += 20
            } else if host != "github.com" {
                guard specific else { continue }
                score -= 25
            }
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
}
