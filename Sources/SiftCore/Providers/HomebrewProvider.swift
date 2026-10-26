import Foundation

public enum HomebrewPackageKind: String, Codable, Sendable { case formula, cask }
public enum HomebrewOwnership: String, Codable, Sendable { case explicitlyRequested, installedCask, dependency }

public struct HomebrewPackage: Sendable {
    /// The same package, additionally owning `paths`.
    func addingArtifacts(_ paths: [String]) -> HomebrewPackage {
        HomebrewPackage(prefix: prefix, kind: kind, name: name, fullName: fullName, tap: tap, ownership: ownership, installedVersion: installedVersion, sourceURL: sourceURL, artifactPaths: artifactPaths + paths.filter { !artifactPaths.contains($0) }, autoUpdates: autoUpdates)
    }

    public let prefix: String
    public let kind: HomebrewPackageKind
    public let name: String
    public let fullName: String
    public let tap: String?
    public let ownership: HomebrewOwnership
    public let installedVersion: String
    public let sourceURL: String?
    public let artifactPaths: [String]
    public let autoUpdates: Bool
}

public struct HomebrewPrefixInventory: Sendable {
    public let prefix: String
    public let packages: [HomebrewPackage]
    public let complete: Bool
    public let outdatedCandidates: [HomebrewOutdatedCandidate]
    public let outdatedComplete: Bool
    public let warnings: [String]

    public init(prefix: String, packages: [HomebrewPackage], complete: Bool, outdatedCandidates: [HomebrewOutdatedCandidate] = [], outdatedComplete: Bool = false, warnings: [String]) {
        self.prefix = prefix
        self.packages = packages
        self.complete = complete
        self.outdatedCandidates = outdatedCandidates
        self.outdatedComplete = outdatedComplete
        self.warnings = warnings
    }
}

public struct HomebrewOutdatedCandidate: Sendable, Equatable {
    public let kind: HomebrewPackageKind
    public let name: String
    /// Every version Homebrew reports on disk: a cask mid-upgrade or a formula with older kegs
    /// still installed lists more than one.
    public let installedVersions: [String]
    public let availableVersion: String

    public init(kind: HomebrewPackageKind, name: String, installedVersions: [String], availableVersion: String) {
        self.kind = kind
        self.name = name
        self.installedVersions = installedVersions
        self.availableVersion = availableVersion
    }
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
    public let ownership: HomebrewOwnership
    public let freshness: Freshness
    public let dataAsOf: Date?

    public init(kind: HomebrewPackageKind, name: String, fullName: String, prefix: String, installedVersion: String, availableVersion: String, sourceURL: String?, autoUpdates: Bool, ownership: HomebrewOwnership = .explicitlyRequested, freshness: Freshness = .unknown, dataAsOf: Date? = nil) {
        self.kind = kind
        self.name = name
        self.fullName = fullName
        self.prefix = prefix
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.sourceURL = sourceURL
        self.autoUpdates = autoUpdates
        self.ownership = ownership
        self.freshness = freshness
        self.dataAsOf = dataAsOf
    }
}

/// When a refresh runs `brew update` first.
public enum HomebrewUpdatePolicy: Sendable, Equatable {
    /// Only when the prefix's metadata is older than `maximumAge` (Homebrew's own
    /// `HOMEBREW_AUTO_UPDATE_SECS` when set).
    case automatic(maximumAge: TimeInterval = 3_600)
    case always
    case never
}

public struct HomebrewProvider: Sendable {
    private let runner: CommandRunner
    let environment: [String: String]
    private let standardDirectories: [String]

