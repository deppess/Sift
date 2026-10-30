import Foundation

/// Whether `url` is plausibly a trackable, top-level installed application: it has a Contents
/// directory (a directory named "*.app" is not necessarily a real bundle — macOS's App Sandbox
/// creates empty "<extension-bundle-id>.app"-named script containers under
/// ~/Library/Application Scripts for app extensions, and any ordinary folder can coincidentally be
/// named "*.app"), and it isn't nested inside another bundle (a framework's internal Helpers
/// directory, a LoginItem tucked in another app's Contents, an XPC service, etc. — these have no
/// independent update lifecycle; they're updated as part of whatever they're embedded in, and are
/// what's actually responsible for "system" noise like framework helper daemons or a game's
/// embedded crash reporter showing up as separate "apps", since Spotlight indexes them like any
/// other bundle, deeply nested or not).
///
/// Shared by `NativeApplicationProvider.discover()` (decides what counts as a candidate at all,
/// before anything is tracked as "seen") and `Database.applyNativeInventoryLocked` (decides whether
/// a previously tracked, Spotlight-only installation has genuinely disappeared): both need the same
/// answer, or a path this function now excludes would still exist on disk and never get reconciled
/// away, since the on-disk-existence check on its own can't tell "genuinely still installed" apart
/// from "was never a trackable application in the first place."
func isPlausibleNativeApplicationBundle(_ url: URL) -> Bool {
    guard FileManager.default.fileExists(atPath: url.appending(path: "Contents").path) else { return false }
    let nestedBundleExtensions: Set<String> = ["app", "framework", "bundle", "xpc", "appex", "plugin", "kext"]
    var ancestor = url.deletingLastPathComponent()
    while ancestor.pathComponents.count > 1 {
        if nestedBundleExtensions.contains(ancestor.pathExtension.lowercased()) { return false }
        ancestor = ancestor.deletingLastPathComponent()
    }
    return true
}

public struct NativeApplicationProvider: Sendable {
    public static let identifier = "native-apps"
    public let roots: [NativeSearchRoot]
    public let maximumDepth: Int
    public let includeSpotlight: Bool
    private let runner: CommandRunner

    private let homeDirectory: String

    public init(roots: [NativeSearchRoot] = defaultRoots(), maximumDepth: Int = .max, includeSpotlight: Bool? = nil, runner: CommandRunner = CommandRunner(), homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.homeDirectory = homeDirectory
        self.roots = roots
        self.maximumDepth = maximumDepth
        self.includeSpotlight = includeSpotlight ?? (roots.map(\.url) == Self.defaultRoots().map(\.url))
        self.runner = runner
    }

