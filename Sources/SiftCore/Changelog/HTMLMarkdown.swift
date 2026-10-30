import Foundation

/// Converts a changelog web page to Markdown that `ChangelogDocument` can split: headings keep
/// their level, list items become bullets, code stays code, and page chrome (navigation, headers,
/// footers, scripts) is dropped. Links keep only their text. Nothing is fetched or executed.
enum HTMLMarkdown {
    static func convert(_ html: String) -> String {
        var output = ""
        var index = html.startIndex
        var skipping: [String] = []
        var preformatted = 0
        var listDepth = 0
        func newline(_ count: Int = 1) {
            let trailing = output.reversed().prefix { $0 == "\n" }.count
            if output.isEmpty { return }
            if trailing < count { output += String(repeating: "\n", count: count - trailing) }
        }
        while index < html.endIndex {
            if html[index] == "<", html[index...].hasPrefix("<!--") {
                index = html[index...].range(of: "-->")?.upperBound ?? html.endIndex
                continue
            }
            guard html[index] == "<", let close = html[index...].firstIndex(of: ">") else {
                if skipping.isEmpty {
                    let character = html[index]
                    if preformatted > 0 { output.append(character) }
                    else if character.isWhitespace { if !(output.last?.isWhitespace ?? true) { output.append(" ") } }
                    else { output.append(character) }
                }
                index = html.index(after: index)
                continue
            }
            let tag = html[html.index(after: index)..<close].trimmingCharacters(in: .whitespacesAndNewlines)
            let isClosing = tag.hasPrefix("/")
            let name = tag.drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber }.lowercased()
            index = html.index(after: close)
            if let skipped = skipping.last {
                if name == skipped {
                    if isClosing { skipping.removeLast() } else if !tag.hasSuffix("/") { skipping.append(name) }
                }
                continue
            }
            switch name {
            // Buttons stay: accordion changelogs put each version's header in one.
            case "script", "style", "head", "nav", "footer", "noscript", "svg", "template", "aside":
                if !isClosing, !tag.hasSuffix("/") { skipping.append(name) }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                if isClosing { newline(2) } else {
                    newline(2)
                    output += String(repeating: "#", count: Int(String(name.last!))!) + " "
                }
            case "li":
                if !isClosing {
                    newline()
                    output += String(repeating: "  ", count: max(0, listDepth - 1)) + "- "
                }
            case "ul", "ol":
                listDepth = max(0, listDepth + (isClosing ? -1 : 1))
                newline(listDepth == 0 ? 2 : 1)
            case "pre":
                if isClosing {
                    preformatted = max(0, preformatted - 1)
                    newline()
                    output += "```"
                    newline(2)
                } else {
                    newline(2)
                    output += "```\n"
                    preformatted += 1
                }
            case "code" where preformatted == 0:
                output += "`"
            case "strong", "b":
                output += "**"
            case "br":
                newline()
            case "p", "div", "section", "article", "tr", "table", "dl", "dt", "dd", "blockquote", "details", "summary", "main", "button", "header", "form":
                newline(name == "p" || name == "section" || name == "article" ? 2 : 1)
            default:
                break
            }
        }
        let decoded = HTMLText.decodeEntities(output)
        let lines = decoded.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.replacingOccurrences(of: "\u{00A0}", with: " ")
            let leading = trimmed.prefix { $0 == " " }
            return leading + trimmed.dropFirst(leading.count).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        }
        return ChangelogDocument.tidy(lines.joined(separator: "\n"))
    }

    /// Every `<a href>` on the page with its visible text, resolved against `base`.
    static func links(in html: String, base: URL) -> [(text: String, url: URL)] {
        var links: [(String, URL)] = []
        // Minified pages leave attribute values unquoted (href=/mac/app/versionhistory/).
        for match in html.matches(of: #/(?is)<a\s[^>]*?href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>"']+))[^>]*>(.*?)</a>/#) {
            let raw = match.1 ?? match.2 ?? match.3 ?? ""
            guard !raw.isEmpty, !raw.hasPrefix("#") else { continue }
            let href = HTMLText.decodeEntities(String(raw)).trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: href, relativeTo: base)?.absoluteURL, url.scheme?.lowercased() == "https" else { continue }
            let text = HTMLText.plainText(from: String(match.4)).trimmingCharacters(in: .whitespacesAndNewlines)
            links.append((text, url))
        }
        return links
    }
}
