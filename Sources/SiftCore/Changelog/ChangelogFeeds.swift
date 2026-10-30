import Foundation

/// RSS and Atom feeds (a project's release feed, GitHub's `releases.atom`) and the JSON data
/// script-built pages embed, read as changelog entries.
enum ChangelogFeeds {
    /// Feeds a page advertises with `<link rel="alternate">`.
    static func advertisedFeeds(in html: String, base: URL) -> [URL] {
        html.matches(of: #/(?is)<link\b[^>]*>/#).compactMap { match -> URL? in
            let tag = String(match.0)
            guard tag.range(of: #"rel\s*=\s*["']?alternate"#, options: [.regularExpression, .caseInsensitive]) != nil,
                  tag.range(of: #"(rss|atom)\+xml"#, options: [.regularExpression, .caseInsensitive]) != nil,
                  let href = tag.firstMatch(of: #/(?i)href\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>]+))/#) else { return nil }
            let value = HTMLText.decodeEntities(String(href.1 ?? href.2 ?? href.3 ?? ""))
            return URL(string: value, relativeTo: base)?.absoluteURL
        }
    }

    /// The items of an RSS or Atom feed, newest first as the feed lists them.
    static func entries(fromFeed data: Data) -> [ChangelogEntry] {
        let parser = FeedParser()
        let xml = XMLParser(data: data)
        xml.shouldResolveExternalEntities = false
        xml.delegate = parser
        guard xml.parse() || !parser.items.isEmpty else { return [] }
        return parser.items.compactMap { item in
            guard let title = item["title"]?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            let html = item["content:encoded"] ?? item["content"] ?? item["description"] ?? item["summary"] ?? ""
            let content = html.contains("<") ? HTMLMarkdown.convert(html) : ChangelogDocument.tidy(html)
            let date = (item["pubDate"] ?? item["updated"] ?? item["published"]).flatMap { ISO8601DateFormatter().date(from: $0) ?? ChangelogResolver.rfc822Date($0) }
            let version = ChangelogVersion.token(in: title) ?? title
            return ChangelogEntry(version: version, title: version == title || title.contains(version) && title.count < version.count + 24 ? nil : title, date: date, content: content, sourceURL: item["link"])
        }
    }

    /// Feed posts as a log by day, for a feed whose posts aren't versioned: each day's posts
    /// under their titles, newest day first. Most posts need a date.
    static func datedEntries(_ items: [ChangelogEntry], limit: Int = 100) -> [ChangelogEntry] {
        let datedItems = items.filter { $0.date != nil }
        guard datedItems.count >= 3, datedItems.count * 5 >= items.count * 4 else { return [] }
        var days: [(String, [ChangelogEntry])] = []
        for item in datedItems.sorted(by: { $0.date! > $1.date! }) {
            let day = ChangelogDocument.dayVersion(item.date!)
            if let index = days.firstIndex(where: { $0.0 == day }) { days[index].1.append(item) } else if days.count < limit { days.append((day, [item])) }
        }
        return days.map { day, posts in
            let date = posts[0].date
            if posts.count == 1, let post = posts.first {
                return ChangelogEntry(version: day, title: post.title ?? post.version, date: date, content: post.content, sourceURL: post.sourceURL)
            }
            let content = posts.map { "### \($0.title ?? $0.version)\n\n\($0.content)" }.joined(separator: "\n\n")
            return ChangelogEntry(version: day, title: nil, date: date, content: content, sourceURL: posts[0].sourceURL)
        }
    }

    private final class FeedParser: NSObject, XMLParserDelegate {
        var items: [[String: String]] = []
        private var current: [String: String]?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if elementName == "item" || elementName == "entry" { current = [:] }
            // Atom links are attributes: <link rel="alternate" href="…"/>.
            if elementName == "link", current != nil, let href = attributes["href"], attributes["rel"] ?? "alternate" == "alternate" { current?["link"] = href }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if elementName == "item" || elementName == "entry" {
                if let current { items.append(current) }
                current = nil
            } else if current != nil, current?[elementName] == nil {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { current?[elementName] = value }
            }
            text = ""
        }
    }

    // MARK: Embedded JSON

    private static let versionKeys = ["version", "versionNumber", "version_number", "versionString", "versionDisplay", "tag", "tagName", "tag_name", "name", "title"]
    private static let contentKeys = ["body", "releaseNotes", "release_notes", "notes", "changes", "changelog", "content", "description", "text", "html", "markdown", "summary", "items"]
    private static let dateKeys = ["date", "releaseDate", "release_date", "publishedAt", "published_at", "createdAt", "created_at", "released", "releasedAt"]

    /// Release records in the JSON a page embeds for its scripts (`__NEXT_DATA__`, `ld+json`, and
    /// other `application/json` blocks): objects with a version and a body. Two or more are needed,
    /// so one stray object that happens to have both doesn't count as a changelog.
    static func embeddedEntries(in html: String) -> [ChangelogEntry] {
        var entries: [ChangelogEntry] = []
        var seen = Set<String>()
        func text(_ value: Any?) -> String? {
            if let string = value as? String { return string }
            if let strings = value as? [String] { return strings.map { "- \($0)" }.joined(separator: "\n") }
            if let objects = value as? [[String: Any]] {
                let lines = objects.compactMap { object in contentKeys.lazy.compactMap { object[$0] as? String }.first ?? object["title"] as? String }
                return lines.isEmpty ? nil : lines.map { "- \($0)" }.joined(separator: "\n")
            }
            return nil
        }
        func walk(_ value: Any, depth: Int) {
            guard depth < 40 else { return }
            if let object = value as? [String: Any] {
                if let label = versionKeys.lazy.compactMap({ object[$0] as? String }).first(where: { ChangelogVersion.token(in: $0) != nil }),
                   let body = contentKeys.lazy.compactMap({ text(object[$0]) }).first(where: { $0.count > 10 && ChangelogVersion.token(in: $0) != label }) {
                    let version = ChangelogVersion.token(in: label) ?? label
                    if seen.insert(version).inserted {
                        let date = dateKeys.lazy.compactMap { object[$0] as? String }.first.flatMap { ISO8601DateFormatter().date(from: $0) ?? ChangelogDocument.date(in: $0) }
                        entries.append(ChangelogEntry(version: version, title: label == version ? nil : label, date: date, content: body.contains("<") ? HTMLMarkdown.convert(body) : ChangelogDocument.tidy(body)))
                    }
                }
                for child in object.values { walk(child, depth: depth + 1) }
            } else if let array = value as? [Any] {
                for child in array { walk(child, depth: depth + 1) }
            }
        }
        for match in html.matches(of: #/(?is)<script\b[^>]*type\s*=\s*["']?application/(?:ld\+)?json["']?[^>]*>(.*?)</script>/#) {
            let raw = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = (raw.hasPrefix("{") || raw.hasPrefix("[") ? raw : HTMLText.decodeEntities(raw)).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            walk(json, depth: 0)
        }
        guard entries.count >= 2 else { return [] }
        return entries.sorted { left, right in
            guard let a = ChangelogVersion.token(in: left.version), let b = ChangelogVersion.token(in: right.version) else { return false }
            return SparkleVersion.compare(a, b) == .orderedDescending
        }
    }

    /// Pages whose content is built by scripts: little visible text, an empty app root, or a
    /// "please enable JavaScript" notice.
    static func looksScriptBuilt(_ html: String) -> Bool {
        let lower = html.lowercased()
        if lower.contains("enable javascript") || lower.contains("requires javascript") || lower.contains("javascript is required") || lower.contains("javascript to run this app") { return true }
        if lower.contains("id=\"__next\"") || lower.contains("id=\"root\"></div>") || lower.contains("id=\"app\"></div>") || lower.contains("data-reactroot") || lower.contains("ng-version") || lower.contains("__nuxt") { return true }
        let visible = HTMLMarkdown.convert(html).filter { !$0.isWhitespace }.count
        return visible < 1_200 && lower.components(separatedBy: "<script").count > 3
    }
}
