import Foundation

// Where an item's changelog may be: its package metadata, bundle, and Sift's own rules.
extension ChangelogResolver {
    // MARK: - Hints

    func gatherHints(_ subject: ChangelogSubject, into hints: inout Hints) {
        let item = subject.item
        for source in Self.knownSources(for: item) { hints.add(source) }
        switch item.kind {
        case .homebrewFormula, .homebrewCask:
            let isCask = item.kind == .homebrewCask
            if let prefix = item.prefix, let version = item.installedVersion, !isCask {
                let keg = URL(filePath: prefix).appending(path: "Cellar").appending(path: item.name).appending(path: version)
                for file in Self.changelogFiles(in: keg) + Self.changelogFiles(in: keg.appending(path: "share/doc").appending(path: item.name)) {
                    hints.add(.localFiles([file]))
                }
            }
            if let source = subject.homebrewSourceURL.flatMap(URL.init(string:)), let github = GitHubSource.parse(source) { hints.add(github.repository) }
            homebrewAPIHints(token: item.name, cask: isCask, into: &hints)
        case .package:
            packageHints(item, into: &hints)
        case .nativeApp:
            applicationHints(item, into: &hints)
        }
    }

    /// Where a few projects keep a changelog no metadata points to, like Homebrew's livecheck
    /// blocks do for versions.
    static func knownSources(for item: CatalogItem) -> [Source] {
        let version = item.installedVersion.map(ChangelogVersion.normalized) ?? ""
        let minor = version.split(separator: ".").prefix(2).joined(separator: ".")
        switch (item.kind, item.bundleIdentifier ?? item.name) {
        case (.homebrewFormula, "go"):
            return [.releaseNotes(URL(string: "https://go.dev/doc/devel/release")!)]
        case (.nativeApp, let id) where id.hasPrefix("org.python.") && minor.split(separator: ".").count == 2:
            return [.releaseNotes(URL(string: "https://docs.python.org/\(minor)/whatsnew/changelog.html")!)]
        case (.homebrewFormula, let name) where name.hasPrefix("python@"):
            return [.releaseNotes(URL(string: "https://docs.python.org/\(name.dropFirst(7))/whatsnew/changelog.html")!)]
        case (.nativeApp, "com.valvesoftware.steam"), (.homebrewCask, "steam"):
            return [.steam(appID: "593110")]
        case (.homebrewCask, "claude-code"), (.homebrewFormula, "claude-code"):
            return [.githubFile(GitHubRepository(owner: "anthropics", name: "claude-code"))]
        case (.homebrewCask, "google-chrome"), (.nativeApp, "com.google.Chrome"):
            return [
                .filteredFeed(
                    URL(string: "https://chromereleases.googleblog.com/feeds/posts/default/-/Stable%20updates?redirect=false&max-results=25")!,
                    title: "Stable Channel Update for Desktop")
            ]
        case (.homebrewCask, "flutter"), (.homebrewFormula, "flutter"):
            return [.releaseNotes(URL(string: "https://docs.flutter.dev/release/release-notes")!)]
        case (.homebrewFormula, "zsh"):
            return [.githubFile(GitHubRepository(owner: "zsh-users", name: "zsh"))]
        case (.homebrewFormula, "glib"):
            return [.forge(host: "gitlab.gnome.org", path: "GNOME/glib")]
        case (.homebrewFormula, "docker"):
            return version.split(separator: ".").first.map { [.releaseNotes(URL(string: "https://docs.docker.com/engine/release-notes/\($0)/")!)] } ?? []
        case (.homebrewFormula, "ansible"):
            return version.split(separator: ".").first.map {
                [.releaseNotes(URL(string: "https://raw.githubusercontent.com/ansible-community/ansible-build-data/main/\($0)/CHANGELOG-v\($0).md")!)]
            } ?? []
        case (.homebrewCask, "signal"), (.nativeApp, "org.whispersystems.signal-desktop"):
            return [.githubReleases(GitHubRepository(owner: "signalapp", name: "Signal-Desktop"))]
        case (.homebrewCask, "emacs-app"), (.homebrewCask, "emacs"), (.nativeApp, "org.gnu.Emacs"):
            // This major's NEWS, then the previous major's (NEWS.30 beside it).
            guard let major = version.split(separator: ".").first.flatMap({ Int($0) }) else { return [] }
            return ["NEWS", "NEWS.\(major - 1)"].map {
                .releaseNotes(URL(string: "https://raw.githubusercontent.com/emacs-mirror/emacs/emacs-\(major)/etc/\($0)")!)
            }
        case (.homebrewCask, "mongodb-compass"), (.nativeApp, "com.mongodb.compass"):
            return [.githubReleases(GitHubRepository(owner: "mongodb-js", name: "compass"))]
        case (.homebrewCask, let name) where name.hasPrefix("temurin"):
            // temurin@21, or the latest (unsuffixed) by its installed major version.
            let major = name.split(separator: "@").dropFirst().first.map(String.init) ?? version.split(separator: ".").first.map(String.init)
            return major.flatMap(Int.init).map { [.adoptium(major: $0)] } ?? []
        default:
            break
        }
        if [.homebrewCask, .nativeApp].contains(item.kind),
            let page = releaseNotesPages.first(where: { $0.names.contains(item.bundleIdentifier ?? item.name) })?.url
        {
            return [.releaseNotes(URL(string: page)!)]
        }
        // JetBrains' IDEs: the releases API carries each version's "what's new".
        if let code = jetBrainsProductCodes[item.bundleIdentifier ?? item.name],
            let url = URL(string: "https://data.services.jetbrains.com/products/releases?code=\(code)&type=release")
        {
            return [.updateFeed(url)]
        }
        // Release notes at an address built from the version, for the installed and latest versions.
        let versions = [item.availableVersion, item.installedVersion].compactMap { $0.map(ChangelogVersion.normalized) }.reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        // The latest and installed versions' pages, then (with `earlier`, which steps back one
        // release) the few before the installed one, for a history.
        func pages(earlier: (([Int]) -> [Int]?)? = nil, _ template: (String, [String]) -> String?) -> [Source] {
            var all = versions
            if let earlier, var parts = versions.last.map({ $0.split(separator: ".").compactMap { Int($0) } }) {
                for _ in 0..<5 {
                    guard let previous = earlier(parts) else { break }
                    parts = previous
                    let version = previous.map(String.init).joined(separator: ".")
                    if !all.contains(version) { all.append(version) }
                }
            }
            let urls = all.compactMap { version -> VersionedURL? in
                let parts = version.split(separator: ".").map(String.init)
                return template(version, parts).flatMap(URL.init(string:)).map { VersionedURL(url: $0, version: version) }
            }
            return urls.isEmpty ? [] : [.versionPages(urls)]
        }
        switch (item.kind, item.bundleIdentifier ?? item.name) {
        case (.homebrewCask, "firefox"), (.nativeApp, "org.mozilla.firefox"):
            return pages(earlier: { $0.count >= 2 && $0[0] > 1 ? [$0[0] - 1, 0] : nil }) { version, _ in
                "https://www.mozilla.org/en-US/firefox/\(version)/releasenotes/"
            }
        case (.homebrewCask, "visual-studio-code"), (.nativeApp, "com.microsoft.VSCode"):
            return pages(earlier: { $0.count >= 2 && $0[1] > 0 ? [$0[0], $0[1] - 1] : nil }) { _, parts in
                parts.count >= 2 ? "https://code.visualstudio.com/updates/v\(parts[0])_\(parts[1])" : nil
            }
        case (.homebrewCask, "blender"), (.nativeApp, "org.blenderfoundation.blender"):
            return pages(earlier: { $0.count >= 2 && $0[1] > 0 ? [$0[0], $0[1] - 1] : nil }) { _, parts in
                parts.count >= 2 ? "https://www.blender.org/download/releases/\(parts[0])-\(parts[1])/" : nil
            }
        case (.homebrewFormula, let name) where name.hasPrefix("postgresql") || name == "libpq":
            return pages(earlier: { $0.count >= 2 && $0[1] > 0 ? [$0[0], $0[1] - 1] : nil }) { version, _ in
                "https://www.postgresql.org/docs/release/\(version)/"
            }
        case (.homebrewFormula, "git"):
            return pages(earlier: { $0.count >= 2 && $0[1] > 0 ? [$0[0], $0[1] - 1, 0] : nil }) { version, _ in
                "https://raw.githubusercontent.com/git/git/master/Documentation/RelNotes/\(version).adoc"
            }
        case (.homebrewFormula, "gcc"):
            return pages(earlier: { $0.first.map { $0 > 10 ? [$0 - 1] : nil } ?? nil }) { _, parts in "https://gcc.gnu.org/gcc-\(parts[0])/changes.html" }
        case (.homebrewFormula, "qemu"):
            return pages(earlier: { $0.count >= 2 ? ($0[1] > 0 ? [$0[0], $0[1] - 1] : [$0[0] - 1, 2]) : nil }) { _, parts in
                parts.count >= 2 ? "https://wiki.qemu.org/ChangeLog/\(parts[0]).\(parts[1])" : nil
            }
        case (.homebrewCask, "libreoffice"), (.nativeApp, "org.libreoffice.script"):
            return pages { _, parts in parts.count >= 2 ? "https://wiki.documentfoundation.org/ReleaseNotes/\(parts[0]).\(parts[1])" : nil }
        case (.homebrewCask, let name) where name.hasPrefix("dotnet-sdk"):
            return versions.prefix(1).compactMap { version in
                let parts = version.split(separator: ".")
                return parts.count >= 2
                    ? URL(string: "https://raw.githubusercontent.com/dotnet/core/main/release-notes/\(parts[0]).\(parts[1])/releases.json").map {
                        .updateFeed($0)
                    } : nil
            }
        default:
            return []
        }
    }

