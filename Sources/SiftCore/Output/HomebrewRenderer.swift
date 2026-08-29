import Foundation

public enum HomebrewRenderer {
    public static func humanReadable(_ updates: [HomebrewUpdate]) -> String {
        guard !updates.isEmpty else { return "No updates available for user-installed Homebrew packages." }
        var lines = ["Available updates", ""]
        lines.append(contentsOf: updates.map {
            let status = $0.freshness == .current ? "current" : "\($0.freshness.rawValue); data as of \($0.dataAsOf?.ISO8601Format() ?? "unknown")"
            return "\($0.name.terminalInline)\t\($0.installedVersion.terminalInline) -> \($0.availableVersion.terminalInline)\t\($0.autoUpdates ? "auto-updates" : $0.kind.rawValue)\t\(status.terminalInline)"
        })
        return lines.joined(separator: "\n")
    }

    public static func json(_ updates: [HomebrewUpdate]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(updates), as: UTF8.self)
    }

    public static func show(_ notes: HomebrewReleaseNotes, full: Bool = false, style: TerminalStyle = TerminalStyle(enabled: false)) -> String {
        let title = style.title(notes.name.terminalInline)
        let version = "\(notes.installedVersion.terminalInline) -> \(notes.availableVersion.terminalInline)"
        let coverage = notes.coverage == "complete" ? style.success("complete range") : style.warning("target release")
        let content = full ? notes.content.terminalText : compactNotes(notes.content, style: style)
        return "\(title)  \(version)\n\(style.label("Notes:")) \(coverage)\n\(content)\n\(style.label("Source:")) \(notes.sourceURL.terminalInline)"
    }

    private static func compactNotes(_ content: String, style: TerminalStyle) -> String {
        let lines = content.terminalText.components(separatedBy: .newlines)
        var displayed: [String] = []
        var omittedLines = 0
        var omittedSections = 0
        var skipping = false
        var visibleContentLines = 0
        let maximumContentLines = 14

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let heading = markdownHeading(line) {
                if heading.caseInsensitiveCompare("release notes") == .orderedSame { continue }
                skipping = isBoilerplateHeading(heading)
                if skipping {
                    omittedSections += 1
                    continue
                }
                if visibleContentLines >= maximumContentLines {
                    omittedSections += 1
                    skipping = true
                    continue
                }
                displayed.append(style.heading(heading))
                visibleContentLines += 1
                continue
            }
            if skipping {
                if !line.isEmpty { omittedLines += 1 }
                continue
            }
            guard !line.isEmpty else { continue }
            if visibleContentLines >= maximumContentLines {
                omittedLines += 1
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                displayed.append("  \(style.label("•")) \(markdownText(String(line.dropFirst(2))))")
            } else {
                displayed.append(markdownText(line))
            }
            visibleContentLines += 1
        }

        while displayed.last?.isEmpty == true { displayed.removeLast() }
        if omittedSections > 0 || omittedLines > 0 {
            let detail = "\(omittedSections) section\(omittedSections == 1 ? "" : "s") and \(omittedLines) line\(omittedLines == 1 ? "" : "s") omitted"
            displayed.append("\(style.label("… \(detail).")) Use 'sift show <package> --full' for complete notes.")
        }
        return displayed.isEmpty ? "No displayable release notes." : displayed.joined(separator: "\n")
    }

    private static let boilerplateHeadings: Set<String> = [
        "install", "download", "checksums", "verifying github artifact attestations", "verification"
    ]

    private static func isBoilerplateHeading(_ heading: String) -> Bool {
        let normalized = heading.lowercased()
        return boilerplateHeadings.contains(normalized) || normalized.hasPrefix("install ") || normalized.hasPrefix("download ")
    }

    private static func markdownHeading(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 3 else { return nil }
        let remainder = line.dropFirst(hashes.count)
        guard remainder.first == " " else { return nil }
        return markdownText(remainder.dropFirst().trimmingCharacters(in: .whitespaces))
    }

    private static func markdownText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "`", with: "")
    }
}
