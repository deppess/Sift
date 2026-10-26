import Foundation

/// Which installer package placed a file, from macOS's package receipts (`pkgutil --file-info`).
/// Answers are remembered for the run and, with a database, across runs: an answer stands until an
/// installer rewrites /var/db/receipts or the bundle itself changes, so pkgutil (one process per
/// path) runs only for new or changed apps.
final class InstallerReceipts: @unchecked Sendable {
    private let runner: CommandRunner
    private let database: Database?
    private let lock = NSLock()
    private var cache: [String: String?] = [:]

    init(runner: CommandRunner, database: Database? = nil) {
        self.runner = runner
        self.database = database
    }

    func package(for path: String) -> String? {
        if let cached = lock.withLock({ cache[path] }) { return cached }
        let validator = Self.validator(for: path)
        let package: String?
        if let validator, let saved = try? database?.cachedMetadataResponse(url: "pkgutil:\(path)", resourceKind: Self.cacheKind), saved.etag == validator, let body = saved.body {
            package = String(decoding: body, as: UTF8.self).nonEmpty
        } else {
            package = lookUp(path)
            if let validator { try? database?.storeMetadataResponse(url: "pkgutil:\(path)", resourceKind: Self.cacheKind, statusCode: 200, body: Data((package ?? "").utf8), etag: validator, lastModified: nil, validatedAt: .now) }
        }
        lock.withLock { cache[path] = package }
        return package
    }

    private static let cacheKind = "installer-receipt-v1"

    /// The receipt database's and the bundle's identity and modification times.
    private static func validator(for path: String) -> String? {
        var receipts = stat(), bundle = stat()
        guard stat("/var/db/receipts", &receipts) == 0, stat(path, &bundle) == 0 else { return nil }
        return "\(receipts.st_mtimespec.tv_sec).\(receipts.st_mtimespec.tv_nsec)|\(bundle.st_ino).\(bundle.st_mtimespec.tv_sec).\(bundle.st_mtimespec.tv_nsec)"
    }

    private func lookUp(_ path: String) -> String? {
        guard path.hasPrefix("/"),
              let result = try? runner.run(executable: URL(filePath: "/usr/sbin/pkgutil"), arguments: ["--file-info", path], environment: ["PATH": "/usr/bin:/bin:/usr/sbin", "LC_ALL": "C"], timeout: 10, outputLimit: 1_048_576),
              result.status == 0 else { return nil }
        // Several receipts can claim a path; only an unambiguous one counts.
        let packages = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("pkgid: ") else { return nil }
            return String(line.dropFirst("pkgid: ".count)).trimmingCharacters(in: .whitespaces).nonEmpty
        }
        return Set(packages).count == 1 ? packages.first : nil
    }
}
