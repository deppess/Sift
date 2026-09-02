import Foundation

public struct HomebrewTarget: Sendable {
    public let version: String
    public let upstreamVersion: String
    public let sourceURL: String?

    public init(version: String, sourceURL: String?, upstreamVersion: String? = nil) {
        self.version = version
        self.upstreamVersion = upstreamVersion ?? version
        self.sourceURL = sourceURL
    }
}

public enum HomebrewVersion {
    public static func upstreamVersion(from installedVersion: String) -> String {
        guard let separator = installedVersion.lastIndex(of: "_"),
              installedVersion[installedVersion.index(after: separator)...].allSatisfy(\.isNumber) else { return installedVersion }
        return String(installedVersion[..<separator])
    }
}
