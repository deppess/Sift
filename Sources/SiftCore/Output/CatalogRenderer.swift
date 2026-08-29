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
        let installed = (item.installedVersion ?? "Unknown").terminalInline
        let available = (item.availableVersion ?? item.installedVersion ?? "Unknown").terminalInline
        let version = item.updateAvailable ? "\(installed) -> \(available)" : installed
        let kind = item.kind == .homebrewFormula ? "Homebrew formula" : item.kind == .homebrewCask ? "Homebrew cask" : "Native app"
        let status = item.updateAvailable ? (item.autoUpdates ? "self-updating" : "update available") : "current"
        var lines = ["\(item.name.terminalInline)  \(version)", "\(kind) · \(status)"]
        if let prefix = item.prefix { lines.append("Prefix: \(prefix.terminalInline)\(item.tap.map { " · \($0.terminalInline)" } ?? "")") }
        else if let path = item.path { lines.append("Path: \(path.terminalInline)") }
        if let notes { lines.append("Notes: \(notes.coverage == "complete" ? "complete range" : "target release") · sift show \(item.selector.terminalInline) --full") }
        else if item.updateAvailable { lines.append("Notes: unavailable") }
        return lines.joined(separator: "\n")
    }

    public static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