    /// Release-notes pages no package metadata points to, by cask name or bundle identifier; Office
    /// for Mac's apps share one page, dated per update.
    private static let releaseNotesPages: [(names: [String], url: String)] = [
        (
            ["com.image-line.flstudio", "com.image-line.fl-cloud-plugins"],
            "https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/WhatsNew.htm"
        ),
        (["android-studio", "com.google.android.studio"], "https://developer.android.com/studio/releases"),
        (["gcloud-cli", "google-cloud-sdk"], "https://cloud.google.com/sdk/docs/release-notes"),
        (["zoom", "us.zoom.xos"], "https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0061222"),
        (["unity-hub", "com.unity3d.unityhub"], "https://unity.com/unity-hub/release-notes"),
        (["postman", "com.postmanlabs.mac"], "https://www.postman.com/release-notes/postman-app/"),
        (["warp", "dev.warp.Warp-Stable"], "https://docs.warp.dev/changelog"),
        (["google-drive", "com.google.drivefs"], "https://support.google.com/a/answer/7577057?hl=en"),
        (["chatgpt", "com.openai.chat"], "https://help.openai.com/en/articles/9703738-chatgpt-macos-app-release-notes"),
        (["1password", "com.1password.1password"], "https://releases.1password.com/mac/stable/"),
        (["claude", "com.anthropic.claudefordesktop"], "https://support.claude.com/en/articles/12138966-claude-desktop-release-notes"),
        (["microsoft-edge", "com.microsoft.edgemac"], "https://learn.microsoft.com/en-us/deployedge/microsoft-edge-relnote-stable-channel"),
        (["windows-app", "com.microsoft.rdc.macos"], "https://learn.microsoft.com/en-us/windows-app/whats-new?tabs=macos"),
        (["miniconda"], "https://www.anaconda.com/docs/getting-started/miniconda/release-notes"),
        (
            [
                "microsoft-word", "microsoft-excel", "microsoft-powerpoint", "microsoft-outlook", "microsoft-onenote", "microsoft-office",
                "microsoft-office-businesspro", "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint", "com.microsoft.Outlook",
                "com.microsoft.onenote.mac"
            ], "https://learn.microsoft.com/en-us/officeupdates/release-notes-office-for-mac"
        )
    ]

