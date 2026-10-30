import Foundation

/// Version ordering exactly as Sparkle 2's `SUStandardVersionComparator` defines it, so "newer"
/// means what the application's own updater decides. Ported from Sparkle
/// (Sparkle/SUStandardVersionComparator.m, MIT license; see NOTICE) and checked
/// against the framework itself:
/// - a version is read up to its first "-" (after the first character);
/// - it splits into runs of digits, runs of other characters, and single separators (period,
///   whitespace, punctuation), all of which count as equal to each other;
/// - the leading run of numbers and periods is padded with ".0" so "1.0" equals "1.0.0" (Sparkle
///   1 doesn't pad: pass `padding: false` for an app that bundles it);
/// - numbers compare as 64-bit values, strings literally, and a number or separator beats a
///   string; with extra parts left, a string means older and anything else newer.
/// Checked against Sparkle 1.26 and 2.6.4 through 2.10 over 60,000 generated version pairs each.
public enum SparkleVersion {
    public static func compare(_ lhs: String, _ rhs: String, padding: Bool = true) -> ComparisonResult {
        var left = parts(lhs)
        var right = parts(rhs)
        if padding { balance(&left, &right) }
        for (a, b) in zip(left, right) {
            let (typeA, typeB) = (a.kind, b.kind)
            if typeA == typeB || (typeA.isSeparator && typeB.isSeparator) {
                if typeA == .number {
                    let (valueA, valueB) = (value(a.text), value(b.text))
                    if valueA != valueB { return valueA > valueB ? .orderedDescending : .orderedAscending }
                } else if typeA == .string {
                    let order = a.text.compare(b.text)
                    if order != .orderedSame { return order }
                }
            } else if typeA != .string, typeB == .string {
                return .orderedDescending
            } else if typeA == .string, typeB != .string {
                return .orderedAscending
            } else {
                // A number against a separator: the separator is invalid.
                return typeA == .number ? .orderedDescending : .orderedAscending
            }
        }
        guard left.count != right.count else { return .orderedSame }
        let longerIsLeft = left.count > right.count
        let extra = longerIsLeft ? left[right.count] : right[left.count]
        if extra.kind == .string { return longerIsLeft ? .orderedAscending : .orderedDescending }
        return longerIsLeft ? .orderedDescending : .orderedAscending
    }

    private enum Kind: Equatable {
        case number, string, period, punctuation, whitespace, dash
        var isSeparator: Bool { self == .period || self == .punctuation || self == .whitespace }
    }
    private struct Part { let kind: Kind; var text: String }

    /// Sparkle classifies by the first character: ".", "-", a decimal digit, whitespace,
    /// punctuation, or anything else.
    private static func kind(of character: Character) -> Kind {
        if character == "." { return .period }
        if character == "-" { return .dash }
        guard let scalar = character.unicodeScalars.first else { return .string }
        let properties = scalar.properties
        if properties.numericType == .decimal { return .number }
        if properties.isWhitespace { return .whitespace }
        switch properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation, .otherPunctuation: return .punctuation
        default: return .string
        }
    }

    private static func parts(_ version: String) -> [Part] {
        var parts: [Part] = []
        for (offset, character) in version.enumerated() {
            let kind = kind(of: character)
            if offset > 0, kind == .dash { break }
            if let last = parts.last, last.kind == kind, !kind.isSeparator {
                parts[parts.count - 1].text.append(character)
            } else {
                parts.append(Part(kind: kind, text: String(character)))
            }
        }
        return parts
    }

    /// Pads the shorter leading run of number and period parts with "0" and "." from the other.
    private static func balance(_ left: inout [Part], _ right: inout [Part]) {
        func leadingCount(_ parts: [Part]) -> Int { parts.prefix { $0.kind == .number || $0.kind == .period }.count }
        let (countLeft, countRight) = (leadingCount(left), leadingCount(right))
        func pad(_ parts: inout [Part], from source: [Part], range: Range<Int>) {
            for index in range {
                parts.insert(source[index].kind == .period ? Part(kind: .period, text: ".") : Part(kind: .number, text: "0"), at: index)
            }
        }
        if countLeft > countRight { pad(&right, from: left, range: countRight..<countLeft) }
        else if countRight > countLeft { pad(&left, from: right, range: countLeft..<countRight) }
    }

    /// `longLongValue`: the leading decimal digits (any script's), saturating at the 64-bit limit.
    private static func value(_ digits: String) -> Int64 {
        var result: Int64 = 0
        for scalar in digits.unicodeScalars {
            guard scalar.properties.numericType == .decimal, let digit = scalar.properties.numericValue else { break }
            let (multiplied, overflow) = result.multipliedReportingOverflow(by: 10)
            let (sum, overflowAgain) = multiplied.addingReportingOverflow(Int64(digit))
            if overflow || overflowAgain { return .max }
            result = sum
        }
        return result
    }
}

