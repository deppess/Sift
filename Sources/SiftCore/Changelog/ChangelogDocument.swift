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
        var versioned = headings.filter { ChangelogVersion.token(in: $0.text) != nil && !isUnreleased($0.text) }
        if versioned.isEmpty {
            // Plain-text NEWS and CHANGES files have no Markdown headings.
            headings = plainTextHeadings(lines)
            versioned = headings
        }
        guard !versioned.isEmpty else { return [] }
        // The first version heading sets the depth: version headings at its level or above are
        // entries, deeper ones (a "### 2.1.1 fixes" under "## 2.1.1") stay inside them. FL
        // Studio lists recent releases as h3 and older majors as h2, and both count.
        let level = versioned[0].level
        let starts = versioned.filter { $0.level <= level }
        var entries: [ChangelogEntry] = []
        for (position, start) in starts.enumerated() {
            let bodyStart = start.index + (isSetextUnderline(lines, after: start.index) ? 2 : 1)
            // An entry ends at the next version heading, or at any heading above its level.
            let nextVersion = position + 1 < starts.count ? starts[position + 1].index : lines.count
            let nextHigher = headings.first { $0.index > start.index && $0.level < start.level }?.index ?? lines.count
            let end = min(nextVersion, nextHigher)
            var bodyLines = bodyStart < end ? Array(lines[bodyStart..<end]) : []
            var entryDate = date(in: start.text)
            // A date on its own first line ("14 September 2026") is the entry's date.
            if entryDate == nil, let first = bodyLines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
               bodyLines[first].count < 48, let found = date(in: bodyLines[first]) {
                entryDate = found
                bodyLines.remove(at: first)
            }
            let version = ChangelogVersion.token(in: start.text) ?? start.text
            entries.append(ChangelogEntry(version: version, title: cleanTitle(start.text, version: version), date: entryDate, content: tidy(dedented(bodyLines)), sourceURL: sourceURL))
        }
        // Point releases written as paragraphs inside an entry ("go1.27.1 (released 2026-09-01)
        // includes fixes to …"), split into entries of their own.
        entries = entries.flatMap { entry -> [ChangelogEntry] in
            let lines = entry.content.components(separatedBy: "\n")
            let starts = lines.indices.filter { lines[$0].firstMatch(of: #/^(?:[a-z]{1,12})?v?\d+(\.\d+)+\s+\(released\b/#) != nil }
            guard !starts.isEmpty else { return [entry] }
            var split = [ChangelogEntry(version: entry.version, title: entry.title, date: entry.date, content: tidy(lines[..<starts[0]].joined(separator: "\n")), sourceURL: entry.sourceURL)]
            for (position, start) in starts.enumerated() {
                let end = position + 1 < starts.count ? starts[position + 1] : lines.count
                let text = lines[start..<end].joined(separator: "\n")
                split.append(ChangelogEntry(version: ChangelogVersion.token(in: lines[start]) ?? entry.version, date: date(in: lines[start]), content: tidy(text), sourceURL: entry.sourceURL))
            }
            return split.sorted { left, right in
                guard let a = ChangelogVersion.token(in: left.version), let b = ChangelogVersion.token(in: right.version) else { return false }
                return SparkleVersion.compare(a, b) == .orderedDescending
            }
        }
        // A version repeated as its own entry's title ("1.9.8" then "1.9.8 · A Whole Glance")
        // is one entry.
        var merged: [ChangelogEntry] = []
        for entry in entries {
            if let last = merged.last, last.version == entry.version {
                merged[merged.count - 1] = ChangelogEntry(version: last.version, title: last.title ?? entry.title, date: last.date ?? entry.date, content: [last.content, entry.content].filter { !$0.isEmpty }.joined(separator: "\n"), sourceURL: last.sourceURL ?? entry.sourceURL)
            } else {
                merged.append(entry)
            }
        }
        return merged
    }

    /// Version lines in plain-text changelogs: GNU NEWS ("* Noteworthy changes in release 9.5",
    /// "* Changes in Wget 1.25.0"), FFmpeg ("version 7.1:"), tmux ("CHANGES FROM 3.5a TO 3.6"),
    /// Bash ("This document details the changes between this version, bash-5.3-release, …"), and
    /// a version at the start of a line followed by a blank or underline.
    static func plainTextHeadings(_ lines: [String]) -> [(index: Int, level: Int, text: String)] {
        var headings: [(Int, Int, String)] = []
        for (index, line) in lines.enumerated() {
            guard let first = line.first, !first.isWhitespace, line.count <= 140, ChangelogVersion.token(in: line) != nil, !isUnreleased(line) else { continue }
            let lower = line.lowercased()
            let next = index + 1 < lines.count ? lines[index + 1].trimmingCharacters(in: .whitespaces) : ""
            // "* Noteworthy changes in release 9.5", "* Changes in Wget 1.25.0"; not a bullet
            // that merely mentions a standard ("…conforming to POSIX 1003.1-2001:").
            let isHeading = lower.hasPrefix("* ") && (lower.firstMatch(of: #/\b(release|version)\s+v?\d/#) != nil || lower.firstMatch(of: #/^\* (?:noteworthy |major |user-visible |)changes in\b/#) != nil)
                || lower.firstMatch(of: #/^(version|release|changes in|noteworthy changes|what's new in|what’s new in|new in)\b/#) != nil
                || lower.hasPrefix("changes from ")
                || lower.hasPrefix("this document details the changes between this version")
                || (lower.firstMatch(of: #/^v?\d+(\.\d+)+/#) != nil && (next.isEmpty || next.allSatisfy { "=-~^*".contains($0) }))
                // A version alone on its line with a date next ("2.0" / "November 2026").
                || (line.count <= 40 && lower.firstMatch(of: #/^(?:[a-z][\w ]{0,30} )?v?\d+(\.\d+)+\s*$/#) != nil && date(in: lines[(index + 1)..<min(lines.count, index + 4)].joined(separator: " ")) != nil)
            if isHeading { headings.append((index, 1, line.trimmingCharacters(in: CharacterSet(charactersIn: "* :").union(.whitespaces)))) }
        }
        if headings.isEmpty {
            // "Tor Browser 16.0 - October 28 2026" or "2012-04-02: atool 0.39.0 released." at the
            // margin with indented text below, used consistently through the file.
            let indentedBelow = lines.indices.filter { index in
                guard let first = lines[index].first, !first.isWhitespace, lines[index].count <= 140, ChangelogVersion.token(in: lines[index]) != nil, index + 1 < lines.count else { return false }
                return lines[index + 1].first.map { $0 == " " || $0 == "\t" } ?? false
            }
            if indentedBelow.count >= 3 { headings = indentedBelow.map { ($0, 1, lines[$0].trimmingCharacters(in: .whitespaces)) } }
        }
        return headings.map { (index: $0.0, level: $0.1, text: $0.2) }
    }

    /// Body lines with their common indentation removed, so indented NEWS bullets aren't read
    /// as code; GNU's "** Bug fixes" sub-headings become headings.
    private static func dedented(_ lines: [String]) -> String {
        // GNU's "** " sub-headings sit at the margin while their text is indented.
        let indents = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("** ") }.map { $0.prefix { $0 == " " || $0 == "\t" }.count }
        let common = indents.min() ?? 0
        return lines.map { line -> String in
            let stripped = String(line.dropFirst(min(common, line.prefix { $0 == " " || $0 == "\t" }.count)))
            return stripped.hasPrefix("** ") ? "### " + stripped.dropFirst(3) : stripped
        }.joined(separator: "\n")
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

    /// The heading's words after the version, minus dates ("Christmas release" in "v1.1.0
    /// Christmas release"); words before it are the product's name. nil when nothing is left.
    private static func cleanTitle(_ heading: String, version: String) -> String? {
        guard let range = heading.range(of: version) else { return nil }
        var rest = String(heading[range.upperBound...])
        rest = rest.replacing(#/\d{4}-\d{2}-\d{2}/#, with: "")
        rest = rest.replacing(#/(?i)\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.? \d{1,2},? \d{4}\b/#, with: "")
        rest = rest.replacing(#/(?i)\b\d{1,2} (?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]* \d{4}\b/#, with: "")
        rest = rest.replacing(#/(?i)\b(released|stable|\[stable\]|final)\b\.?/#, with: "")
        let trimmed = rest.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:()[]·|,.?*").union(.whitespaces))
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

    static func date(in original: String) -> Date? {
        // "July 21st, 2026" reads as "July 21, 2026".
        let text = original.replacing(#/(\d{1,2})(st|nd|rd|th)\b/#) { String($0.1) }
        if let match = text.firstMatch(of: #/(\d{4})[-/](\d{2})[-/](\d{2})/#),
           let year = Int(match.1), let month = Int(match.2), let day = Int(match.3) {
            return utcDate(year: year, month: month, day: day)
        }
        // "2025/ Feb / 03" (FL Studio).
        if let match = text.firstMatch(of: #/(\d{4})\s*/\s*([A-Za-z]{3})[a-z]*\s*/\s*(\d{1,2})/#), let year = Int(match.1), let day = Int(match.3),
           let month = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].firstIndex(of: match.2.lowercased()) {
            return utcDate(year: year, month: month + 1, day: day)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let patterns: [(Regex<Substring>, [String])] = [
            (try! Regex(#"(?i)\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.? \d{1,2},? \d{4}\b"#), ["MMMM d, yyyy", "MMM d, yyyy", "MMMM d yyyy", "MMM d yyyy", "MMM. d, yyyy"]),
            (try! Regex(#"(?i)\b\d{1,2} (?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]* \d{4}\b"#), ["d MMMM yyyy", "d MMM yyyy"]),
            (try! Regex(#"(?i)^\s*(?:january|february|march|april|may|june|july|august|september|october|november|december) \d{4}\s*$"#), ["MMMM yyyy"]),
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
        // A browser check or a script-only page stands in for the content.
        if ["update your browser", "unsupported browser", "enable javascript", "javascript is required", "requires javascript", "turn on javascript"].contains(where: plain.lowercased().contains) && plain.count < 1_200 { return true }
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