    public init(runner: CommandRunner = CommandRunner(), environment: [String: String] = ProcessInfo.processInfo.environment, standardDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]) {
        self.runner = runner
        self.environment = environment.merging(["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1", "LC_ALL": "C"]) { _, replacement in replacement }
        self.standardDirectories = standardDirectories
    }

    /// When `brew update` last finished for `prefix`: Homebrew rewrites its repository's
    /// `FETCH_HEAD` and its API snapshots on every update, so their newest modification time is
    /// read straight from disk without starting `brew`. `nil` when neither exists.
    func metadataUpdatedAt(prefix: String) -> Date? {
        let files = ["\(prefix)/.git/FETCH_HEAD", "\(prefix)/Homebrew/.git/FETCH_HEAD"] + apiSnapshotFiles()
        return files.compactMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }.max()
    }

    private func shouldUpdate(prefix: String, policy: HomebrewUpdatePolicy, now: Date) -> (update: Bool, lastUpdated: Date?) {
        switch policy {
        case .never: return (false, nil)
        case .always: return (true, metadataUpdatedAt(prefix: prefix))
        case let .automatic(maximumAge):
            let age = environment["HOMEBREW_AUTO_UPDATE_SECS"].flatMap(TimeInterval.init).flatMap { $0 > 0 ? $0 : nil } ?? maximumAge
            let lastUpdated = metadataUpdatedAt(prefix: prefix)
            return (lastUpdated.map { now.timeIntervalSince($0) >= age } ?? true, lastUpdated)
        }
    }

    /// Reads every detected prefix. `update` decides per prefix whether `brew update` runs first;
    /// a failed update is a warning and the refresh continues with the metadata already on disk.
    /// `progress` hears about each update before it starts, since it is the slow step. With
    /// `snapshots`, a prefix whose fingerprint is unchanged reuses its saved output instead of
    /// running `brew info` and `brew outdated`.
    public func discover(update: HomebrewUpdatePolicy = .never, now: Date = .now, snapshots: (any HomebrewSnapshotStoring)? = nil, progress: (@Sendable (String) -> Void)? = nil) -> HomebrewInventory {
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
                var updateWarnings: [String] = []
                let (needsUpdate, lastUpdated) = shouldUpdate(prefix: prefix, policy: update, now: now)
                if needsUpdate {
                    progress?("Updating Homebrew metadata\(lastUpdated.map { " (last updated \(DashboardRenderer.relativeTimestamp($0, relativeTo: now)))" } ?? "")…")
                    do {
                        let result = try runner.run(executable: executable, arguments: ["update", "--quiet"], environment: environment, timeout: 120)
                        guard result.status == 0 else { throw ProviderError.commandFailed }
                    } catch {
                        updateWarnings.append("Homebrew update at \(executable.path): \(error.localizedDescription)")
                    }
                }
                let fingerprint = snapshots.map { _ in snapshotFingerprint(executable: executable, prefix: prefix) }
                let saved = fingerprint.flatMap { snapshots?.homebrewSnapshot(prefix: prefix, fingerprint: $0, notBefore: now.addingTimeInterval(-Self.snapshotMaximumAge)) }
                let info: Data
                let outdatedRun: Concurrent<Result<CommandResult, Error>>
                if let saved {
                    info = saved.info
                    outdatedRun = Concurrent { .success(CommandResult(status: 0, stdout: saved.outdated, stderr: Data())) }
                } else {
                    // The two snapshots are independent reads, so they run side by side.
                    let runner = runner
                    let environment = environment
                    outdatedRun = Concurrent { Result { try runner.run(executable: executable, arguments: ["outdated", "--json=v2", "--greedy-auto-updates"], environment: environment) } }
                    let result = try runner.run(executable: executable, arguments: ["info", "--json=v2", "--installed"], environment: environment)
                    guard result.status == 0 else { throw ProviderError.commandFailed }
                    info = result.stdout
                }
                let (packages, inventoryWarnings) = try parseInventory(info, prefix: prefix)
                do {
                    let outdated = try outdatedRun.value.get()
                    guard outdated.status == 0 else { throw ProviderError.commandFailed }
                    let (outdatedCandidates, outdatedWarnings) = try parseOutdated(outdated.stdout)
                    if saved == nil, let fingerprint, let snapshots {
                        snapshots.storeHomebrewSnapshot(prefix: prefix, fingerprint: fingerprint, info: info, outdated: outdated.stdout, at: now)
                    }
                    prefixes.append(HomebrewPrefixInventory(prefix: prefix, packages: packages, complete: true, outdatedCandidates: outdatedCandidates, outdatedComplete: true, warnings: updateWarnings + inventoryWarnings + outdatedWarnings))
                } catch {
                    prefixes.append(HomebrewPrefixInventory(prefix: prefix, packages: packages, complete: true, warnings: updateWarnings + inventoryWarnings + ["Homebrew outdated snapshot at \(executable.path): \(error.localizedDescription)"]))
                }
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
        discoverExecutables(named: "brew", standardDirectories: standardDirectories, environment: environment)
    }

    /// A single malformed formula or cask entry is skipped (with a warning) rather than failing the
    /// whole `info --installed` snapshot: one unreadable package's shape must not discard every
    /// other healthy package in the same prefix.
    private func parseInventory(_ data: Data, prefix: String) throws -> (packages: [HomebrewPackage], warnings: [String]) {
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderError.commandFailed }
        guard let formulaeDocument = document["formulae"] as? [[String: Any]],
              let casksDocument = document["casks"] as? [[String: Any]] else {
            throw ProviderError.invalidInventory
        }
        var warnings: [String] = []
        let formulae = formulaeDocument.compactMap { formula -> HomebrewPackage? in
            let name = formula["name"] as? String
            guard let name, !name.isEmpty, let receipts = formula["installed"] as? [[String: Any]] else {
                warnings.append("Skipped a Homebrew formula entry\((formula["name"] as? String).map { " for \($0)" } ?? ""): unexpected shape.")
                return nil
            }
            let usableReceipts = receipts.filter { (($0["version"] as? String) ?? "").isEmpty == false }
            // A keg-only or force-installed formula can have multiple versions on disk at once.
            // `linked_keg` names the one Homebrew actually considers active; when it isn't set
            // (common for keg-only formulae, which are never linked), fall back to the most
            // recently installed receipt rather than whichever happens to sort last in the array,
            // since array order isn't a documented, stable proxy for "the active install."
            let linkedKeg = formula["linked_keg"] as? String
            let receipt = (linkedKeg.flatMap { keg in usableReceipts.first(where: { ($0["version"] as? String) == keg }) })
                ?? usableReceipts.max(by: { (($0["time"] as? Int) ?? 0) < (($1["time"] as? Int) ?? 0) })
            guard let receipt, let version = receipt["version"] as? String else {
                warnings.append("Skipped Homebrew formula \(name): no usable installed version was reported.")
                return nil
            }
            let source = ((formula["urls"] as? [String: Any])?["stable"] as? [String: Any])?["url"] as? String
            return HomebrewPackage(prefix: prefix, kind: .formula, name: name, fullName: formula["full_name"] as? String ?? name, tap: formula["tap"] as? String, ownership: receipt["installed_on_request"] as? Bool == true ? .explicitlyRequested : .dependency, installedVersion: version, sourceURL: source, artifactPaths: [], autoUpdates: false)
        }
        let casks = casksDocument.compactMap { cask -> HomebrewPackage? in
            let token = cask["token"] as? String
            guard let token, !token.isEmpty, let installed = cask["installed"] as? String, !installed.isEmpty else {
                warnings.append("Skipped a Homebrew cask entry\((cask["token"] as? String).map { " for \($0)" } ?? ""): unexpected shape.")
                return nil
            }
            let artifacts = cask["artifacts"] as? [[String: Any]] ?? []
            // A malformed artifact entry only drops that one artifact path (used for cask-owned-app
            // suppression), not the whole cask: it's supplementary data, not the cask's identity.
            let artifactPaths = artifacts.compactMap { artifact -> String? in
                guard artifact["app"] != nil else { return nil }
                guard let appNames = appArtifactNames(artifact), !appNames.isEmpty,
                      let target = artifact["target"] as? String,
                      let path = appTargetPath(target), path.hasSuffix(".app") else { return nil }
                return path
            }
            return HomebrewPackage(prefix: prefix, kind: .cask, name: token, fullName: cask["full_token"] as? String ?? token, tap: cask["tap"] as? String, ownership: .installedCask, installedVersion: installed, sourceURL: cask["url"] as? String, artifactPaths: artifactPaths, autoUpdates: cask["auto_updates"] as? Bool == true)
        }
        return (formulae + casks, warnings)
    }

    /// Returns the candidates Homebrew's `outdated` snapshot reports, plus a warning for each
    /// entry that couldn't be parsed. A malformed entry is skipped rather than failing the whole
    /// snapshot, so only that package falls back to "not reported as outdated".
    private func parseOutdated(_ data: Data) throws -> (candidates: [HomebrewOutdatedCandidate], warnings: [String]) {
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderError.invalidOutdated }
        var warnings: [String] = []
        func candidates(_ key: String, kind: HomebrewPackageKind) throws -> [HomebrewOutdatedCandidate] {
            guard let entries = document[key] as? [[String: Any]] else { throw ProviderError.invalidOutdated }
            return entries.compactMap { entry in
                let name = (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                guard let name,
                      let versions = (entry["installed_versions"] as? [String])?.filter({ !$0.isEmpty }), !versions.isEmpty,
                      let availableVersion = entry["current_version"] as? String, !availableVersion.isEmpty else {
                    warnings.append("Skipped an outdated \(kind == .formula ? "formula" : "cask") entry\(name.map { " for \($0)" } ?? ""): Homebrew reported an unexpected shape.")
                    return nil
                }
                return HomebrewOutdatedCandidate(kind: kind, name: name, installedVersions: versions, availableVersion: availableVersion)
            }
        }
        return (try candidates("formulae", kind: .formula) + candidates("casks", kind: .cask), warnings)
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
        case invalidOutdated

        var errorDescription: String? {
            switch self {
            case .commandFailed: "Homebrew returned a nonzero status."
            case .invalidInventory: "Homebrew returned an incomplete installed-package inventory."
            case .invalidOutdated: "Homebrew returned an incomplete outdated-package snapshot."
            }
        }
    }
}