    public func discover() -> NativeInventoryResult {
        guard maximumDepth >= 0, roots.allSatisfy(\.url.isFileURL) else {
            return NativeInventoryResult(applications: [], warnings: ["Invalid native application search-root configuration."], complete: false)
        }
        var applications: [NativeApplication] = []
        var warnings: [String] = []
        var scannedRoots: [String] = []
        var candidatePaths = Set<String>()
        // `url` is the path Sift records (which may be a symlink, e.g. /Applications/Safari.app);
        // `bundle` is the real bundle directory its metadata is read from.
        var candidates: [(url: URL, bundle: URL, root: URL, classification: ApplicationClassification)] = []
        var seenCandidates = Set<String>()
        // Firmlinks (e.g. /Applications aliasing /System/Volumes/Data/Applications) are not
        // symlinks, so resolvingSymlinksInPath() can't normalize between the two spellings the
        // directory walk and Spotlight might each report for the identical bundle. Device+inode
        // identity catches that case even when the path strings genuinely differ.
        var seenIdentities = Set<FileIdentity>()
        var complete = true
        // Spotlight answers in ~35 ms on its own, so the query runs while the roots are walked.
        let provider = self
        let spotlight = includeSpotlight ? Concurrent { Result { try provider.spotlightPaths() } } : nil

        for root in roots {
            let normalizedRoot = root.url.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: normalizedRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                if root.required {
                    warnings.append("Required application root is unavailable: \(normalizedRoot.path)")
                    complete = false
                }
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: normalizedRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                // Not .skipsHiddenFiles: that also skips entries carrying the BSD hidden flag, which
                // macOS sets on /Applications/Safari.app. Dot-files are skipped by name below.
                options: [],
                errorHandler: { _, error in
                    warnings.append("Unable to enumerate \(normalizedRoot.path): \(error.localizedDescription)")
                    complete = false
                    return true
                }
            ) else {
                warnings.append("Unable to enumerate \(normalizedRoot.path).")
                complete = false
                continue
            }
            scannedRoots.append(normalizedRoot.path)
            for case let candidate as URL in enumerator {
                if candidate.lastPathComponent.hasPrefix(".") { enumerator.skipDescendants(); continue }
                let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let isSymbolicLink = values?.isSymbolicLink == true
                // A bundle directly inside a root is depth zero; only containing directories consume depth.
                let depth = max(0, candidate.pathComponents.count - normalizedRoot.pathComponents.count - 1)
                if depth > maximumDepth { enumerator.skipDescendants(); continue }
                // Symlinked directories are never descended into; only a symlink that is itself an
                // application bundle (macOS ships /Applications/Safari.app this way) is followed.
                guard candidate.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                let normalized = candidate.standardizedFileURL
                guard isContained(normalized, in: normalizedRoot) else { continue }
                // Checked before candidatePaths tracks it at all, not just before parsing it as an
                // application: a path that isn't a plausible application bundle was never a real,
                // trackable app, so it must not count as "seen" either — otherwise a stale record for
                // it would never be reconciled away.
                guard isPlausibleNativeApplicationBundle(normalized), let bundle = resolvedBundle(normalized, isSymbolicLink: isSymbolicLink) else { continue }
                candidatePaths.insert(normalized.path)
                guard seenIdentities.insert(fileIdentity(bundle) ?? FileIdentity(path: bundle.path)).inserted else { continue }
                // A linked bundle takes its classification from where it really lives, so Safari's
                // Cryptex link in /Applications is still an Apple system application.
                let classification = isSymbolicLink ? Self.classification(forPath: bundle.path, homeDirectory: homeDirectory) : root.classification
                if seenCandidates.insert(normalized.path).inserted { candidates.append((normalized, bundle, normalizedRoot, classification)) }
            }
        }
        if let spotlight {
            do {
                // Computed once outside the loop below: every Spotlight candidate is tested against
                // the same normalized root set, so normalizing per-candidate would just repeat work.
                let normalizedRoots = roots.map { (root: $0, normalizedURL: $0.url.standardizedFileURL.resolvingSymlinksInPath()) }
                for path in try spotlight.value.get() {
                    let rawCandidate = URL(filePath: path).standardizedFileURL
                    let isSymbolicLink = (try? rawCandidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
                    // Directory components are resolved, but a candidate that is itself a link keeps
                    // its own name, matching the directory walk.
                    let candidate = isSymbolicLink ? rawCandidate.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: rawCandidate.lastPathComponent) : rawCandidate.resolvingSymlinksInPath()
                    guard candidate.pathExtension.lowercased() == "app" else { continue }
                    guard isPlausibleNativeApplicationBundle(candidate), let bundle = resolvedBundle(candidate, isSymbolicLink: isSymbolicLink) else { continue }
                    candidatePaths.insert(candidate.path)
                    // Same physical bundle as one the directory walk already found under a different
                    // spelling (see seenIdentities above) — the path is still recorded as "seen" for
                    // reconciliation, but it doesn't get a second, duplicate application entry.
                    guard seenIdentities.insert(fileIdentity(bundle) ?? FileIdentity(path: bundle.path)).inserted else { continue }
                    guard seenCandidates.insert(candidate.path).inserted else { continue }
                    let matchedRoot = normalizedRoots
                        .filter { isContained(candidate, in: $0.normalizedURL) }
                        .max { $0.normalizedURL.path.count < $1.normalizedURL.path.count }
                    let classification = isSymbolicLink || matchedRoot == nil ? Self.classification(forPath: bundle.path, homeDirectory: homeDirectory) : matchedRoot!.root.classification
                    candidates.append((candidate, bundle, matchedRoot?.normalizedURL ?? URL(filePath: "/", directoryHint: .isDirectory), classification))
                }
                // Spotlight's completeness can never be proven (privacy exclusions, disabled
                // indexing, unindexed volumes), so a successful mdfind run must not be treated as
                // authoritative for deactivating apps outside the explicitly scanned roots.
            } catch {
                warnings.append("Spotlight application search: \(error.localizedDescription)")
                complete = false
            }
        }
        // Each bundle's metadata is read independently, so they're read across all cores.
        let found = candidates
        let results = UnsafeResults<Result<NativeApplication?, Error>>(count: found.count)
        DispatchQueue.concurrentPerform(iterations: found.count) { index in
            let candidate = found[index]
            results[index] = Result { try application(at: candidate.url, bundle: candidate.bundle, root: candidate.root, classification: candidate.classification) }
        }
        for (candidate, result) in zip(found, results.values) {
            switch result {
            case let .success(application?): applications.append(application)
            case .success(nil): break
            case let .failure(error):
                warnings.append("Unable to read \(candidate.url.lastPathComponent): \(error.localizedDescription)")
                // This bundle's data was not actually refreshed; the provider must not report a
                // clean success, and a partial scan cannot prove any other application disappeared.
                complete = false
            }
        }
        return NativeInventoryResult(applications: applications.sorted { $0.path < $1.path }, warnings: warnings, complete: complete, scannedRoots: scannedRoots, candidatePaths: candidatePaths)
    }

    /// One bundle read the way discovery reads it, for an app already in the catalog.
    public func application(atPath path: String) -> NativeApplication? {
        let url = URL(filePath: path, directoryHint: .isDirectory)
        let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        guard let bundle = resolvedBundle(url, isSymbolicLink: isLink) else { return nil }
        return try? application(at: url, bundle: bundle, root: url.deletingLastPathComponent(), classification: .user)
    }

    private func application(at url: URL, bundle: URL, root: URL, classification: ApplicationClassification) throws -> NativeApplication? {
        let values = try bundle.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
        let plistURL = bundle.appending(path: "Contents/Info.plist")
        let plistValues = try plistURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard plistValues.isRegularFile == true, plistValues.isSymbolicLink != true else { throw NativeInventoryError.invalidMetadata }
        guard (plistValues.fileSize ?? 0) <= 1_048_576 else { throw NativeInventoryError.metadataTooLarge }
        let data = try Data(contentsOf: plistURL, options: [.mappedIfSafe])
        let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let metadata = propertyList as? [String: Any] else { throw NativeInventoryError.invalidMetadata }
        let displayName = visibleName(metadata["CFBundleDisplayName"]) ?? visibleName(metadata["CFBundleName"]) ?? url.deletingPathExtension().lastPathComponent
        let bundleIdentifier = (metadata["CFBundleIdentifier"] as? String)?.nonEmpty
        let resolvedClassification = bundleIdentifier == nil && isSteamShortcut(bundle, executable: metadata["CFBundleExecutable"] as? String) ? .launcher : classification
        let declaredFeed = (metadata["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let authority = updateAuthority(bundle: bundle, path: url.path, bundleIdentifier: bundleIdentifier, classification: resolvedClassification, declaresFeed: declaredFeed != nil)
        // An app that sets its feed at run time leaves it in its preferences, which Sparkle reads
        // when Info.plist has none.
        let feedURL = declaredFeed ?? (authority == .sparkle ? bundleIdentifier.flatMap(savedSparkleFeed) : nil)
        var linkTargets: [String] = []
        if bundle.path != url.path { linkTargets.append(bundle.path) }
        if let executable = (metadata["CFBundleExecutable"] as? String)?.nonEmpty, !executable.contains("/") {
            let executableURL = bundle.appending(path: "Contents/MacOS").appending(path: executable)
            if (try? executableURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { linkTargets.append(executableURL.resolvingSymlinksInPath().path) }
        }
        return NativeApplication(path: url.path, bundleIdentifier: bundleIdentifier, displayName: displayName, shortVersion: (metadata["CFBundleShortVersionString"] as? String)?.nonEmpty, buildVersion: (metadata["CFBundleVersion"] as? String)?.nonEmpty, classification: resolvedClassification, discoveryRoot: root.path, updateAuthority: authority, sparkleFeedURL: authority == .sparkle ? feedURL : nil, linkTargets: linkTargets)
    }

    /// SUFeedURL from the app's own preferences, in either its regular or sandbox container
    /// location. The preferences file is read, never written.
    private func savedSparkleFeed(bundleIdentifier: String) -> String? {
        guard !bundleIdentifier.contains("/"), !bundleIdentifier.hasPrefix(".") else { return nil }
        let home = URL(filePath: homeDirectory, directoryHint: .isDirectory)
        let candidates = [
            home.appending(path: "Library/Preferences/\(bundleIdentifier).plist"),
            home.appending(path: "Library/Containers/\(bundleIdentifier)/Data/Library/Preferences/\(bundleIdentifier).plist"),
        ]
        for file in candidates {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true, (values.fileSize ?? .max) <= 4 * 1_048_576,
                  let data = try? Data(contentsOf: file),
                  let preferences = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let feed = (preferences["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else { continue }
            return feed
        }
        return nil
    }

    private func updateAuthority(bundle: URL, path: String, bundleIdentifier: String?, classification: ApplicationClassification, declaresFeed: Bool) -> NativeUpdateAuthority {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: bundle.appending(path: "Contents/_MASReceipt/receipt").path) { return .appStore }
        if declaresFeed || fileManager.fileExists(atPath: bundle.appending(path: "Contents/Frameworks/Sparkle.framework").path) { return .sparkle }
        if fileManager.fileExists(atPath: bundle.appending(path: "Contents/Resources/app-update.yml").path) { return .electron }
        if path.contains("/steamapps/common/") { return .steam }
        if path.hasPrefix("/Applications/Setapp/") { return .setapp }
        if let bundleIdentifier, BlackmagicDownloads.product(forBundleIdentifier: bundleIdentifier) != nil { return .blackmagic }
        if bundleIdentifier?.hasPrefix("com.apple.") == true, classification == .system || classification == .coreService { return .apple }
        return .unknown
    }

    /// Some bundles (several CoreServices UI agents among them) carry a name made only of
    /// invisible characters such as U+200E; those fall through to the next name source.
    private func visibleName(_ value: Any?) -> String? {
        guard let name = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let isVisible = name.unicodeScalars.contains { !$0.properties.isWhitespace && !$0.properties.isDefaultIgnorableCodePoint && $0.properties.generalCategory != .format && $0.properties.generalCategory != .control }
        return isVisible ? name : nil
    }

    /// Steam's "Create desktop shortcut" writes a bundle with no identifier whose executable is a
    /// tiny generated script running `open steam://run/<id>`. The script is read, never executed.
    private func isSteamShortcut(_ bundle: URL, executable: String?) -> Bool {
        guard let executable, !executable.contains("/") else { return false }
        let script = bundle.appending(path: "Contents/MacOS").appending(path: executable)
        guard let values = try? script.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true, (values.fileSize ?? .max) <= 4_096,
              let contents = try? String(contentsOf: script, encoding: .utf8) else { return false }
        return contents.contains("steam://run/")
    }

    /// The real bundle directory for a candidate: the candidate itself, or, for a symlinked
    /// candidate, its destination when that is a top-level application bundle.
    private func resolvedBundle(_ url: URL, isSymbolicLink: Bool) -> URL? {
        guard isSymbolicLink else { return url }
        let destination = url.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard destination.pathExtension.lowercased() == "app", FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue,
              isPlausibleNativeApplicationBundle(destination) else { return nil }
        return destination
    }

    private func spotlightPaths() throws -> [String] {
        let executable = URL(filePath: "/usr/bin/mdfind")
        let result = try runner.run(executable: executable, arguments: ["-0", "-onlyin", "/", "kMDItemContentType == \"com.apple.application-bundle\"c"], environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"], timeout: 30, outputLimit: 32 * 1_024 * 1_024)
        guard result.status == 0 else { throw NativeInventoryError.spotlightFailed }
        return result.stdout.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Classification for a bundle found outside a configured root (via Spotlight) or through a
    /// symlink. Only the standard application folders and Steam libraries hold user-installed
    /// applications; anything else is a helper, cache, or build product.
    static func classification(forPath path: String, homeDirectory: String) -> ApplicationClassification {
        let coreServicePrefixes = ["/System/Library/CoreServices/", "/Library/CoreServices/", "/Library/Apple/System/Library/CoreServices/"]
        if coreServicePrefixes.contains(where: path.hasPrefix) { return .coreService }
        if path.hasPrefix("/System/") || path.hasPrefix("/Library/Apple/") { return .system }
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") { return .user }
        if path.contains("/steamapps/common/") { return .user }
        return .auxiliary
    }

    private func fileIdentity(_ url: URL) -> FileIdentity? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.path == "/" ? "/" : root.path + "/"
        return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
    }

    public static func defaultRoots(fileManager: FileManager = .default) -> [NativeSearchRoot] {
        [
            NativeSearchRoot(url: URL(filePath: "/Applications", directoryHint: .isDirectory), classification: .user, required: true),
            NativeSearchRoot(url: fileManager.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory), classification: .user, required: false),
            NativeSearchRoot(url: URL(filePath: "/System/Applications", directoryHint: .isDirectory), classification: .system, required: true),
            NativeSearchRoot(url: URL(filePath: "/System/Library/CoreServices", directoryHint: .isDirectory), classification: .coreService, required: true),
            NativeSearchRoot(url: URL(filePath: "/Library/CoreServices", directoryHint: .isDirectory), classification: .coreService, required: false),
        ]
    }
}

private struct FileIdentity: Hashable {
    let device: Int32
    let inode: UInt64
    let path: String?

    init(device: Int32, inode: UInt64) { (self.device, self.inode, self.path) = (device, inode, nil) }
    /// Fallback identity when stat fails; distinct per path, so it never merges two bundles.
    init(path: String) { (self.device, self.inode, self.path) = (0, 0, path) }
}

public enum NativeInventoryError: LocalizedError { case metadataTooLarge, invalidMetadata, spotlightFailed
    public var errorDescription: String? { switch self { case .metadataTooLarge: "Bundle metadata exceeds the 1 MiB limit."; case .invalidMetadata: "Bundle metadata is not a property-list dictionary."; case .spotlightFailed: "mdfind returned a nonzero status." } }
}
