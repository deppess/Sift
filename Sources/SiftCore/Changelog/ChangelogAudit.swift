import Foundation

/// Checks a changelog against what Sift knows about the item, for `sift __sweep`: whether it is
/// the right project, covers the installed and latest versions, and says what changed. Each
/// problem is a short flag; an empty list means nothing looks wrong.
public enum ChangelogAudit {
    public static func flags(_ changelog: Changelog, item: CatalogItem) -> [String] {
        var flags: [String] = []
        let entries = changelog.entries
        let versioned = entries.filter { ChangelogVersion.token(in: $0.version) == $0.version }
        let isVersioned =
            versioned.count * 2 >= entries.count
            && !ChangelogVersion.isCalendarDated(entries, installed: changelog.installedVersion.map(ChangelogVersion.normalized))
        if isVersioned {
            if let installed = changelog.installedVersion, changelog.installedEntry == nil { flags.append("missing-installed(\(installed))") }
            if let available = changelog.availableVersion, available != changelog.installedVersion {
                let target = ChangelogVersion.normalized(available)
                if ChangelogVersion.installedIndex(in: entries, installed: target) == nil,
                    !(versioned.first.flatMap { ChangelogVersion.token(in: $0.version) }.map { SparkleVersion.compare($0, target) == .orderedDescending }
                        ?? false)
                {
                    flags.append("missing-latest(\(available))")
                }
            }
            // A release newer than anything the update check reported: the checker may have
            // missed an update (or the changelog lists a pre-release or another platform's build).
            let known = changelog.availableVersion ?? changelog.installedVersion
            if let known,
                let newest = versioned.compactMap({ ChangelogVersion.token(in: $0.version) }).max(by: { SparkleVersion.compare($0, $1) == .orderedAscending }),
                newest.range(of: #"(?i)(alpha|beta|rc|pre|dev)"#, options: .regularExpression) == nil,
                // A year-numbered tag (FL Studio's "2024.2.2", an old date tag) against ordinary versions isn't comparable.
                !(Int(newest.prefix { $0.isNumber }).map { $0 >= 1990 } ?? false)
                    || (Int(ChangelogVersion.normalized(known).prefix { $0.isNumber }).map { $0 >= 1990 } ?? false),
                ChangelogVersion.sameLine([ChangelogEntry(version: newest, content: "")], installed: ChangelogVersion.normalized(known)),
                SparkleVersion.compare(newest, ChangelogVersion.normalized(known)) == .orderedDescending,
                !ChangelogVersion.looselyMatches(newest, ChangelogVersion.normalized(known))
            {
                flags.append("newer-than-update-check(\(newest))")
            }
            // Versions far from the installed one: another product's tags, or a number that
            // isn't a version (a standard, a year).
            if let installed = changelog.installedVersion.map(ChangelogVersion.normalized), let major = Int(installed.prefix { $0.isNumber }) {
                let outliers = versioned.filter { entry in
                    guard let other = Int(entry.version.prefix { $0.isNumber }) else { return false }
                    return other > max(major * 4, major + 20) && !(other >= 1990 && other <= 2100)
                }
                if !outliers.isEmpty { flags.append("outlier-versions(\(outliers.prefix(3).map(\.version).joined(separator: ",")))") }
            }
            // Releases tagged for different products in one repository (gopls/v0.17 in golang/tools).
            let prefixes = Set(
                entries.compactMap(\.sourceURL).compactMap { url -> String? in
                    guard let tag = url.components(separatedBy: "/releases/tag/").dropFirst().first?.removingPercentEncoding else { return nil }
                    let prefix = tag.prefix { !$0.isNumber }.trimmingCharacters(in: CharacterSet(charactersIn: "v-_/@"))
                    return prefix.isEmpty ? nil : prefix.lowercased()
                })
            if prefixes.count > 1 { flags.append("mixed-tags(\(prefixes.sorted().prefix(4).joined(separator: ",")))") }
        }
        let withText = entries.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !ChangelogDocument.isPlaceholder($0.content) }
        if withText.count * 2 < entries.count { flags.append("mostly-empty(\(withText.count)/\(entries.count))") }
        if entries.count < 3 { flags.append("short(\(entries.count))") }
        // A repository whose name shares nothing with the item, when the item's own metadata
        // didn't name it (a guess from a link).
        if item.kind == .nativeApp,
            let repository = changelog.sourceURL.flatMap(URL.init(string:)).flatMap({ GitHubSource.parse(ChangelogResolver.Hints.repositoryRoot($0)) })?
                .repository
        {
            let keys = [item.name, item.fullName ?? "", item.bundleIdentifier ?? ""].map(BundleURLScanner.matchKey)
            let repoKey = BundleURLScanner.matchKey(repository.name), ownerKey = BundleURLScanner.matchKey(repository.owner)
            let related = keys.contains { key in
                !key.isEmpty && (key.contains(repoKey) || repoKey.contains(key) || key.contains(ownerKey) || ownerKey.contains(key))
            }
            if !related { flags.append("repo-name-mismatch(\(repository.path))") }
        }
        return flags
    }
}
