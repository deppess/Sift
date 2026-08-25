import Foundation

public struct HomebrewTarget: Sendable {
    // `version` is Homebrew's actionable display version. It may include a
    // packaging revision which is not an upstream release version.
    public let version: String
    public let upstreamVersion: String
    public let formulaRevision: Int?
    public let sourceURL: String?

    public init(version: String, sourceURL: String?, upstreamVersion: String? = nil, formulaRevision: Int? = nil) {
        self.version = version
        self.upstreamVersion = upstreamVersion ?? version
        self.formulaRevision = formulaRevision
        self.sourceURL = sourceURL
    }

    public var isPackagingRevisionOnlyUpdate: Bool { formulaRevision != nil }
}

public enum HomebrewVersion {
    public static func upstreamVersion(from installedVersion: String) -> String {
        guard let separator = installedVersion.lastIndex(of: "_"),
              installedVersion[installedVersion.index(after: separator)...].allSatisfy(\.isNumber) else { return installedVersion }
        return String(installedVersion[..<separator])
    }
}

public struct HomebrewAPI: HomebrewTargetResolving {
    private let metadataClient: MetadataHTTPClient?

    public init(metadataClient: MetadataHTTPClient? = nil) {
        self.metadataClient = metadataClient
    }

    public func target(for package: HomebrewPackage) throws -> HomebrewTarget? {
        guard package.tap == "homebrew/core" || package.tap == "homebrew/cask" || package.tap == nil else { return nil }
        let kind = package.kind == .formula ? "formula" : "cask"
        guard let url = URL(string: "https://formulae.brew.sh/api/\(kind)/\(package.name).json") else { return nil }
        let data = try fetch(url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if package.kind == .formula {
            guard let versions = object?["versions"] as? [String: Any], let stable = versions["stable"] as? String else { return nil }
            let revision = object?["revision"] as? Int ?? 0
            return HomebrewTarget(
                version: revision > 0 ? "\(stable)_\(revision)" : stable,
                sourceURL: (((object?["urls"] as? [String: Any])?["stable"] as? [String: Any])?["url"] as? String) ?? package.sourceURL,
                upstreamVersion: stable,
                formulaRevision: revision > 0 ? revision : nil
            )
        }
        guard let version = object?["version"] as? String else { return nil }
        return HomebrewTarget(version: version, sourceURL: object?["url"] as? String ?? package.sourceURL)
    }

    public func resolveTarget(for package: HomebrewPackage) -> HomebrewTargetResolution {
        guard package.tap == "homebrew/core" || package.tap == "homebrew/cask" || package.tap == nil else {
            return .unsupported("Passive target lookup is unavailable for custom Homebrew taps.")
        }
        do {
            guard let target = try target(for: package) else {
                return .unavailable("Homebrew metadata did not contain a comparable target version.")
            }
            return .resolved(target)
        } catch {
            return .transientFailure(error.localizedDescription)
        }
    }

    private func fetch(_ url: URL) throws -> Data {
        guard let metadataClient else { throw HomebrewAPIError.metadataClientUnavailable }
        return try metadataClient.fetch(url, resource: .homebrewTarget).body
    }
}

public enum HomebrewAPIError: LocalizedError {
    case metadataClientUnavailable

    public var errorDescription: String? {
        "Homebrew metadata transport is unavailable."
    }
}
