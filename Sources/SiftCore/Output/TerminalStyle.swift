import Foundation

public struct TerminalStyle: Sendable {
    public let enabled: Bool

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }

    /// A small list mark echoes the orange card on Sift's dark-blue app icon.
    public func brand(_ value: String) -> String {
        guard enabled else { return value }
        return "\(accent("▤")) \(title(value))"
    }

    public func title(_ value: String) -> String { apply(value, code: "1;38;5;75") }
    public func heading(_ value: String) -> String { apply(value, code: "1;38;5;75") }
    public func accent(_ value: String) -> String { apply(value, code: "38;5;209") }
    public func label(_ value: String) -> String { apply(value, code: "2") }
    public func success(_ value: String) -> String { apply(value, code: "32") }
    public func warning(_ value: String) -> String { accent(value) }

    private func apply(_ value: String, code: String) -> String {
        guard enabled, !value.isEmpty else { return value }
        return "\u{1B}[\(code)m\(value)\u{1B}[0m"
    }
}
