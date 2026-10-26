import Foundation

public enum ChangesRenderer {
    public static func humanReadable(_ changes: [NativeVersionTransition]) -> String {
        guard !changes.isEmpty else { return "No cached application version changes." }
        let rows = changes.map { [$0.name.terminalInline, "\($0.fromVersion.terminalInline) -> \($0.toVersion.terminalInline)"] }
        return (["Application changes  \(changes.count)", ""] + TableFormatter.rows(rows)).joined(separator: "\n")
    }

    public static func json(_ changes: [NativeVersionTransition]) throws -> String {
        try JSONOutput.encode(changes)
    }
}
