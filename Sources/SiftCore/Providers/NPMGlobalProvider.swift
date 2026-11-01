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
    public let outdatedComplete: Bool

    public init(prefix: String, packages: [NPMGlobalPackage], updateCandidates: [NPMGlobalUpdateCandidate], outdatedComplete: Bool = true) {
        self.prefix = prefix
        self.packages = packages
        self.updateCandidates = updateCandidates
        self.outdatedComplete = outdatedComplete
    }
}

public struct NPMGlobalInventory: Codable, Equatable, Sendable {
    public let prefixes: [NPMGlobalPrefixInventory]
    public let warnings: [String]

    public init(prefixes: [NPMGlobalPrefixInventory], warnings: [String] = []) {
        self.prefixes = prefixes
        self.warnings = warnings
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

public struct NPMGlobalProvider: Sendable {
    private let runner: CommandRunner
    private let environment: [String: String]
    private let standardDirectories: [String]

    public init(
        runner: CommandRunner = CommandRunner(), environment: [String: String] = ProcessInfo.processInfo.environment,
        standardDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]
    ) {
        self.runner = runner
        self.environment = environment.merging(["LC_ALL": "C", "NO_COLOR": "1", "FORCE_COLOR": "0", "npm_config_color": "false"]) { _, replacement in
            replacement
        }
        self.standardDirectories = standardDirectories
    }

    public func discover() -> NPMGlobalInventory {
        var inventories: [NPMGlobalPrefixInventory] = []
        var warnings: [String] = []
        var seenPrefixes = Set<String>()
        for executable in executables() {
            do {
                // Each npm start costs ~0.15s and the listing doesn't depend on the prefix, so both
                // run at once; a listing for an already-seen prefix is discarded.
                let provider = self
                let listRun = Concurrent { Result { try provider.run(executable, command: "list", arguments: ["list", "--global", "--depth=0", "--json"]) } }
                let prefixResult = try run(executable, command: "prefix", arguments: ["prefix", "--global"])
                let prefix = String(decoding: prefixResult.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard isSafeAbsolutePath(prefix) else { throw NPMGlobalProviderError.invalidPrefix }
                guard seenPrefixes.insert(prefix).inserted else { continue }

                let listResult = try listRun.value.get()
                let (listedPackages, inventoryWarnings) = try parseInventory(listResult.stdout)
                warnings.append(contentsOf: inventoryWarnings)
                // npm is its own runtime, not a user-installed global tool.
                let packages = listedPackages.filter { $0.name != "npm" }
                // `npm outdated` contacts the registry for every global package, npm included, and is
                // by far the slowest provider call; with nothing to track there is nothing to ask.
                guard !packages.isEmpty else {
                    inventories.append(NPMGlobalPrefixInventory(prefix: prefix, packages: [], updateCandidates: []))
                    continue
                }

                do {
                    let outdatedResult = try runner.run(
                        executable: executable, arguments: ["outdated", "--global", "--depth=0", "--json"] + configurationArguments, environment: environment)
                    // npm uses status 1 to report that update candidates exist.
                    guard outdatedResult.status == 0 || outdatedResult.status == 1 else {
                        throw NPMGlobalProviderError.commandFailed(executable: executable, command: "outdated", status: outdatedResult.status)
                    }
                    let updates = try parseOutdated(outdatedResult.stdout)
                    // npm can report a per-package registry/network error (e.g. a timeout checking
                    // one package) by printing "npm error"/"npm ERR!" to stderr while still exiting
                    // 0/1 and returning valid JSON for every package it *did* check successfully —
                    // the failed package is simply missing from the JSON, which looks identical to
                    // "no update available." Treat that stderr signal as reason to distrust this
                    // round's outdated snapshot entirely, so a real cached update for the omitted
                    // package is retained rather than silently cleared.
                    let stderrText = String(decoding: outdatedResult.stderr, as: UTF8.self)
                    if stderrText.range(of: "npm error", options: .caseInsensitive) != nil || stderrText.range(of: "npm ERR!") != nil {
                        warnings.append(
                            "npm outdated snapshot at \(executable.path) reported an error for at least one package: \(stderrText.trimmingCharacters(in: .whitespacesAndNewlines))"
                        )
                        inventories.append(NPMGlobalPrefixInventory(prefix: prefix, packages: packages, updateCandidates: updates, outdatedComplete: false))
                    } else {
                        inventories.append(NPMGlobalPrefixInventory(prefix: prefix, packages: packages, updateCandidates: updates))
                    }
                } catch {
                    warnings.append("npm outdated snapshot at \(executable.path): \(error.localizedDescription)")
                    inventories.append(NPMGlobalPrefixInventory(prefix: prefix, packages: packages, updateCandidates: [], outdatedComplete: false))
                }
            } catch {
                // A failed installation must not discard prefixes that other installations reported successfully.
                warnings.append("npm at \(executable.path): \(error.localizedDescription)")
            }
        }
        return NPMGlobalInventory(prefixes: inventories.sorted { $0.prefix < $1.prefix }, warnings: warnings)
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
        discoverExecutables(named: "npm", standardDirectories: standardDirectories, environment: environment)
    }

    /// A package npm reports with no usable version (e.g. a broken symlink, an "invalid" or
    /// "extraneous" global install) is skipped rather than failing the whole inventory: one
    /// unhealthy package must not discard every other healthy package in the same prefix.
    private func parseInventory(_ data: Data) throws -> (packages: [NPMGlobalPackage], warnings: [String]) {
        let document = try JSONDecoder().decode(NPMListOutput.self, from: data)
        guard let dependencies = document.dependencies else { throw NPMGlobalProviderError.invalidInventory }
        var warnings: [String] = []
        let packages = dependencies.compactMap { name, dependency -> NPMGlobalPackage? in
            guard !name.isEmpty, let version = dependency.version, !version.isEmpty else {
                warnings.append("Skipped an npm global package entry\(name.isEmpty ? "" : " for \(name)"): no usable installed version was reported.")
                return nil
            }
            return NPMGlobalPackage(name: name, installedVersion: version)
        }.sorted { $0.name < $1.name }
        return (packages, warnings)
    }

    private func parseOutdated(_ data: Data) throws -> [NPMGlobalUpdateCandidate] {
        let document = try JSONDecoder().decode([String: NPMOutdatedOutput].self, from: data)
        return try document.map { name, outdated in
            guard !name.isEmpty, !outdated.current.isEmpty, !outdated.wanted.isEmpty, !outdated.latest.isEmpty else {
                throw NPMGlobalProviderError.invalidOutdated
            }
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
