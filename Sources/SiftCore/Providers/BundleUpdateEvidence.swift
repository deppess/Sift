import Foundation

/// HTTPS URLs an application embeds in its Info.plist and executables, read as bytes (nothing is
/// run). Used only for apps no stronger source covers, to find the update check the app makes
/// itself and the vendor domain it belongs to.
enum BundleURLScanner {
    private static let maximumExecutableSize = 192 * 1_048_576
    private static let maximumURLs = 4_000

    static func urls(in application: NativeApplication) -> [URL] {
        let bundle = URL(filePath: application.bundlePath, directoryHint: .isDirectory)
        var files = [bundle.appending(path: "Contents/Info.plist")]
        let macOS = bundle.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        files += ((try? FileManager.default.contentsOfDirectory(at: macOS, includingPropertiesForKeys: nil)) ?? []).map { $0.resolvingSymlinksInPath() }
        var seen = Set<String>()
        var urls: [URL] = []
        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
                (values.fileSize ?? .max) <= maximumExecutableSize,
                let data = try? Data(contentsOf: file, options: .mappedIfSafe)
            else { continue }
            for text in strings(in: data, prefix: Array("https://".utf8)) where seen.insert(text).inserted {
                if let url = URL(string: text), url.host != nil { urls.append(url) }
                if urls.count >= maximumURLs { return urls }
            }
        }
        return urls
    }

    private static let urlBytes: [Bool] = {
        var table = [Bool](repeating: false, count: 256)
        for byte in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%".utf8 { table[Int(byte)] = true }
        return table
    }()

    /// Every run of URL characters starting with `prefix`, found with Foundation's optimized search.
    private static func strings(in data: Data, prefix: [UInt8]) -> [String] {
        let needle = Data(prefix)
        var results: [String] = []
        var searchStart = data.startIndex
        while let match = data.range(of: needle, in: searchStart..<data.endIndex) {
            var end = match.upperBound
            while end < data.endIndex, end - match.lowerBound < 512, urlBytes[Int(data[end])] { end += 1 }
            if end - match.lowerBound > prefix.count + 3 { results.append(String(decoding: data[match.lowerBound..<end], as: UTF8.self)) }
            searchStart = end
        }
        return results
    }

    /// The repository whose releases the app itself queries (`api.github.com/repos/O/R/releases`
    /// or `github.com/O/R/releases`), when its owner or name also appears in the bundle identifier
    /// or app name. A plain repository or credits link is not a release check.
    static func releaseRepository(in urls: [URL], for application: NativeApplication) -> GitHubRepository? {
        let identity = Set(
            ((application.bundleIdentifier ?? "").split(separator: ".").map(String.init) + [
                application.displayName, (application.path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            ]).map(matchKey)
        ).subtracting([""])
        var repositories = Set<String>()
        for url in urls {
            guard let host = url.host?.lowercased() else { continue }
            let parts = url.path.split(separator: "/").map(String.init)
            let candidate: (String, String)?
            if host == "api.github.com", parts.count >= 4, parts[0] == "repos", parts[3] == "releases" {
                candidate = (parts[1], parts[2])
            } else if host == "github.com", parts.count >= 3, parts[2] == "releases" {
                candidate = (parts[0], parts[1])
            } else {
                candidate = nil
            }
            guard let (owner, name) = candidate, identity.contains(matchKey(owner)) || identity.contains(matchKey(name)) else { continue }
            repositories.insert("\(owner)/\(name)")
        }
        // Case differences ("Brightside" vs "brightside") are the same repository.
        let unique = Dictionary(grouping: repositories, by: { $0.lowercased() })
        guard unique.count == 1, let path = unique.values.first?.sorted().first else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        return GitHubRepository(owner: parts[0], name: parts[1])
    }

    static func matchKey(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// electron-builder's `Contents/Resources/app-update.yml`, a flat YAML map such as
/// `provider: github` / `owner: example` / `repo: app`, or `provider: generic` / `url: https://…`.
struct ElectronUpdateManifest {
    enum Source: Equatable {
        case github(GitHubRepository)
        case generic(URL)
        case unsupported(String)
    }

    let source: Source

    init?(bundlePath: String) {
        let file = URL(filePath: bundlePath).appending(path: "Contents/Resources/app-update.yml")
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
            (values.fileSize ?? .max) <= 65_536,
            let text = try? String(contentsOf: file, encoding: .utf8)
        else { return nil }
        self.init(yaml: text)
    }

    init?(yaml: String) {
        let fields = Self.flatMap(yaml)
        switch fields["provider"]?.lowercased() {
        case "github"?:
            guard let owner = fields["owner"]?.nonEmpty, let repo = fields["repo"]?.nonEmpty else { return nil }
            source = .github(GitHubRepository(owner: owner, name: repo))
        case "generic"?:
            guard let text = fields["url"], let url = URL(string: text) else { return nil }
            source = .generic(url)
        case let provider?:
            source = .unsupported(provider)
        case nil:
            return nil
        }
    }

    /// `version:` from a `latest-mac.yml` update feed.
    static func version(inLatestYAML data: Data) -> String? {
        flatMap(String(decoding: data, as: UTF8.self))["version"]?.nonEmpty
    }

    /// Top-level `key: value` pairs; nested and list entries are ignored.
    private static func flatMap(_ yaml: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in yaml.split(separator: "\n") where !line.hasPrefix(" ") && !line.hasPrefix("-") && !line.hasPrefix("#") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "'" || first == "\"" { value = String(value.dropFirst().dropLast()) }
            if fields[key] == nil { fields[key] = value }
        }
        return fields
    }
}
