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

    /// A cask version's upstream part: Homebrew appends build metadata after a comma
    /// ("158.0.1,2" is version 158.0.1, build 2).
    public static func caskUpstreamVersion(from caskVersion: String) -> String {
        caskVersion.split(separator: ",", maxSplits: 1).first.map(String.init) ?? caskVersion
    }
}
