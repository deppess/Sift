import CryptoKit
import Foundation

/// Saved `brew info --installed` and `brew outdated` output for a prefix, reused while the
/// prefix's fingerprint is unchanged.
public protocol HomebrewSnapshotStoring: Sendable {
    func homebrewSnapshot(prefix: String, fingerprint: String, notBefore: Date) -> (info: Data, outdated: Data)?
    func storeHomebrewSnapshot(prefix: String, fingerprint: String, info: Data, outdated: Data, at date: Date)
}

extension HomebrewProvider {
    /// Even an unchanged fingerprint is trusted for at most a day.
    static let snapshotMaximumAge: TimeInterval = 24 * 60 * 60

    /// A digest of everything `brew info --installed` and `brew outdated` read, taken from file
    /// timestamps without starting `brew`:
    /// - installed kegs and casks (Cellar, Caskroom, each keg's install receipt, cask metadata),
    /// - which kegs are linked or pinned,
    /// - package metadata (the repository and every tap's git checkout, the API snapshots),
    /// - `HOMEBREW_*` settings and the `brew` executable itself.
    /// Installing, upgrading, uninstalling, pinning, tapping, and `brew update` all rewrite at least
    /// one of these, so a matching fingerprint means Homebrew would answer the same way again.
    func snapshotFingerprint(executable: URL, prefix: String) -> String {
        let fileManager = FileManager.default
        var lines = environment.filter { $0.key.hasPrefix("HOMEBREW_") }.sorted { $0.key < $1.key }.map { "env \($0.key)=\($0.value)" }
        func stamp(_ path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { lines.append("- \(path)"); return }
            lines.append("\(path) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec) \(info.st_size)")
        }
        func children(_ path: String) -> [String] {
            ((try? fileManager.contentsOfDirectory(atPath: path)) ?? []).sorted().map { "\(path)/\($0)" }
        }
        stamp(executable.path)
        for directory in ["Cellar", "Caskroom", "opt", "var/homebrew/linked", "var/homebrew/pinned"] { stamp("\(prefix)/\(directory)") }
        for formula in children("\(prefix)/Cellar") {
            stamp(formula)
            for keg in children(formula) {
                stamp(keg)
                stamp("\(keg)/INSTALL_RECEIPT.json")
            }
        }
        for cask in children("\(prefix)/Caskroom") {
            stamp(cask)
            stamp("\(cask)/.metadata")
            children("\(cask)/.metadata").forEach(stamp)
        }
        let repository = fileManager.fileExists(atPath: "\(prefix)/.git") ? prefix : "\(prefix)/Homebrew"
        let taps = children("\(repository)/Library/Taps").flatMap(children)
        for checkout in [repository] + taps {
            stamp(checkout)
            for file in [".git/FETCH_HEAD", ".git/index", ".git/HEAD", ".git/packed-refs", "Formula", "Casks"] { stamp("\(checkout)/\(file)") }
        }
        apiSnapshotFiles().forEach(stamp)
        return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Homebrew's downloaded package metadata (`*.jws.json`), rewritten by every `brew update`.
    func apiSnapshotFiles() -> [String] {
        guard let cache = environment["HOMEBREW_CACHE"]?.nonEmpty ?? environment["HOME"]?.nonEmpty.map({ "\($0)/Library/Caches/Homebrew" }) else { return [] }
        return ["\(cache)/api", "\(cache)/api/internal"].flatMap { directory in
            ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter { $0.hasSuffix(".jws.json") }.sorted().map { "\(directory)/\($0)" }
        }
    }
}

/// Snapshots live in the metadata cache table, compressed, keyed by prefix, with the fingerprint
/// in place of an ETag; they are pruned with it.
extension Database: HomebrewSnapshotStoring {
    private static let snapshotKinds = (info: "homebrew-info-snapshot-v1", outdated: "homebrew-outdated-snapshot-v1")

    public func homebrewSnapshot(prefix: String, fingerprint: String, notBefore: Date) -> (info: Data, outdated: Data)? {
        func load(_ kind: String) -> Data? {
            guard let cached = try? cachedMetadataResponse(url: "homebrew:\(prefix)", resourceKind: kind),
                cached.etag == fingerprint, cached.validatedAt >= notBefore, let body = cached.body
            else { return nil }
            return try? (body as NSData).decompressed(using: .lzfse) as Data
        }
        guard let info = load(Self.snapshotKinds.info), let outdated = load(Self.snapshotKinds.outdated) else { return nil }
        return (info, outdated)
    }

    public func storeHomebrewSnapshot(prefix: String, fingerprint: String, info: Data, outdated: Data, at date: Date) {
        for (kind, data) in [(Self.snapshotKinds.info, info), (Self.snapshotKinds.outdated, outdated)] {
            guard let compressed = try? (data as NSData).compressed(using: .lzfse) as Data else { return }
            try? storeMetadataResponse(
                url: "homebrew:\(prefix)", resourceKind: kind, statusCode: 200, body: compressed, etag: fingerprint, lastModified: nil, validatedAt: date)
        }
    }
}
