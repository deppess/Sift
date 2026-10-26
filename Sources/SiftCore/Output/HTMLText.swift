import Foundation

/// Converts the small HTML fragments that appcasts embed as release notes into plain text: block
/// elements become line breaks, list items become bullets, everything else is dropped. Nothing is
/// fetched or executed. Not a general HTML renderer.
enum HTMLText {
    static func plainText(from html: String) -> String {
        var output = ""
        var index = html.startIndex
        var skipping: String?
        while index < html.endIndex {
            guard html[index] == "<", let close = html[index...].firstIndex(of: ">") else {
                if skipping == nil { output.append(html[index]) }
                index = html.index(after: index)
                continue
            }
            let tag = html[html.index(after: index)..<close].trimmingCharacters(in: .whitespaces)
            let isClosing = tag.hasPrefix("/")
            let name = tag.drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber }.lowercased()
            index = html.index(after: close)
            if let skipped = skipping {
                if isClosing, name == skipped { skipping = nil }
                continue
            }
            switch name {
            case "script", "style", "head", "title":
                if !isClosing, !tag.hasSuffix("/") { skipping = name }
            case "li":
                if !isClosing { output += (output.isEmpty || output.hasSuffix("\n") ? "" : "\n") + "• " }
            case "br":
                output += "\n"
            case "p", "div", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "tr", "section", "article":
                // One line break per block boundary, and a paragraph opening inside a list item
                // stays on the bullet's line.
                if !output.hasSuffix("• "), !output.hasSuffix("\n") { output += "\n" }
            default:
                break
            }
        }
        let decoded = decodeEntities(output)
        let lines = decoded.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        var compacted: [String] = []
        for line in lines where !(line.isEmpty && (compacted.last?.isEmpty ?? true)) { compacted.append(line) }
        while compacted.last?.isEmpty == true { compacted.removeLast() }
        compacted.removeAll { $0 == "•" }
        // Consecutive list items stay together even when each wraps its text in a paragraph.
        let tight = compacted.indices.filter { index in
            compacted[index].isEmpty && index > 0 && index < compacted.count - 1 && compacted[index - 1].hasPrefix("• ") && compacted[index + 1].hasPrefix("• ")
        }
        for index in tight.reversed() { compacted.remove(at: index) }
        return compacted.joined(separator: "\n")
    }

    private static let namedEntities: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "bull": "•"]

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "&", let end = text[index...].prefix(12).firstIndex(of: ";") {
                let entity = String(text[text.index(after: index)..<end])
                if let replacement = decodeEntity(entity) {
                    output += replacement
                    index = text.index(after: end)
                    continue
                }
            }
            output.append(text[index])
            index = text.index(after: index)
        }
        return output
    }

    private static func decodeEntity(_ entity: String) -> String? {
        if let named = namedEntities[entity] { return named }
        guard entity.hasPrefix("#") else { return nil }
        let digits = entity.dropFirst()
        let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
        return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }
}
