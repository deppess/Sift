import Foundation

public struct CargoCrate: Equatable, Sendable {
    public let name: String
    public let version: String
}

public struct CargoInventory: Sendable {
    public let cargoHome: String?
    public let crates: [CargoCrate]
    public let warnings: [String]
}

/// Reads `cargo install`'s own record ($CARGO_HOME/.crates2.json) instead of running cargo.
/// Only crates.io crates whose binaries are still present count as installed; git and path
/// installs have no registry version to compare.
public struct CargoProvider: Sendable {
    public let cargoHome: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = environment["CARGO_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        cargoHome = URL(filePath: home ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cargo").path, directoryHint: .isDirectory)
    }

    public init(cargoHome: URL) { self.cargoHome = cargoHome }

    public func discover() -> CargoInventory {
        let record = cargoHome.appending(path: ".crates2.json")
        guard FileManager.default.fileExists(atPath: record.path) else { return CargoInventory(cargoHome: nil, crates: [], warnings: []) }
        guard let values = try? record.resourceValues(forKeys: [.fileSizeKey]), (values.fileSize ?? .max) <= 16 * 1_048_576,
              let data = try? Data(contentsOf: record),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let installs = document["installs"] as? [String: [String: Any]] else {
            return CargoInventory(cargoHome: cargoHome.path, crates: [], warnings: ["Cargo's install record at \(record.path) could not be read."])
        }
        var crates: [CargoCrate] = []
        for (key, install) in installs {
            // "<name> <version> (registry+https://github.com/rust-lang/crates.io-index)"
            let parts = key.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3, parts[2].contains("crates.io-index") || parts[2].contains("index.crates.io") else { continue }
            let binaries = install["bins"] as? [String] ?? []
            guard binaries.contains(where: { FileManager.default.isExecutableFile(atPath: cargoHome.appending(path: "bin").appending(path: $0).path) }) else { continue }
            crates.append(CargoCrate(name: parts[0], version: parts[1]))
        }
        return CargoInventory(cargoHome: cargoHome.path, crates: crates.sorted { $0.name < $1.name }, warnings: [])
    }

    /// crates.io's sparse index path for a crate name.
    static func indexURL(for name: String) -> URL? {
        let lower = name.lowercased()
        guard !lower.isEmpty, lower.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        let path: String
        switch lower.count {
        case 1: path = "1/\(lower)"
        case 2: path = "2/\(lower)"
        case 3: path = "3/\(lower.prefix(1))/\(lower)"
        default: path = "\(lower.prefix(2))/\(lower.dropFirst(2).prefix(2))/\(lower)"
        }
        return URL(string: "https://index.crates.io/\(path)")
    }

    /// The newest non-yanked version in a sparse-index file (one JSON object per line). Pre-releases
    /// count only when the installed version is itself a pre-release.
    static func latestVersion(indexData: Data, installed: String) -> String? {
        func isPrerelease(_ version: String) -> Bool { version.split(separator: "+", maxSplits: 1).first?.contains("-") == true }
        let allowPrerelease = isPrerelease(installed)
        var best: String?
        for line in indexData.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let version = entry["vers"] as? String, entry["yanked"] as? Bool != true,
                  allowPrerelease || !isPrerelease(version) else { continue }
            let core = version.split(separator: "+").first.map(String.init) ?? version
            if best.map({ SemanticVersion.compare(core, $0) == .orderedDescending }) ?? true { best = core }
        }
        return best
    }
}

/// SemVer 2.0 precedence, which crates.io versions follow: major, minor, and patch numerically;
/// a prerelease ("1.0.0-beta.2") orders before its release, its dot-separated identifiers
/// compare numerically when both are numbers and otherwise as ASCII text, with numbers first and
/// more identifiers winning a tie; build metadata ("+build.5") is ignored.
enum SemanticVersion {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let (left, right) = (split(lhs), split(rhs))
        for (a, b) in zip(left.core, right.core) where a != b { return numeric(a, b) }
        if left.core.count != right.core.count { return left.core.count < right.core.count ? .orderedAscending : .orderedDescending }
        switch (left.prerelease, right.prerelease) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (a?, b?):
            for (x, y) in zip(a, b) where x != y {
                switch (x.allSatisfy(\.isASCIIDigit), y.allSatisfy(\.isASCIIDigit)) {
                case (true, true): return numeric(x, y)
                case (true, false): return .orderedAscending
                case (false, true): return .orderedDescending
                case (false, false): return x < y ? .orderedAscending : .orderedDescending
                }
            }
            return a.count == b.count ? .orderedSame : (a.count < b.count ? .orderedAscending : .orderedDescending)
        }
    }

    private static func split(_ version: String) -> (core: [Substring], prerelease: [Substring]?) {
        let withoutBuild = version.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let pieces = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        return (pieces[0].split(separator: ".", omittingEmptySubsequences: false), pieces.count > 1 ? pieces[1].split(separator: ".", omittingEmptySubsequences: false) : nil)
    }

    /// Digit strings by value, without overflow; leading zeros don't count.
    private static func numeric(_ a: Substring, _ b: Substring) -> ComparisonResult {
        let (x, y) = (a.drop { $0 == "0" }, b.drop { $0 == "0" })
        if x.count != y.count { return x.count < y.count ? .orderedAscending : .orderedDescending }
        return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
