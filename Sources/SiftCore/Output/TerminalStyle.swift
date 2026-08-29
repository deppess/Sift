import Foundation

public struct TerminalStyle: Sendable {
    public let enabled: Bool

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }

    public func title(_ value: String) -> String { apply(value, code: "1;36") }
    public func heading(_ value: String) -> String { apply(value, code: "1;34") }
    public func label(_ value: String) -> String { apply(value, code: "2") }
    public func success(_ value: String) -> String { apply(value, code: "32") }
    public func warning(_ value: String) -> String { apply(value, code: "33") }

    private func apply(_ value: String, code: String) -> String {
        guard enabled, !value.isEmpty else { return value }
        return "\u{1B}[\(code)m\(value)\u{1B}[0m"
    }
}
