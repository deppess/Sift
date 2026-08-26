import Foundation

public enum HomebrewPackageKind: String, Codable, Sendable { case formula, cask }
public enum HomebrewOwnership: String, Codable, Sendable { case explicitlyRequested, installedCask, dependency }

public struct HomebrewPackage: Sendable {
    public let prefix: String
    public let kind: HomebrewPackageKind
    public let name: String
    public let fullName: String
    public let tap: String?
    public let ownership: HomebrewOwnership
    public let installedVersion: String
    public let sourceURL: String?
    public let homepage: String?
    public let artifactPaths: [String]
    public let autoUpdates: Bool
}

public struct HomebrewPrefixInventory: Sendable {
    public let prefix: String
    public let packages: [HomebrewPackage]
    public let complete: Bool
    public let warnings: [String]
}

public enum HomebrewAvailability: String, Codable, Sendable { case detected, absent }

public struct HomebrewInventory: Sendable {
    public let availability: HomebrewAvailability
    public let prefixes: [HomebrewPrefixInventory]

    public init(availability: HomebrewAvailability = .detected, prefixes: [HomebrewPrefixInventory]) {
        self.availability = availability
        self.prefixes = prefixes
    }

    public var packages: [HomebrewPackage] { prefixes.flatMap(\.packages).sorted { $0.name < $1.name } }
    public var warnings: [String] { prefixes.flatMap(\.warnings) }
}

public struct HomebrewUpdate: Codable, Equatable, Sendable {
    public let kind: HomebrewPackageKind
    public let name: String
    public let fullName: String
    public let prefix: String
    public let installedVersion: String
    public let availableVersion: String
    public let sourceURL: String?
    public let autoUpdates: Bool
    public let freshness: Freshness
    public let dataAsOf: Date?

    public init(kind: HomebrewPackageKind, name: String, fullName: String, prefix: String, installedVersion: String, availableVersion: String, sourceURL: String?, autoUpdates: Bool, freshness: Freshness = .unknown, dataAsOf: Date? = nil) {
        self.kind = kind
        self.name = name
        self.fullName = fullName
        self.prefix = prefix
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.sourceURL = sourceURL
        self.autoUpdates = autoUpdates
        self.freshness = freshness
        self.dataAsOf = dataAsOf
    }
}

public struct HomebrewProvider {
    private let runner: CommandRunner
    private let environment: [String: String]

