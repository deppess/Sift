import Foundation

public struct NPMGlobalPackage: Codable, Equatable, Sendable {
    public let name: String
    public let installedVersion: String

    public init(name: String, installedVersion: String) {
        self.name = name
        self.installedVersion = installedVersion
    }
}

public struct NPMGlobalUpdateCandidate: Codable, Equatable, Sendable {
    public let name: String
    public let installedVersion: String
    public let wantedVersion: String
    public let latestVersion: String

    public init(name: String, installedVersion: String, wantedVersion: String, latestVersion: String) {
        self.name = name
        self.installedVersion = installedVersion
        self.wantedVersion = wantedVersion
        self.latestVersion = latestVersion
    }
}

public struct NPMGlobalPrefixInventory: Codable, Equatable, Sendable {
    public let prefix: String
    public let packages: [NPMGlobalPackage]
    public let updateCandidates: [NPMGlobalUpdateCandidate]

    public init(prefix: String, packages: [NPMGlobalPackage], updateCandidates: [NPMGlobalUpdateCandidate]) {
        self.prefix = prefix
        self.packages = packages
        self.updateCandidates = updateCandidates
    }
}

public struct NPMGlobalInventory: Codable, Equatable, Sendable {
    public let prefixes: [NPMGlobalPrefixInventory]

    public init(prefixes: [NPMGlobalPrefixInventory]) {
        self.prefixes = prefixes
    }
}

public enum NPMGlobalProviderError: LocalizedError {
    case commandFailed(executable: URL, command: String, status: Int32)
    case invalidPrefix
    case invalidInventory
    case invalidOutdated

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(executable, command, status):
            "npm command failed (\(status)): \(executable.path) \(command)"
        case .invalidPrefix:
            "npm returned an invalid global prefix."
        case .invalidInventory:
            "npm returned an invalid global package inventory."
        case .invalidOutdated:
            "npm returned an invalid global outdated-package snapshot."
        }
    }
}

public struct NPMGlobalProvider {
    private let runner: CommandRunner
    private let environment: [String: String]

    public init(runner: CommandRunner = CommandRunner(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.runner = runner
        self.environment = environment.merging(["LC_ALL": "C"]) { _, replacement in replacement }
    }

    public func discover() throws -> NPMGlobalInventory {
        var inventories: [NPMGlobalPrefixInventory] = []
        var seenPrefixes = Set<String>()
        for executable in executables() {
            let prefixResult = try run(executable, command: "prefix", arguments: ["prefix", "--global"])
            let prefix = String(decoding: prefixResult.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSafePrefix(prefix) else { throw NPMGlobalProviderError.invalidPrefix }
            guard seenPrefixes.insert(prefix).inserted else { continue }

            let listResult = try run(executable, command: "list", arguments: ["list", "--global", "--depth=0", "--json"])
            let packages = try parseInventory(listResult.stdout)

            let outdatedResult = try runner.run(executable: executable, arguments: ["outdated", "--global", "--depth=0", "--json"] + configurationArguments, environment: environment)
            // npm uses status 1 to report that update candidates exist.
            guard outdatedResult.status == 0 || outdatedResult.status == 1 else {
                throw NPMGlobalProviderError.commandFailed(executable: executable, command: "outdated", status: outdatedResult.status)
            }
            let updates = try parseOutdated(outdatedResult.stdout)
            inventories.append(NPMGlobalPrefixInventory(prefix: prefix, packages: packages, updateCandidates: updates))
        }
        return NPMGlobalInventory(prefixes: inventories.sorted { $0.prefix < $1.prefix })
    }

    private var configurationArguments: [String] {
        ["--ignore-scripts", "--no-audit", "--no-fund", "--no-update-notifier", "--color=false"]
    }

    private func run(_ executable: URL, command: String, arguments: [String]) throws -> CommandResult {
        let result = try runner.run(executable: executable, arguments: arguments + configurationArguments, environment: environment)
        guard result.status == 0 else {
            throw NPMGlobalProviderError.commandFailed(executable: executable, command: command, status: result.status)
        }
        return result
    }

    private func executables() -> [URL] {
        var candidates = [URL(filePath: "/opt/homebrew/bin/npm"), URL(filePath: "/usr/local/bin/npm")]
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").compactMap { entry in
                let directory = String(entry)
                guard directory.hasPrefix("/"), !directory.split(separator: "/").contains("..") else { return nil }
                return URL(filePath: directory, directoryHint: .isDirectory).appending(path: "npm")
            }
        }
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard isRegularExecutable(resolved), seen.insert(resolved.path).inserted else { return nil }
            return resolved
        }
    }

    private func isRegularExecutable(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return false }
        return true
    }

    private func isSafePrefix(_ prefix: String) -> Bool {
        prefix.hasPrefix("/") && !prefix.split(separator: "/").contains("..") && !prefix.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private func parseInventory(_ data: Data) throws -> [NPMGlobalPackage] {
        let document = try JSONDecoder().decode(NPMListOutput.self, from: data)
        guard let dependencies = document.dependencies else { throw NPMGlobalProviderError.invalidInventory }
        return try dependencies.map { name, dependency in
            guard !name.isEmpty, let version = dependency.version, !version.isEmpty else { throw NPMGlobalProviderError.invalidInventory }
            return NPMGlobalPackage(name: name, installedVersion: version)
        }.sorted { $0.name < $1.name }
    }

    private func parseOutdated(_ data: Data) throws -> [NPMGlobalUpdateCandidate] {
        let document = try JSONDecoder().decode([String: NPMOutdatedOutput].self, from: data)
        return try document.map { name, outdated in
            guard !name.isEmpty, !outdated.current.isEmpty, !outdated.wanted.isEmpty, !outdated.latest.isEmpty else { throw NPMGlobalProviderError.invalidOutdated }
            return NPMGlobalUpdateCandidate(name: name, installedVersion: outdated.current, wantedVersion: outdated.wanted, latestVersion: outdated.latest)
        }.sorted { $0.name < $1.name }
    }
}

private struct NPMListOutput: Decodable {
    let dependencies: [String: NPMListDependency]?
}

private struct NPMListDependency: Decodable {
    let version: String?
}

private struct NPMOutdatedOutput: Decodable {
    let current: String
    let wanted: String
    let latest: String
}
