import Foundation
import Synchronization

public enum ChangelogOutcome: Sendable {
    case changelog(Changelog)
    /// Nothing was found; `tried` says where Sift looked and why each place gave nothing.
    case unavailable(name: String, tried: [String])
}

/// A catalog item's changelog: the cached copy while it's fresh, otherwise fetched again and
/// cached. A failed fetch falls back to the last copy that worked.
public struct ChangelogService: Sendable {
    /// How long a fetched changelog is reused before asking its source again.
    public static let maxAge: TimeInterval = 6 * 60 * 60
    /// How long "nothing found" stands before looking again.
    public static let missMaxAge: TimeInterval = 24 * 60 * 60

    private let database: Database
    private let resolver: ChangelogResolver

    public init(database: Database, resolver: ChangelogResolver) {
        self.database = database
        self.resolver = resolver
    }

    public init(database: Database, renderer: (@Sendable (URL) -> String?)? = nil) {
        self.init(database: database, resolver: ChangelogResolver(client: MetadataHTTPClient(database: database), renderer: renderer))
    }

    /// The cached changelog only; never fetches. Used by `sift show`.
    public static func cached(for item: CatalogItem, database: Database) throws -> Changelog? {
        guard let state = try database.changelogState(selector: item.selector), let source = state.source else { return nil }
        let entries = try database.changelogEntries(selector: item.selector)
        guard !entries.isEmpty else { return nil }
        let versions = try parentApplication(of: item, database: database) ?? item
        var changelog = Changelog(selector: item.selector, name: item.name, installedVersion: versions.installedVersion, availableVersion: versions.availableVersion, source: source, sourceURL: state.sourceURL, entries: entries, fetchedAt: state.fetchedAt)
        changelog.installedAt = installDate(of: versions)
        return changelog
    }

    public func changelog(for item: CatalogItem, refetch: Bool = false, now: Date = .now) throws -> ChangelogOutcome {
        let cached = try Self.cached(for: item, database: database)
        let state = try database.changelogState(selector: item.selector)
        if !refetch, let state {
            let age = now.timeIntervalSince(state.fetchedAt)
            if let cached, age >= 0, age < Self.maxAge, covers(cached, item) || age < 60 * 60 { return .changelog(cached) }
            if state.status == "unavailable", cached == nil, age >= 0, age < Self.missMaxAge { return .unavailable(name: item.name, tried: Self.tried(state.detail)) }
        }
        // A helper installed and updated with another app ("Installed and updated with DaVinci
        // Resolve.") has that app's changelog.
        let parent = try Self.parentApplication(of: item, database: database)
        let target = parent ?? item
        let homebrewSource: String? = switch target.kind {
        case .homebrewFormula, .homebrewCask:
            try target.prefix.flatMap { prefix in try database.homebrewSourceURL(prefix: prefix, kind: target.kind == .homebrewCask ? .cask : .formula, fullName: target.fullName ?? target.name) }
        default: nil
        }
        switch resolver.resolve(ChangelogSubject(item: target, homebrewSourceURL: homebrewSource)) {
        case let .resolved(resolvedSource, sourceURL, entries):
            let source = parent.map { "\(resolvedSource), for \($0.name)" } ?? resolvedSource
            try database.storeChangelog(selector: item.selector, source: source, sourceURL: sourceURL, entries: entries, fetchedAt: now)
            // The whole stored history, in version order, not just this fetch.
            let history = try database.changelogEntries(selector: item.selector)
            var changelog = Changelog(selector: item.selector, name: item.name, installedVersion: target.installedVersion, availableVersion: target.availableVersion, source: source, sourceURL: sourceURL, entries: history.isEmpty ? entries : history, fetchedAt: now)
            changelog.installedAt = Self.installDate(of: target)
            return .changelog(changelog)
        case let .unavailable(tried):
            try database.storeChangelogMiss(selector: item.selector, status: "unavailable", detail: tried.joined(separator: "\n"), fetchedAt: now)
            if var cached {
                cached.staleReason = "No source has a changelog now; showing the copy from \(cached.fetchedAt.formatted(date: .abbreviated, time: .omitted))."
                return .changelog(cached)
            }
            return .unavailable(name: item.name, tried: tried)
        case let .failure(message):
            try database.storeChangelogMiss(selector: item.selector, status: "failure", detail: message, fetchedAt: now)
            if var cached {
                cached.staleReason = "Couldn't fetch a fresh copy (\(message)); showing the one from \(cached.fetchedAt.formatted(date: .abbreviated, time: .omitted))."
                return .changelog(cached)
            }
            return .unavailable(name: item.name, tried: [message])
        }
    }

    /// Fetches the changelogs `refresh` makes instant: everything with a pending update and
    /// everything that changed in the last week, skipping copies that are still fresh. Returns how
    /// many were fetched.
    @discardableResult
    public func prefetch(now: Date = .now, progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> Int {
        let items = try database.catalogItems()
        let recent = Set(try database.updateLog(since: now.addingTimeInterval(-7 * 24 * 60 * 60)).map(\.selector))
        var due: [CatalogItem] = []
        for item in items where item.updateAvailable || recent.contains(String(item.selector.prefix { $0 != "@" })) {
            if let state = try database.changelogState(selector: item.selector), now.timeIntervalSince(state.fetchedAt) < (state.status == "unavailable" ? Self.missMaxAge : Self.maxAge) {
                guard state.status == "resolved" else { continue }
                if let cached = try Self.cached(for: item, database: database), covers(cached, item) { continue }
            }
            due.append(item)
        }
        let counter = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: due.count) { index in
            _ = try? changelog(for: due[index], refetch: true, now: now)
            let done = counter.withLock { value -> Int in value += 1; return value }
            progress?(done, due.count)
        }
        return due.count
    }

    /// When the installed copy arrived: the app bundle's Info.plist (rewritten by every install
    /// and update), or the Homebrew keg or Caskroom folder for its version.
    static func installDate(of item: CatalogItem) -> Date? {
        var candidates: [String] = []
        if let path = item.path { candidates += [path + "/Contents/Info.plist", path] }
        if let prefix = item.prefix, let version = item.installedVersion {
            let name = item.fullName ?? item.name
            candidates.append(prefix + (item.kind == .homebrewCask ? "/Caskroom/" : "/Cellar/") + name + "/" + version)
        }
        return candidates.lazy.compactMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }.first
    }

    static func parentApplication(of item: CatalogItem, database: Database) throws -> CatalogItem? {
        guard item.updateSource == NativeUpdateAuthority.bundled.rawValue, let detail = item.updateDetail,
              let match = detail.firstMatch(of: #/updated with (.+?)\./#) else { return nil }
        let name = String(match.1)
        return try database.catalogItems(includeAll: true).first { $0.kind == .nativeApp && $0.name == name && $0.selector != item.selector }
    }

    /// Whether a cached changelog already has an entry for the newest version known.
    private func covers(_ changelog: Changelog, _ item: CatalogItem) -> Bool {
        guard let newest = item.availableVersion ?? item.installedVersion else { return true }
        let normalized = ChangelogVersion.normalized(newest)
        return changelog.entries.contains { ChangelogVersion.matches($0.version, normalized) } || changelog.entries.first.flatMap { ChangelogVersion.token(in: $0.version) }.map { SparkleVersion.compare($0, normalized) != .orderedAscending } ?? true
    }

    private static func tried(_ detail: String?) -> [String] {
        detail?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
    }
}
