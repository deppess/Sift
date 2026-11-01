import Foundation
import SiftCore
import Synchronization

/// `sift __benchmark <casks|formulae> [count]`: changelog accuracy for Homebrew's most-installed
/// casks or formulae, installed or not, each treated as installed at its current version. A TSV
/// report goes to standard output and a summary to standard error. Nothing is stored except the
/// HTTP cache.
enum Benchmark {
    static func run(kind: String, count: Int, only: [String] = [], databaseURL: URL) throws -> Int32 {
        let database = try Database.writer(url: databaseURL)
        let client = MetadataHTTPClient(database: database)
        let resolver = ChangelogResolver(client: client, renderer: renderPage)
        let cask = kind.hasPrefix("cask")
        let analytics = URL(
            string: cask ? "https://formulae.brew.sh/api/analytics/cask-install/30d.json" : "https://formulae.brew.sh/api/analytics/install-on-request/30d.json"
        )!
        guard let document = try JSONSerialization.jsonObject(with: client.fetch(analytics, resource: .packageRegistry).body) as? [String: Any],
            let items = document["items"] as? [[String: Any]]
        else { return EXIT_FAILURE }
        // Formula analytics count options separately ("node --HEAD"); one row per formula. Casks
        // from third-party taps ("microsoft/git/microsoft-git") aren't in Homebrew's API.
        var seen = Set<String>()
        let ranked = items.compactMap { ($0[cask ? "cask" : "formula"] as? String)?.split(separator: " ").first.map(String.init) }.filter {
            !$0.contains("/") && seen.insert($0).inserted
        }
        let tokens = only.isEmpty ? Array(ranked.prefix(count)) : only
        let results = Mutex([(Int, String)]())
        let tokenList = Array(tokens)
        DispatchQueue.concurrentPerform(iterations: tokenList.count) { index in
            let token = tokenList[index]
            var version: String?
            if let url = URL(string: "https://formulae.brew.sh/api/\(cask ? "cask" : "formula")/\(token).json"),
                let data = try? client.fetch(url, resource: .packageRegistry).body,
                let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                version = cask ? info["version"] as? String : ((info["versions"] as? [String: Any])?["stable"] as? String)
            }
            let item = CatalogItem(
                selector: "\(cask ? "cask" : "formula"):\(token)", aliases: [token], kind: cask ? .homebrewCask : .homebrewFormula, name: token,
                fullName: token, installedVersion: version, availableVersion: nil, active: true, bundleIdentifier: nil, path: nil, prefix: nil, tap: nil,
                ownership: nil, autoUpdates: false, observedAt: .now, updateSource: "homebrew")
            let line: String
            switch resolver.resolve(ChangelogSubject(item: item)) {
            case let .resolved(source, sourceURL, entries):
                let changelog = Changelog(
                    selector: item.selector, name: token, installedVersion: version, availableVersion: nil, source: source, sourceURL: sourceURL,
                    entries: entries, fetchedAt: .now)
                let flags = ChangelogAudit.flags(changelog, item: item)
                var fields = [flags.isEmpty ? "ok" : "warn", token, version ?? "?", source, "\(entries.count)", flags.joined(separator: " ")]
                // SIFT_BENCH_VERSIONS=1 adds the first versions found, for looking into a flag.
                if ProcessInfo.processInfo.environment["SIFT_BENCH_VERSIONS"] != nil { fields.append(entries.prefix(8).map(\.version).joined(separator: " ")) }
                line = fields.map(\.terminalInline).joined(separator: "\t")
            case let .unavailable(tried):
                line = ["MISS", token, version ?? "?", "", "0", tried.joined(separator: " | ")].map(\.terminalInline).joined(separator: "\t")
            case let .failure(message):
                line = ["ERROR", token, version ?? "?", "", "0", message].map(\.terminalInline).joined(separator: "\t")
            }
            let done = results.withLock {
                $0.append((index, line)); return $0.count
            }
            let filled = done * 30 / max(tokenList.count, 1)
            let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: 30 - filled)
            FileHandle.standardError.write(Data("\r\u{1B}[2K\(bar) \(done)/\(tokenList.count) \(done * 100 / max(tokenList.count, 1))%  \(token)".utf8))
        }
        let lines = results.withLock { $0.sorted { $0.0 < $1.0 }.map(\.1) }
        print("status\tname\tversion\tsource\tentries\tflags")
        lines.forEach { print($0) }
        let clean = lines.filter { $0.hasPrefix("ok\t") }.count, flagged = lines.filter { $0.hasPrefix("warn\t") }.count
        FileHandle.standardError.write(Data("\r\u{1B}[2Kchangelogs found: \(clean + flagged)/\(lines.count), \(clean) with no audit flags\n".utf8))
        return EXIT_SUCCESS
    }
}