    static let jetBrainsProductCodes: [String: String] = [
        "intellij-idea": "IIU", "com.jetbrains.intellij": "IIU", "intellij-idea-ce": "IIC", "com.jetbrains.intellij.ce": "IIC",
        "pycharm": "PCP", "com.jetbrains.pycharm": "PCP", "pycharm-ce": "PCC", "com.jetbrains.pycharm.ce": "PCC",
        "webstorm": "WS", "com.jetbrains.WebStorm": "WS", "goland": "GO", "com.jetbrains.goland": "GO",
        "clion": "CL", "com.jetbrains.CLion": "CL", "phpstorm": "PS", "com.jetbrains.PhpStorm": "PS",
        "rider": "RD", "com.jetbrains.rider": "RD", "rubymine": "RM", "com.jetbrains.rubymine": "RM",
        "datagrip": "DG", "com.jetbrains.datagrip": "DG", "rustrover": "RR", "com.jetbrains.rustrover": "RR",
        "dataspell": "DS", "com.jetbrains.dataspell": "DS", "jetbrains-toolbox": "TBA", "com.jetbrains.toolbox": "TBA"
    ]

    /// Homebrew's API: a formula's homepage and source, or a cask's homepage and download URL.
    private func homebrewAPIHints(token: String, cask: Bool, into hints: inout Hints) {
        guard let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))),
            let url = URL(string: "https://formulae.brew.sh/api/\(cask ? "cask" : "formula")/\(encoded).json"),
            let data = try? client.fetch(url, resource: .packageRegistry).body,
            let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let urls = document["urls"] as? [String: Any]
        let stable = (urls?["stable"] as? [String: Any])?["url"] as? String
        livecheckHints(document: document, cask: cask, stableURL: stable, into: &hints)
        let head = (urls?["head"] as? [String: Any])?["url"] as? String
        for link in [stable, head, document["url"] as? String] {
            guard let link, let url = URL(string: link) else { continue }
            if let github = GitHubSource.parse(url) {
                hints.add(github.repository)
            } else if let forge = Hints.forgeRepository(url) {
                hints.add(.forge(host: forge.host, path: forge.path))
            } else {
                registryHints(forDownload: url, into: &hints)
            }
        }
        hints.add(link: document["homepage"] as? String)
    }

    /// The update endpoint in the cask's or formula's `livecheck` block, read from its Ruby source
    /// on GitHub (raw files cost no API quota): a Sparkle feed, a JSON endpoint, or a repository.
    private func livecheckHints(document: [String: Any], cask: Bool, stableURL: String?, into hints: inout Hints) {
        guard let path = document["ruby_source_path"] as? String, !path.contains(".."),
            let url = URL(string: "https://raw.githubusercontent.com/Homebrew/\(cask ? "homebrew-cask" : "homebrew-core")/HEAD/\(path)"),
            let source = try? fetchText(url, resource: .githubChangelog)
        else { return }
        let version = cask ? document["version"] as? String : (document["versions"] as? [String: Any])?["stable"] as? String
        guard
            let livecheck = HomebrewLivecheck(
                source: source, version: version, downloadURL: cask ? document["url"] as? String : stableURL, homepage: document["homepage"] as? String)
        else { return }
        if client.debug { MetadataHTTPClient.trace("livecheck: \(livecheck.strategy) \(livecheck.url.absoluteString)") }
        switch livecheck.strategy {
        case .sparkle: hints.add(.sparkle(livecheck.url, padding: true))
        case .json: hints.add(.updateFeed(livecheck.url))
        case .github: if let github = GitHubSource.parse(Hints.repositoryRoot(livecheck.url)) { hints.add(github.repository) }
        case .page: if Self.looksLikeChangelogURL(livecheck.url) { hints.add(link: livecheck.url.absoluteString) }
        case .other: break
        }
    }

    /// A download from PyPI, npm, or crates.io names the package there, whose metadata names
    /// its repository: Homebrew's rich-cli downloads from PyPI, fish-lsp from npm.
    private func registryHints(forDownload url: URL, into hints: inout Hints) {
        let host = url.host?.lowercased() ?? ""
        let parts = url.path.split(separator: "/").map(String.init)
        if host == "files.pythonhosted.org" || host == "pypi.io" || host == "pypi.org", let file = parts.last,
            let match = file.firstMatch(of: #/^(.+?)-\d[^-]*\.(tar\.gz|zip|whl|tar\.bz2)$/#)
        {
            pypiHints(String(match.1), into: &hints)
        } else if host == "registry.npmjs.org", let dash = parts.firstIndex(of: "-"), dash > 0 {
            npmHints(parts[..<dash].joined(separator: "/"), into: &hints)
        } else if host == "static.crates.io" || host == "crates.io", let index = parts.firstIndex(of: "crates"), index + 1 < parts.count {
            cratesHints(parts[index + 1], into: &hints)
        }
    }

    private func pypiHints(_ name: String, into hints: inout Hints) {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "https://pypi.org/pypi/\(encoded)/json"),
            let data = try? client.fetch(url, resource: .packageRegistry).body, let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let info = document["info"] as? [String: Any]
        else { return }
        let links = ((info["project_urls"] as? [String: String]) ?? [:]).map { ($0.key, $0.value) } + [("Homepage", (info["home_page"] as? String) ?? "")]
        for (_, link) in Self.rankedProjectURLs(links) { hints.add(link: link) }
    }

    private func npmHints(_ name: String, into hints: inout Hints) {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let url = URL(string: "https://registry.npmjs.org/\(encoded)/latest"),
            let data = try? client.fetch(url, resource: .packageRegistry).body, let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        hints.add(link: (manifest["repository"] as? String) ?? ((manifest["repository"] as? [String: Any])?["url"] as? String))
        hints.add(link: manifest["homepage"] as? String)
    }

    private func cratesHints(_ name: String, into hints: inout Hints) {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let url = URL(string: "https://crates.io/api/v1/crates/\(encoded)"),
            let data = try? client.fetch(url, resource: .packageRegistry).body, let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let crate = document["crate"] as? [String: Any]
        else { return }
        hints.add(link: crate["repository"] as? String)
        hints.add(link: crate["homepage"] as? String)
    }

    private func packageHints(_ item: CatalogItem, into hints: inout Hints) {
        let scope = URL(filePath: item.prefix ?? "/nonexistent")
        switch item.updateSource {
        case RefreshProvider.npmGlobal.rawValue:
            let package = scope.appending(path: "lib/node_modules").appending(path: item.name)
            for file in Self.changelogFiles(in: package) { hints.add(.localFiles([file])) }
            if let data = try? Data(contentsOf: package.appending(path: "package.json")),
                let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                hints.add(link: (manifest["repository"] as? String) ?? ((manifest["repository"] as? [String: Any])?["url"] as? String))
                hints.add(link: manifest["homepage"] as? String)
            } else {
                npmHints(item.name, into: &hints)
            }
        case RefreshProvider.uvTools.rawValue:
            let links = Self.pythonProjectURLs(toolDirectory: scope.appending(path: item.name), name: item.name)
            for (_, link) in Self.rankedProjectURLs(links) { hints.add(link: link) }
            if links.isEmpty { pypiHints(item.name, into: &hints) }
        case RefreshProvider.cargo.rawValue:
            if let version = item.installedVersion,
                let sources = try? FileManager.default.contentsOfDirectory(atPath: scope.appending(path: "registry/src").path)
            {
                for registry in sources.sorted() {
                    let crate = scope.appending(path: "registry/src").appending(path: registry).appending(path: "\(item.name)-\(version)")
                    for file in Self.changelogFiles(in: crate) { hints.add(.localFiles([file])) }
                    if let manifest = try? String(contentsOf: crate.appending(path: "Cargo.toml"), encoding: .utf8) {
                        for key in ["repository", "homepage"] {
                            if let match = manifest.firstMatch(of: try! Regex("(?m)^\\s*\(key)\\s*=\\s*\"([^\"]+)\"")) {
                                hints.add(link: String(match.output[1].substring ?? ""))
                            }
                        }
                    }
                }
            }
            cratesHints(item.name, into: &hints)
        case RefreshProvider.steamGames.rawValue:
            // A cache from 1.0 has no app ID yet; Steam's own manifests have it.
            if let appID = item.identifier ?? steamAppID(named: item.name) { hints.add(.steam(appID: appID)) }
        case RefreshProvider.macPorts.rawValue:
            // Ports have no metadata Sift reads: a Python port is its PyPI project, and anything
            // else is usually the Homebrew formula of the same name.
            if let match = item.name.firstMatch(of: #/^py\d+-(.+)$/#) {
                pypiHints(String(match.1), into: &hints)
            } else {
                homebrewAPIHints(token: item.name.lowercased(), cask: false, into: &hints)
            }
        default:
            break
        }
    }

    /// Project-URL and Home-page lines from an installed Python package's metadata.
    static func pythonProjectURLs(toolDirectory: URL, name: String) -> [(String, String)] {
        let key = name.lowercased().replacingOccurrences(of: "-", with: "_")
        let lib = toolDirectory.appending(path: "lib")
        guard let pythons = try? FileManager.default.contentsOfDirectory(atPath: lib.path) else { return [] }
        for python in pythons where python.hasPrefix("python") {
            let site = lib.appending(path: python).appending(path: "site-packages")
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: site.path),
                let info = names.first(where: { $0.hasSuffix(".dist-info") && $0.lowercased().replacingOccurrences(of: "-", with: "_").hasPrefix(key + "-") }),
                let metadata = try? String(contentsOf: site.appending(path: info).appending(path: "METADATA"), encoding: .utf8)
            else { continue }
            var links: [(String, String)] = []
            for line in metadata.components(separatedBy: "\n") {
                if line.hasPrefix("Project-URL:") {
                    let value = line.dropFirst(12).split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if value.count == 2 { links.append((value[0], value[1])) }
                } else if line.hasPrefix("Home-page:") {
                    links.append(("Homepage", line.dropFirst(10).trimmingCharacters(in: .whitespaces)))
                } else if line.isEmpty {
                    break
                }
            }
            return links
        }
        return []
    }

    /// Changelog links first, then the source repository, then the homepage.
    static func rankedProjectURLs(_ links: [(String, String)]) -> [(String, String)] {
        func rank(_ label: String) -> Int {
            let lower = label.lowercased().filter(\.isLetter)
            if ["changelog", "changes", "releasenotes", "release", "releases", "history", "news", "whatsnew"].contains(where: lower.contains) { return 0 }
            if ["source", "repository", "code", "github"].contains(where: lower.contains) { return 1 }
            if ["homepage", "home"].contains(where: lower.contains) { return 2 }
            if lower.contains("documentation") || lower.contains("docs") { return 3 }
            return 4
        }
        return links.filter { !$0.1.isEmpty }.sorted { rank($0.0) < rank($1.0) }.filter { rank($0.0) < 4 }
    }

    private func applicationHints(_ item: CatalogItem, into hints: inout Hints) {
        guard let path = item.path else { return }
        let application = NativeApplicationProvider(homeDirectory: homeDirectory).application(atPath: path)
        let bundleIdentifier = item.bundleIdentifier ?? application?.bundleIdentifier
        // Read once: scanning a bundle's executables for addresses is the slow part.
        let urls = application.map(BundleURLScanner.urls(in:)) ?? []
        switch item.updateSource {
        case NativeUpdateAuthority.appStore.rawValue:
            if let bundleIdentifier { hints.add(.appStore(bundleIdentifier: bundleIdentifier)) }
        case NativeUpdateAuthority.blackmagic.rawValue:
            if let bundleIdentifier, let product = BlackmagicDownloads.product(forBundleIdentifier: bundleIdentifier) {
                hints.add(.blackmagic(product: product))
            }
        default:
            break
        }
        if let application {
            if let feed = application.sparkleFeedURL.flatMap(URL.init(string:)), isPublicHTTPSURL(feed) {
                hints.add(.sparkle(feed, padding: !SparkleAppcastParser.bundlesSparkle1(application.bundlePath)))
            }
            if case let .github(repository)? = ElectronUpdateManifest(bundlePath: application.bundlePath)?.source { hints.add(repository) }
        }
        if path.contains("/steamapps/common/"), let appID = steamAppID(forPath: path) { hints.add(.steam(appID: appID)) }
        if let application {
            let bundled =
                Self.bundleChangelogFiles(application.bundlePath)
                + Self.appDataChangelogFiles(name: item.name, bundleIdentifier: bundleIdentifier, home: homeDirectory)
            if !bundled.isEmpty { hints.add(.localFiles(bundled)) }
            if let repository = BundleURLScanner.releaseRepository(in: urls, for: application) { hints.add(repository) }
            // A changelog page the app links to itself, on its own vendor's site (the domain its
            // bundle identifier names); links to other sites in a binary are often dependencies'.
            let vendor = bundleIdentifier.flatMap(Self.vendorDomain(bundleIdentifier:))
            for url in urls
            where isPublicHTTPSURL(url) && Self.looksLikeChangelogURL(url) && !url.path.hasSuffix(".xml") && !url.path.hasSuffix(".json")
                && !url.path.hasSuffix(".yml")
            {
                guard let host = url.host?.lowercased(), host != "github.com", let domain = HomebrewCaskCatalog.vendorDomain(host) else { continue }
                // The vendor's domain, or one named after the app (dynamiclake.com for DynamicLake Pro).
                let label = BundleURLScanner.matchKey(String(domain.split(separator: ".").first ?? ""))
                let appKey = BundleURLScanner.matchKey(item.name)
                guard domain == vendor || label.count >= 4 && appKey.hasPrefix(label) else { continue }
                hints.add(link: url.absoluteString)
            }
        }
        // Homebrew's cask for the same bundle: its homepage, and the GitHub project it downloads from.
        if let catalog = try? client.fetch(HomebrewCaskCatalog.url, resource: .homebrewCaskCatalog, derivedAs: "index-v2", HomebrewCaskCatalog.init(data:)) {
            let fileName = (path as NSString).lastPathComponent
            // By exact bundle identifier, or else (as the update check does) a cask with the
            // app's file name whose vendor domain the app references.
            let hosts = Set(urls.compactMap { $0.host?.lowercased() })
            if let entry = catalog.entry(bundleIdentifier: bundleIdentifier, bundleFileName: fileName)
                ?? catalog.entry(bundleFileName: fileName, referencedHosts: hosts)?.entry
            {
                homebrewAPIHints(token: entry.token, cask: true, into: &hints)
            }
        }
    }

    /// Changelog files an app keeps in its own data folders (VirtualDJ saves the one it downloads
    /// to Cache/changelog.txt), two levels deep.
    static func appDataChangelogFiles(name: String, bundleIdentifier: String?, home: String) -> [URL] {
        let homeURL = URL(filePath: home, directoryHint: .isDirectory)
        let names = [name, bundleIdentifier].compactMap { $0 }.filter { !$0.isEmpty && !$0.contains("/") && !$0.hasPrefix(".") }
        var folders: [URL] = []
        for folder in names {
            folders += [
                homeURL.appending(path: "Library/Application Support/\(folder)"), homeURL.appending(path: "Library/Caches/\(folder)"),
                homeURL.appending(path: "Documents/\(folder)")
            ]
        }
        var found: [URL] = []
        for folder in folders {
            found += changelogFiles(in: folder)
            for sub in ["Cache", "cache", "Resources", "Docs"] { found += changelogFiles(in: folder.appending(path: sub)) }
        }
        return found
    }

    /// "com.bjango.istatmenus" names bjango.com.
    static func vendorDomain(bundleIdentifier: String) -> String? {
        let parts = bundleIdentifier.lowercased().split(separator: ".")
        guard parts.count >= 2,
            ["com", "net", "org", "io", "app", "co", "de", "at", "ch", "fr", "uk", "dev", "ai", "me", "pl", "nl", "se"].contains(String(parts[0]))
        else { return nil }
        return "\(parts[1]).\(parts[0])"
    }

    private func steamAppID(named name: String) -> String? {
        let inventory = SteamProvider(
            steamDirectory: URL(filePath: homeDirectory).appending(path: "Library/Application Support/Steam", directoryHint: .isDirectory)
        ).discover()
        return inventory.libraries.flatMap(\.games).first { $0.name == name }?.appID
    }

    private func steamAppID(forPath path: String) -> String? {
        let inventory = SteamProvider(
            steamDirectory: URL(filePath: homeDirectory).appending(path: "Library/Application Support/Steam", directoryHint: .isDirectory)
        ).discover()
        return inventory.libraries.flatMap(\.games).first { path.hasPrefix($0.installDirectory + "/") }?.appID
    }
}
