import Foundation
import Markdown

struct MarkdownTerminalRenderer: MarkupVisitor {
    typealias Result = String

    private let style: TerminalStyle
    /// False prints a link's text alone, as compact changelogs do.
    var linkDestinations = true
    private var listDepth = 0
    private var orderedListIndices: [Int] = []

    init(style: TerminalStyle) {
        self.style = style
    }

    mutating func render(_ source: String, full: Bool) -> String {
        let document = Document(parsing: source)
        let output = full ? visit(document) : compact(document)
        return output.terminalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private mutating func compact(_ document: Document) -> String {
        let blocks = Array(document.children)
        var output: [String] = []
        var omitted = 0
        var index = 0
        while index < blocks.count {
            // Headings that only restate what the entry is ("What's Changed", "Changelog").
            if let heading = blocks[index] as? Heading,
                ["release notes", "what's changed", "what’s changed", "changelog", "changes", "what's new", "what’s new"].contains(
                    heading.plainText.trimmingCharacters(in: .whitespaces).lowercased())
            {
                index += 1
                continue
            }
            if let heading = blocks[index] as? Heading,
                isOperationalHeading(heading.plainText),
                let end = operationalSectionEnd(blocks, startingAfter: index, level: heading.level),
                end > index + 1
            {
                omitted += 1
                index = end
                continue
            }
            let rendered = visit(blocks[index]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !rendered.isEmpty { output.append(rendered) }
            index += 1
        }
        if omitted > 0 {
            output.append(style.label("Downloads and verification omitted; use --full to display them."))
        }
        return output.joined(separator: "\n")
    }

    private func isOperationalHeading(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "download" || normalized == "checksums" || normalized == "verification" || normalized.hasPrefix("install ")
            || normalized.hasPrefix("download ") || normalized.hasPrefix("verifying ")
    }

    private func operationalSectionEnd(_ blocks: [Markup], startingAfter headingIndex: Int, level: Int) -> Int? {
        var index = headingIndex + 1
        var hasOperationalBlock = false
        while index < blocks.count {
            if let nextHeading = blocks[index] as? Heading, nextHeading.level <= level { break }
            if blocks[index] is CodeBlock || blocks[index] is Table { hasOperationalBlock = true }
            index += 1
        }
        return hasOperationalBlock ? index : nil
    }

    mutating func defaultVisit(_ markup: Markup) -> String {
        markup.children.map { visit($0) }.joined()
    }

    mutating func visitDocument(_ document: Document) -> String {
        document.children.map { visit($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        style.heading(defaultVisit(heading).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        defaultVisit(paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func visitText(_ text: Text) -> String { text.string }
    mutating func visitSoftBreak(_: SoftBreak) -> String { " " }
    mutating func visitLineBreak(_: LineBreak) -> String { "\n" }
    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String { style.label(inlineCode.code) }
    mutating func visitEmphasis(_ emphasis: Emphasis) -> String { defaultVisit(emphasis) }
    mutating func visitStrong(_ strong: Strong) -> String { style.title(defaultVisit(strong)) }
    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String { defaultVisit(strikethrough) }

    mutating func visitLink(_ link: Link) -> String {
        let label = defaultVisit(link).trimmingCharacters(in: .whitespacesAndNewlines)
        guard linkDestinations, let destination = link.destination, !destination.isEmpty, destination != label else { return label }
        return "\(label) (\(destination))"
    }

    mutating func visitImage(_ image: Image) -> String {
        let label = defaultVisit(image).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = label.isEmpty ? "Image" : "Image: \(label)"
        return image.source.map { "\(prefix) (\($0))" } ?? prefix
    }

    mutating func visitInlineHTML(_ html: InlineHTML) -> String { visibleHTMLText(html.rawHTML) }
    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String { visibleHTMLText(html.rawHTML) }

    mutating func visitUnorderedList(_ list: UnorderedList) -> String {
        listDepth += 1
        defer { listDepth -= 1 }
        return list.children.map { visit($0) }.joined(separator: "\n")
    }

    mutating func visitOrderedList(_ list: OrderedList) -> String {
        listDepth += 1
        orderedListIndices.append(Int(list.startIndex))
        defer {
            orderedListIndices.removeLast()
            listDepth -= 1
        }
        return list.children.map { visit($0) }.joined(separator: "\n")
    }

    mutating func visitListItem(_ item: ListItem) -> String {
        let indentation = String(repeating: "  ", count: max(0, listDepth - 1))
        let marker: String
        if !orderedListIndices.isEmpty {
            marker = "\(orderedListIndices[orderedListIndices.count - 1])."
            orderedListIndices[orderedListIndices.count - 1] += 1
        } else if let checkbox = item.checkbox {
            marker = checkbox == .checked ? "[x]" : "[ ]"
        } else {
            marker = "•"
        }
        let content = item.children.map { visit($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return "\(indentation)\(style.label(marker)) \(content.replacingOccurrences(of: "\n", with: "\n\(indentation)  "))"
    }

    mutating func visitBlockQuote(_ quote: BlockQuote) -> String {
        defaultVisit(quote).split(separator: "\n", omittingEmptySubsequences: false)
            .map { "\(style.label(">")) \($0)" }
            .joined(separator: "\n")
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let language = codeBlock.language.map { " [\($0)]" } ?? ""
        let code = codeBlock.code.terminalText.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  \($0)" }
            .joined(separator: "\n")
        return "\(style.label("Code\(language):"))\n\(code)"
    }

    mutating func visitThematicBreak(_: ThematicBreak) -> String { style.label("---") }

    mutating func visitTable(_ table: Table) -> String {
        let rows = table.children.map { visit($0) }.filter { !$0.isEmpty }
        return rows.joined(separator: "\n")
    }

    mutating func visitTableHead(_ head: Table.Head) -> String { defaultVisit(head) }
    mutating func visitTableBody(_ body: Table.Body) -> String { body.children.map { visit($0) }.joined(separator: "\n") }
    mutating func visitTableRow(_ row: Table.Row) -> String { row.children.map { visit($0) }.joined(separator: " | ") }
    mutating func visitTableCell(_ cell: Table.Cell) -> String { defaultVisit(cell).trimmingCharacters(in: .whitespacesAndNewlines) }

    private func visibleHTMLText(_ value: String) -> String {
        value.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
    }
}
