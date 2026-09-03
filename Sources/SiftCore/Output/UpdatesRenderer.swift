import Foundation

public enum UpdatesRenderer {
    public static func humanReadable(_ updates: [UnifiedUpdate]) -> String {
        guard !updates.isEmpty else { return "No cached updates available." }
        var lines = ["Updates  \(updates.count)", ""]
        lines.append(contentsOf: updates.map { "\($0.name.terminalInline)\t\($0.installedVersion.terminalInline) -> \($0.availableVersion.terminalInline)\t\($0.provider.terminalInline)\t\($0.scope.terminalInline)" })
        return lines.joined(separator: "\n")
    }

    public static func json(_ updates: [UnifiedUpdate]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(updates), as: UTF8.self)
    }
}