    public init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner
        self.environment = ProcessInfo.processInfo.environment.merging(["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1", "LC_ALL": "C"]) { _, replacement in replacement }
    }

    public func discover() -> HomebrewInventory {
        var prefixes: [HomebrewPrefixInventory] = []
        var seenPrefixes = Set<String>()
        for executable in executables() {
            var discoveredPrefix: String?
            do {
                let prefixResult = try runner.run(executable: executable, arguments: ["--prefix"], environment: environment)
                guard prefixResult.status == 0 else { throw ProviderError.commandFailed }
                let prefix = String(decoding: prefixResult.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !prefix.isEmpty, seenPrefixes.insert(prefix).inserted else { continue }
                discoveredPrefix = prefix
                let result = try runner.run(executable: executable, arguments: ["info", "--json=v2", "--installed"], environment: environment)
                guard result.status == 0 else { throw ProviderError.commandFailed }
                prefixes.append(HomebrewPrefixInventory(prefix: prefix, packages: try parseInventory(result.stdout, prefix: prefix), complete: true, warnings: []))
            } catch {
                // A failed prefix must remain distinct from a complete empty inventory.
                let prefix = discoveredPrefix ?? executable.deletingLastPathComponent().deletingLastPathComponent().path
                if discoveredPrefix == nil, !seenPrefixes.insert(prefix).inserted { continue }
                prefixes.append(HomebrewPrefixInventory(prefix: prefix, packages: [], complete: false, warnings: ["Homebrew at \(executable.path): \(error.localizedDescription)"]))
            }
        }
        if prefixes.isEmpty { return HomebrewInventory(availability: .absent, prefixes: []) }
        return HomebrewInventory(availability: .detected, prefixes: prefixes.sorted { $0.prefix < $1.prefix })
    }

    private func executables() -> [URL] {
        var urls = [URL(filePath: "/opt/homebrew/bin/brew"), URL(filePath: "/usr/local/bin/brew")]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            urls += path.split(separator: ":").map { URL(filePath: String($0)).appending(path: "brew") }
        }
        var seen = Set<String>()
        return urls.filter { FileManager.default.isExecutableFile(atPath: $0.path) && seen.insert($0.standardizedFileURL.resolvingSymlinksInPath().path).inserted }
    }

    private func parseInventory(_ data: Data, prefix: String) throws -> [HomebrewPackage] {
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderError.commandFailed }
        guard let formulaeDocument = document["formulae"] as? [[String: Any]],
              let casksDocument = document["casks"] as? [[String: Any]] else {
            throw ProviderError.invalidInventory
        }
        let formulae = try formulaeDocument.map { formula -> HomebrewPackage in
            guard let name = formula["name"] as? String,
                  let receipts = formula["installed"] as? [[String: Any]],
                  let receipt = receipts.last(where: { (($0["version"] as? String) ?? "").isEmpty == false }),
                  let version = receipt["version"] as? String else { throw ProviderError.invalidInventory }
            let source = ((formula["urls"] as? [String: Any])?["stable"] as? [String: Any])?["url"] as? String
            return HomebrewPackage(prefix: prefix, kind: .formula, name: name, fullName: formula["full_name"] as? String ?? name, tap: formula["tap"] as? String, ownership: receipt["installed_on_request"] as? Bool == true ? .explicitlyRequested : .dependency, installedVersion: version, sourceURL: source, homepage: formula["homepage"] as? String, artifactPaths: [], autoUpdates: false)
        }
        let casks = try casksDocument.map { cask -> HomebrewPackage in
            guard let token = cask["token"] as? String, !token.isEmpty,
                  let installed = cask["installed"] as? String, !installed.isEmpty else { throw ProviderError.invalidInventory }
            let artifacts = cask["artifacts"] as? [[String: Any]] ?? []
            let artifactPaths = try artifacts.compactMap { artifact -> String? in
                guard artifact["app"] != nil else { return nil }
                guard let appNames = appArtifactNames(artifact) else { throw ProviderError.invalidInventory }
                guard !appNames.isEmpty,
                      let target = artifact["target"] as? String,
                      let path = appTargetPath(target), path.hasSuffix(".app") else { throw ProviderError.invalidInventory }
                return path
            }
            return HomebrewPackage(prefix: prefix, kind: .cask, name: token, fullName: cask["full_token"] as? String ?? token, tap: cask["tap"] as? String, ownership: .installedCask, installedVersion: installed, sourceURL: cask["url"] as? String, homepage: cask["homepage"] as? String, artifactPaths: artifactPaths, autoUpdates: cask["auto_updates"] as? Bool == true)
        }
        return formulae + casks
    }

    private func appArtifactNames(_ artifact: [String: Any]) -> [String]? {
        if let names = artifact["app"] as? [String] { return names.allSatisfy { !$0.isEmpty && $0.hasSuffix(".app") } ? names : nil }
        if let name = artifact["app"] as? String { return !name.isEmpty && name.hasSuffix(".app") ? [name] : nil }
        return nil
    }

    private func appTargetPath(_ target: String) -> String? {
        guard !target.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        let expanded: String
        if target == "~" { expanded = FileManager.default.homeDirectoryForCurrentUser.path }
        else if target.hasPrefix("~/") { expanded = FileManager.default.homeDirectoryForCurrentUser.appending(path: String(target.dropFirst(2))).path }
        else { expanded = target }
        guard expanded.hasPrefix("/") else { return nil }
        let components = expanded.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("..") else { return nil }
        return URL(filePath: expanded).standardizedFileURL.path
    }

    private enum ProviderError: LocalizedError {
        case commandFailed
        case invalidInventory

        var errorDescription: String? {
            switch self {
            case .commandFailed: "Homebrew returned a nonzero status."
            case .invalidInventory: "Homebrew returned an incomplete installed-package inventory."
            }
        }
    }
}
