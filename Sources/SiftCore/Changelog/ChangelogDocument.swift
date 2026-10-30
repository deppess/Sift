import Foundation

/// Splits changelog documents (a CHANGELOG.md, a project's changelog web page, release
/// descriptions) into per-version entries. Nothing here fetches or executes anything.
enum ChangelogDocument {
    /// A Markdown document split at its version headings: the heading level most version
    /// headings use, so sub-headings ("### Fixes") stay inside their entry. Text before the first
    /// version heading (a title, an "Unreleased" section) is dropped.
    static func entries(fromMarkdown document: String, sourceURL: String?) -> [ChangelogEntry] {
        let lines = document.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var headings: [(index: Int, level: Int, text: String)] = []
        var inFence = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            guard !inFence else { continue }
            if let heading = atxHeading(trimmed) {
                headings.append((index, heading.level, heading.text))
            } else if index + 1 < lines.count, !trimmed.isEmpty, let underline = lines[index + 1].trimmingCharacters(in: .whitespaces).first,
                      underline == "=" || underline == "-", lines[index + 1].trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == underline }), lines[index + 1].trimmingCharacters(in: .whitespaces).count >= 3 {
                // A setext heading, which reStructuredText-style changelogs converted to Markdown use.
                headings.append((index, underline == "=" ? 1 : 2, trimmed))
            }
        }
        let versioned = headings.filter { ChangelogVersion.token(in: $0.text) != nil && !isUnreleased($0.text) }
        guard !versioned.isEmpty else { return [] }
        let levelCounts = Dictionary(grouping: versioned, by: \.level).mapValues(\.count)
        let level = levelCounts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }!.key
        let starts = versioned.filter { $0.level == level }
        var entries: [ChangelogEntry] = []
        for (position, start) in starts.enumerated() {
            let bodyStart = start.index + (isSetextUnderline(lines, after: start.index) ? 2 : 1)
            // An entry ends at the next version heading, or at any heading above its level.
            let nextVersion = position + 1 < starts.count ? starts[position + 1].index : lines.count
            let nextHigher = headings.first { $0.index > start.index && $0.level < level }?.index ?? lines.count
            let end = min(nextVersion, nextHigher)
            let body = bodyStart < end ? lines[bodyStart..<end].joined(separator: "\n") : ""
            let version = ChangelogVersion.token(in: start.text) ?? start.text
            entries.append(ChangelogEntry(version: version, title: cleanTitle(start.text, version: version), date: date(in: start.text), content: tidy(body), sourceURL: sourceURL))
        }
        return entries
    }

    private static func atxHeading(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        let level = line.prefix { $0 == "#" }.count
        guard level <= 6, line.dropFirst(level).first == " " else { return nil }
        var text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (level, stripInlineMarkdown(text.trimmingCharacters(in: .whitespaces)))
    }

    private static func isSetextUnderline(_ lines: [String], after index: Int) -> Bool {
        guard index + 1 < lines.count else { return false }
        let next = lines[index + 1].trimmingCharacters(in: .whitespaces)
        return next.count >= 3 && (next.allSatisfy { $0 == "=" } || next.allSatisfy { $0 == "-" })
    }

    private static func isUnreleased(_ heading: String) -> Bool {
        let lower = heading.lowercased()
        return lower.contains("unreleased") || lower.contains("upcoming") || lower.contains("not yet released")
    }

    /// "[1.2.0](https://…) - 2026-10-21" reads as "1.2.0 - 2026-10-21".
    static func stripInlineMarkdown(_ text: String) -> String {
        var result = text.replacing(#/\[([^\]]*)\]\([^)]*\)/#) { String($0.1) }
        result = result.replacing(#/\[([^\]]*)\]\[[^\]]*\]/#) { String($0.1) }
        result = result.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// The heading's words beyond the version and date ("Christmas release"); nil when there are none.
    private static func cleanTitle(_ heading: String, version: String) -> String? {
        var rest = heading.replacingOccurrences(of: "v\(version)", with: "").replacingOccurrences(of: version, with: "")
        rest = rest.replacing(#/\d{4}-\d{2}-\d{2}/#, with: "")
        rest = rest.replacing(#/(?i)^\s*(version|release|v)\b/#, with: "")
        let trimmed = rest.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:()[]·|,"))
        return trimmed.count >= 3 && trimmed.contains(where: \.isLetter) ? trimmed : nil
    }

    /// Blank-line runs collapsed and GitHub's "Full Changelog" footer dropped.
    static func tidy(_ markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n").filter { line in
            let lower = line.lowercased().replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
            return !(lower.hasPrefix("full changelog:") && lower.contains("/compare/"))
        }
        var compacted: [String] = []
        for line in lines where !(line.trimmingCharacters(in: .whitespaces).isEmpty && (compacted.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)) { compacted.append(line) }
        lines = compacted
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: Dates

    static func date(in text: String) -> Date? {
        if let match = text.firstMatch(of: #/(\d{4})-(\d{2})-(\d{2})/#),
           let year = Int(match.1), let month = Int(match.2), let day = Int(match.3) {
            return utcDate(year: year, month: month, day: day)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let patterns: [(Regex<Substring>, [String])] = [
            (try! Regex(#"(?i)\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.? \d{1,2},? \d{4}\b"#), ["MMMM d, yyyy", "MMM d, yyyy", "MMMM d yyyy", "MMM d yyyy", "MMM. d, yyyy"]),
            (try! Regex(#"(?i)\b\d{1,2} (?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]* \d{4}\b"#), ["d MMMM yyyy", "d MMM yyyy"]),
        ]
        for (pattern, formats) in patterns {
            guard let match = text.firstMatch(of: pattern) else { continue }
            let value = String(text[match.range]).replacingOccurrences(of: "Sept", with: "Sep")
            for format in formats {
                formatter.dateFormat = format
                if let date = formatter.date(from: value) { return date }
            }
        }
        return nil
    }

    static func utcDate(year: Int, month: Int, day: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard (1990...2100).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    // MARK: Placeholders

    /// Text that points somewhere else instead of saying what changed: "Please visit the Help
    /// Centre for the latest release notes", "See the changelog", a bare link. Entries made only
    /// of these don't count as a changelog.
    static func isPlaceholder(_ content: String) -> Bool {
        let plain = stripInlineMarkdown(content)
            .replacing(#/https?://\S+/#, with: "LINK")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if plain.isEmpty || plain == "LINK" { return true }
        guard plain.count <= 240 else { return false }
        let lower = plain.lowercased()
        let pointers = ["visit", "see the", "see our", "see link", "refer to", "help cent", "click here", "available at", "available on", "can be found", "read more", "read the", "check out", "full changelog", "full release notes", "release notes are", "for details", "for more information", "learn more", "what's new page", "on our website", "on our blog"]
        return pointers.contains { lower.contains($0) } && (lower.contains("LINK".lowercased()) || lower.contains("release notes") || lower.contains("changelog") || lower.contains("change log") || lower.contains("website") || lower.contains("help cent") || lower.contains("blog") || plain.count < 120)
    }

    static func isMeaningful(_ entries: [ChangelogEntry]) -> Bool {
        entries.contains { !isPlaceholder($0.content) }
    }

    // MARK: BBCode (Steam announcements)

    static func markdown(fromBBCode text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n")
        result = result.replacing(#/(?is)\[img[^\]]*\].*?\[/img\]/#, with: "")
        result = result.replacing(#/(?is)\[previewyoutube[^\]]*\].*?\[/previewyoutube\]/#, with: "")
        result = result.replacing(#/\{STEAM_CLAN_IMAGE\}\S*/#, with: "")
        result = result.replacing(#/(?is)\[url=[^\]]*\](.*?)\[/url\]/#) { String($0.1) }
        result = result.replacing(#/(?i)\[h1\]/#, with: "\n# ").replacing(#/(?i)\[h2\]/#, with: "\n## ").replacing(#/(?i)\[h3\]/#, with: "\n### ")
        result = result.replacing(#/(?i)\[/h[1-6]\]/#, with: "\n")
        result = result.replacing(#/(?i)\[/\*\]/#, with: "")
        result = result.replacing(#/(?i)\[\*\]\s*/#, with: "\n- ")
        result = result.replacing(#/(?i)\[/?b\]/#, with: "**").replacing(#/(?i)\[/?i\]/#, with: "_")
        result = result.replacing(#/(?i)\[p\]/#, with: "\n").replacing(#/(?i)\[/p\]/#, with: "\n")
        result = result.replacing(#/(?i)\[/?(list|olist|u|s|strike|spoiler|noparse|quote|code|table|tr|td|th|hr|url)[^\]]*\]/#, with: "\n")
        result = result.replacing(#/\*\*\s*\*\*/#, with: "")
        // A bullet whose text was wrapped onto the next line ("[*]\n[p]text") joins it.
        let lines = result.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var joined: [String] = []
        for line in lines {
            if joined.last == "-" || joined.last == "- ", !line.isEmpty { joined[joined.count - 1] = "- " + line } else { joined.append(line) }
        }
        return tidy(joined.filter { $0 != "-" }.joined(separator: "\n"))
    }
}
