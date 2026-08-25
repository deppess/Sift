import Foundation

public enum CatalogRenderer {
    public static func list(_ items: [CatalogItem]) -> String {
        guard !items.isEmpty else { return "No cached user-managed software. Run 'sift refresh' to collect it." }
        var lines = ["Software", ""]
        lines.append(contentsOf: items.map { item in
            let version = (item.installedVersion ?? "Unknown version").terminalInline
            let target = item.updateAvailable ? " -> \(item.availableVersion!)" : ""
            return "\(item.name.terminalInline)\t\(version)\(target.terminalInline)\t\(item.kind.rawValue)"
        })
        return lines.joined(separator: "\n")
    }

    public static func detail(_ item: CatalogItem, notes: HomebrewReleaseNotes?) -> String {
        var lines = [item.name.terminalInline, "", "Selector: \(item.selector.terminalInline)", "Kind: \(item.kind.rawValue)"]
        if let prefix = item.prefix { lines.append("Prefix: \(prefix.terminalInline)") }
        if let tap = item.tap { lines.append("Tap: \(tap.terminalInline)") }
        if let path = item.path { lines.append("Path: \(path.terminalInline)") }
        lines.append("")
        lines.append("Installed: \((item.installedVersion ?? "Unknown").terminalInline)")
        lines.append("Available: \((item.availableVersion ?? item.installedVersion ?? "Unknown").terminalInline)")
        lines.append(item.updateAvailable ? "Status: \(item.autoUpdates ? "self-updating cask" : "update available")" : "Status: current")
        if let notes { lines.append("Changes: \(notes.coverage). Run 'sift show \(item.selector)' for full notes.") }
        else if !item.updateAvailable { lines.append("No version gap; no changelog was fetched.") }
        else { lines.append("Release notes are not cached yet.") }
        return lines.joined(separator: "\n")
    }

    public static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