public struct SparkleAppcastItem: Equatable, Sendable {
    /// `sparkle:version`, compared against the bundle's CFBundleVersion.
    public let version: String
    /// `sparkle:shortVersionString`, the user-facing version.
    public let shortVersion: String?
    public let channel: String?
    public let minimumSystemVersion: String?
    public let maximumSystemVersion: String?
    public let releaseNotesHTML: String?
    public let releaseNotesURL: String?
    /// The item's `pubDate` as the feed writes it (RFC 822).
    public var publishedAt: String?

    public var displayVersion: String { shortVersion ?? version }

    public init(version: String, shortVersion: String?, channel: String?, minimumSystemVersion: String?, maximumSystemVersion: String?, releaseNotesHTML: String?, releaseNotesURL: String?, publishedAt: String? = nil) {
        self.version = version
        self.shortVersion = shortVersion
        self.channel = channel
        self.minimumSystemVersion = minimumSystemVersion
        self.maximumSystemVersion = maximumSystemVersion
        self.releaseNotesHTML = releaseNotesHTML
        self.releaseNotesURL = releaseNotesURL
        self.publishedAt = publishedAt
    }
}

/// Parses a Sparkle appcast (an RSS feed). External entities are never resolved and only the
/// fields Sparkle itself uses to choose an update are read. Elements nested deeper than an item's
/// direct children (delta enclosures, informational-update version ranges) are ignored, since
/// their `version` values describe other builds.
public final class SparkleAppcastParser: NSObject, XMLParserDelegate {
    private var items: [SparkleAppcastItem] = []
    private var stack: [String] = []
    private var fields: [String: String] = [:]
    private var text = ""

    public static func parse(_ data: Data) throws -> [SparkleAppcastItem] {
        let delegate = SparkleAppcastParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? SparkleAppcastError.malformed }
        return delegate.items
    }

    private static func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let name = Self.localName(elementName)
        stack.append(name)
        text = ""
        if name == "item", stack.count >= 2 {
            fields = [:]
        } else if name == "enclosure", isDirectChildOfItem {
            for (key, value) in attributes {
                let attribute = Self.localName(key)
                if ["version", "shortVersionString"].contains(attribute), fields["enclosure.\(attribute)"] == nil {
                    fields["enclosure.\(attribute)"] = value
                }
            }
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    public func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let name = Self.localName(elementName)
        if name == "item" {
            if let item = makeItem() { items.append(item) }
            fields = [:]
        } else if isDirectChildOfItem {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // The first occurrence wins: a localized duplicate (xml:lang) follows the default.
            if !value.isEmpty, fields[name] == nil { fields[name] = value }
        }
        stack.removeLast()
        text = ""
    }

    /// True while the innermost open element is a direct child of an `item`.
    private var isDirectChildOfItem: Bool {
        stack.count >= 2 && stack[stack.count - 2] == "item"
    }

    private func makeItem() -> SparkleAppcastItem? {
        guard let version = fields["version"] ?? fields["enclosure.version"] else { return nil }
        return SparkleAppcastItem(
            version: version,
            shortVersion: fields["shortVersionString"] ?? fields["enclosure.shortVersionString"],
            channel: fields["channel"],
            minimumSystemVersion: fields["minimumSystemVersion"],
            maximumSystemVersion: fields["maximumSystemVersion"],
            releaseNotesHTML: fields["description"],
            releaseNotesURL: fields["releaseNotesLink"] ?? fields["fullReleaseNotesLink"],
            publishedAt: fields["pubDate"]
        )
    }

    /// The update Sparkle would offer: the newest default-channel item this macOS can run.
    public static func bestItem(_ items: [SparkleAppcastItem], systemVersion: String, padding: Bool = true) -> SparkleAppcastItem? {
        items
            .filter { $0.channel == nil }
            .filter { item in item.minimumSystemVersion.map { SparkleVersion.compare(systemVersion, $0, padding: padding) != .orderedAscending } ?? true }
            .filter { item in item.maximumSystemVersion.map { SparkleVersion.compare(systemVersion, $0, padding: padding) != .orderedDescending } ?? true }
            .max { SparkleVersion.compare($0.version, $1.version, padding: padding) == .orderedAscending }
    }

    /// Whether the bundle ships Sparkle 1, whose version comparison doesn't pad "1.0" to "1.0.0".
    /// Sparkle 1 keeps Autoupdate.app in Resources; Sparkle 2 has Updater.app at the top level.
    static func bundlesSparkle1(_ bundlePath: String) -> Bool {
        let framework = URL(filePath: bundlePath).appending(path: "Contents/Frameworks/Sparkle.framework/Versions/Current")
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: framework.appending(path: "Resources/Autoupdate.app").path) && !fileManager.fileExists(atPath: framework.appending(path: "Updater.app").path)
    }
}

public enum SparkleAppcastError: LocalizedError {
    case malformed
    public var errorDescription: String? { "The appcast is not valid XML." }
}
