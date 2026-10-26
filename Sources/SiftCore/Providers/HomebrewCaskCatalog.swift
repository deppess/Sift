import Foundation

/// Homebrew's public cask catalog, used as a version source for applications that weren't
/// installed with Homebrew and whose own updater can't be read from the bundle.
///
/// A cask is tied to an application only by the bundle's exact identifier, never by name alone:
/// the cask's uninstall step quits that identifier, or the cask installs an app with the bundle's
/// file name and its uninstall/zap paths name the identifier, or it is a package-installer cask
/// whose paths name the identifier. When several casks qualify, the stable one (no `@` variant
/// such as `@beta`) is chosen; otherwise the application stays unmatched.
public struct HomebrewCaskCatalog: Codable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let token: String
        public let version: String
        /// The upstream version: Homebrew appends build metadata after a comma.
        public var upstreamVersion: String { HomebrewVersion.caskUpstreamVersion(from: version) }
    }

    private struct Cask: Codable, Sendable {
        let entry: Entry
        let appNames: Set<String>
        let installsPackage: Bool
        /// Registrable domains of the cask's homepage and download URL.
        let vendorDomains: Set<String>
        /// Identifiers its uninstall step quits or signals.
        let quits: Set<String>
        /// Identifiers its uninstall and zap paths name.
        let mentions: Set<String>
    }

    /// Only the casks are stored; the lookups are rebuilt from them when decoded, which is far
    /// cheaper than parsing the 19 MB catalog again.
    private enum CodingKeys: CodingKey { case casks }

    private let casks: [Cask]
    private let byQuitIdentifier: [String: [Int]]
    private let byAppName: [String: [Int]]
    private let byMentionedIdentifier: [String: [Int]]

    public static let url = URL(string: "https://formulae.brew.sh/api/cask.json")!

    public init(data: Data) throws {
        guard let document = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw MetadataHTTPError.invalidResponse }
        var casks: [Cask] = []
        for cask in document {
            guard let token = cask["token"] as? String, let version = cask["version"] as? String, version != "latest", !version.isEmpty else { continue }
            let artifacts = cask["artifacts"] as? [[String: Any]] ?? []
            var appNames = Set<String>()
            var quits = Set<String>()
            var mentions = Set<String>()
            var installsPackage = false
            for artifact in artifacts {
                for name in artifact["app"] as? [Any] ?? [] {
                    if let name = name as? String { appNames.insert((name as NSString).lastPathComponent.lowercased()) }
                }
                if artifact["pkg"] != nil { installsPackage = true }
                for key in ["uninstall", "zap"] {
                    guard let stanza = artifact[key] else { continue }
                    for case let directive as [String: Any] in stanza as? [Any] ?? [] where key == "uninstall" {
                        for field in ["quit", "signal"] { Self.strings(in: directive[field]).forEach { quits.insert($0.lowercased()) } }
                    }
                    for string in Self.strings(in: stanza) { mentions.formUnion(Self.identifierPrefixes(in: string)) }
                }
            }
            let vendorDomains = Set([cask["homepage"], cask["url"]].compactMap { ($0 as? String).flatMap(URL.init(string:))?.host.flatMap(Self.vendorDomain) })
            casks.append(Cask(entry: Entry(token: token, version: version), appNames: appNames, installsPackage: installsPackage, vendorDomains: vendorDomains, quits: quits, mentions: mentions))
        }
        self.init(casks: casks)
    }

    public init(from decoder: Decoder) throws {
        try self.init(casks: decoder.container(keyedBy: CodingKeys.self).decode([Cask].self, forKey: .casks))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(casks, forKey: .casks)
    }

    private init(casks: [Cask]) {
        var byQuit: [String: [Int]] = [:]
        var byApp: [String: [Int]] = [:]
        var byMention: [String: [Int]] = [:]
        for (index, cask) in casks.enumerated() {
            for identifier in cask.quits { byQuit[identifier, default: []].append(index) }
            for name in cask.appNames { byApp[name, default: []].append(index) }
            for identifier in cask.mentions { byMention[identifier, default: []].append(index) }
        }
        self.casks = casks
        byQuitIdentifier = byQuit
        byAppName = byApp
        byMentionedIdentifier = byMention
    }

    public var count: Int { casks.count }

    /// The single cask strongly tied to this bundle, or nil when there is none or the evidence is ambiguous.
    public func entry(bundleIdentifier: String?, bundleFileName: String) -> Entry? {
        guard let identifier = bundleIdentifier?.lowercased(), !identifier.isEmpty else { return nil }
        let fileName = bundleFileName.lowercased()
        let mentioning = Set(byMentionedIdentifier[identifier] ?? [])
        let tiers: [[Int]] = [
            byQuitIdentifier[identifier] ?? [],
            (byAppName[fileName] ?? []).filter(mentioning.contains),
            mentioning.filter { casks[$0].appNames.isEmpty && casks[$0].installsPackage }.sorted(),
        ]
        for tier in tiers where !tier.isEmpty {
            let unique = Array(Set(tier))
            if unique.count == 1 { return casks[unique[0]].entry }
            let stable = unique.filter { !casks[$0].entry.token.contains("@") }
            return stable.count == 1 ? casks[stable[0]].entry : nil
        }
        return nil
    }

    /// Hosts that serve many unrelated vendors, so sharing one says nothing about who made an app.
    private static let sharedHosts: Set<String> = ["github.com", "githubusercontent.com", "github.io", "amazonaws.com", "cloudfront.net", "sourceforge.net", "google.com", "apple.com", "microsoft.com", "dropbox.com", "gitlab.com", "bitbucket.org", "sparkle-project.org", "cloudflare.com", "azureedge.net", "akamaized.net", "digitaloceanspaces.com", "backblazeb2.com", "r2.dev", "workers.dev", "netlify.app", "vercel.app", "itch.io"]

    /// The weaker tier: exactly one stable cask installs an app with this file name, and the app
    /// itself references that cask's vendor domain (its homepage or download host). Two
    /// independent signals; the name alone is never enough.
    public func entry(bundleFileName: String, referencedHosts: Set<String>) -> (entry: Entry, domain: String)? {
        let domains = Set(referencedHosts.compactMap(Self.vendorDomain))
        let named = Array(Set(byAppName[bundleFileName.lowercased()] ?? [])).filter { !casks[$0].entry.token.contains("@") }
        let matches = named.compactMap { index in casks[index].vendorDomains.intersection(domains).first.map { (casks[index].entry, $0) } }
        return matches.count == 1 ? matches[0] : nil
    }

    /// "updates.tinyvendor.io" → "tinyvendor.io"; two-letter second-level labels under country codes
    /// ("example.co.uk") keep three labels. Shared hosting domains yield nil.
    static func vendorDomain(_ host: String) -> String? {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        let keep = labels.count >= 3 && labels[labels.count - 1].count == 2 && ["co", "com", "org", "net", "ac", "gov"].contains(labels[labels.count - 2]) ? 3 : 2
        let domain = labels.suffix(keep).joined(separator: ".")
        return sharedHosts.contains(domain) ? nil : domain
    }

    private static func strings(in value: Any?) -> [String] {
        switch value {
        case let string as String: [string]
        case let array as [Any]: array.flatMap { strings(in: $0) }
        case let dictionary as [String: Any]: dictionary.values.flatMap { strings(in: $0) }
        default: []
        }
    }

    private static let fileSuffixes: Set<String> = ["plist", "savedstate", "binarycookies", "help", "log", "sfl", "sfl2", "sfl3", "sfl4", "lssharedfilelist", "helper", "diagnostic"]

    /// The identifier each path component names: the component itself, or the component without a
    /// file suffix or wildcard, so "~/Library/Preferences/com.example.NetGuardAgent.plist" yields
    /// "com.example.netguardagent". A shorter dotted prefix is never an identifier of its own.
    private static func identifierPrefixes(in path: String) -> Set<String> {
        var result = Set<String>()
        for component in path.split(separator: "/") {
            var name = component.lowercased()
            while name.hasSuffix("*") || name.hasSuffix(".") { name.removeLast() }
            guard name.contains(".") else { continue }
            result.insert(name)
            if let dot = name.lastIndex(of: "."), fileSuffixes.contains(String(name[name.index(after: dot)...])) {
                result.insert(String(name[..<dot]))
            }
        }
        return result
    }
}
