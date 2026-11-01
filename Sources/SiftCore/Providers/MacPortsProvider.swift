import CSQLite
import Foundation

public struct MacPort: Equatable, Sendable {
    public let name: String
    public let epoch: Int
    public let version: String
    public let revision: Int
    public let requested: Bool
    /// Application bundles this port installed, from the registry's file list.
    public let applicationPaths: [String]

    /// MacPorts' own spelling, `version_revision`.
    public var displayVersion: String { "\(version)_\(revision)" }
}

public struct MacPortsIndexEntry: Equatable, Sendable {
    public let epoch: Int
    public let version: String
    public let revision: Int

    public var displayVersion: String { "\(version)_\(revision)" }
}

public struct MacPortsInventory: Sendable {
    public let prefix: String?
    public let ports: [MacPort]
    /// Latest available versions from the local port index, for installed ports only.
    public let index: [String: MacPortsIndexEntry]
    public let indexAvailable: Bool
    /// When the local port index was last synced (`port selfupdate`/`sync`).
    public var indexDate: Date? = nil
    public let warnings: [String]
}

/// Reads MacPorts' registry database and its locally synced port index directly. `port` is never
/// run: listing and outdated checks need no network, and they keep working when `port` itself
/// can't start (it refuses to run after a macOS upgrade until `port migrate`).
public struct MacPortsProvider: Sendable {
    public let prefix: URL

    public init(prefix: URL = URL(filePath: "/opt/local", directoryHint: .isDirectory)) {
        self.prefix = prefix
    }

    public func discover() -> MacPortsInventory {
        let registry = prefix.appending(path: "var/macports/registry/registry.db")
        guard FileManager.default.fileExists(atPath: registry.path) else {
            return MacPortsInventory(prefix: nil, ports: [], index: [:], indexAvailable: false, warnings: [])
        }
        let ports: [MacPort]
        do {
            ports = try readRegistry(registry)
        } catch {
            return MacPortsInventory(
                prefix: prefix.path, ports: [], index: [:], indexAvailable: false,
                warnings: ["MacPorts registry at \(registry.path): \(error.localizedDescription)"])
        }
        let names = Set(ports.map(\.name))
        var index: [String: MacPortsIndexEntry] = [:]
        let indexFiles = portIndexFiles()
        for file in indexFiles {
            // Earlier sources take precedence, as in MacPorts.
            for (name, entry) in Self.parsePortIndex(at: file, names: names) where index[name] == nil { index[name] = entry }
        }
        let warnings = indexFiles.isEmpty ? ["No synced MacPorts port index was found; run 'sudo port sync' to enable update checks."] : []
        let indexDate = indexFiles.compactMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }.max()
        return MacPortsInventory(prefix: prefix.path, ports: ports, index: index, indexAvailable: !indexFiles.isEmpty, indexDate: indexDate, warnings: warnings)
    }

    /// MacPorts' online port database: a port's current version, for checking against when the
    /// local index hasn't been synced in a while. The API gives no revision.
    public static func apiURL(for name: String) -> URL? {
        name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.+"))).flatMap {
            URL(string: "https://ports.macports.org/api/v1/ports/\($0)/")
        }
    }

    public static func apiEntry(_ data: Data) -> MacPortsIndexEntry? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let version = object["version"] as? String else { return nil }
        let epoch = (object["epoch"] as? Int) ?? Int(object["epoch"] as? String ?? "") ?? 0
        return MacPortsIndexEntry(epoch: epoch, version: version, revision: 0)
    }

    /// Whether `index` offers a newer version than the installed port, by MacPorts' ordering:
    /// epoch, then version, then revision.
    public static func isOutdated(_ port: MacPort, index: MacPortsIndexEntry) -> Bool {
        if index.epoch != port.epoch { return index.epoch > port.epoch }
        let order = compareVersions(index.version, port.version)
        if order != .orderedSame { return order == .orderedDescending }
        return index.revision > port.revision
    }

    /// MacPorts' `vercmp`: alphanumeric runs compared left to right, digits numerically and
    /// letters lexically, a digit run outranking a letter run, and leftover runs winning.
    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func runs(_ text: String) -> [Substring] {
            var result: [Substring] = []
            var index = text.startIndex
            while index < text.endIndex {
                guard text[index].isLetter || text[index].isNumber, text[index].isASCII else { index = text.index(after: index); continue }
                let isDigit = text[index].isNumber
                let end = text[index...].firstIndex { !$0.isASCII || (isDigit ? !$0.isNumber : !$0.isLetter) } ?? text.endIndex
                result.append(text[index..<end])
                index = end
            }
            return result
        }
        let left = runs(lhs)
        let right = runs(rhs)
        for (a, b) in zip(left, right) {
            let aDigit = a.first!.isNumber
            let bDigit = b.first!.isNumber
            if aDigit != bDigit { return aDigit ? .orderedDescending : .orderedAscending }
            if aDigit {
                let x = a.drop { $0 == "0" }
                let y = b.drop { $0 == "0" }
                if x.count != y.count { return x.count < y.count ? .orderedAscending : .orderedDescending }
                if x != y { return x < y ? .orderedAscending : .orderedDescending }
            } else if a != b {
                return a < b ? .orderedAscending : .orderedDescending
            }
        }
        return left.count == right.count ? .orderedSame : left.count < right.count ? .orderedAscending : .orderedDescending
    }

    // MARK: Registry

    private func readRegistry(_ url: URL) throws -> [MacPort] {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        // Read-only and never creating anything: the registry belongs to root.
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let handle else {
            throw MacPortsError.registry(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open")
        }
        sqlite3_busy_timeout(handle, 1_000)
        var applications: [Int64: [String]] = [:]
        try query(
            handle,
            "SELECT files.id, files.path FROM files JOIN ports ON ports.id = files.id WHERE ports.state = 'installed' AND files.path LIKE '%.app/Contents/Info.plist';"
        ) { statement in
            let path = String(cString: sqlite3_column_text(statement, 1))
            let bundle = String(path.dropLast("/Contents/Info.plist".count))
            // Bundles inside a framework (Python.framework's Python.app) aren't applications.
            guard !bundle.contains(".framework/") else { return }
            applications[sqlite3_column_int64(statement, 0), default: []].append(bundle)
        }
        var ports: [MacPort] = []
        try query(handle, "SELECT id, name, epoch, version, revision, requested FROM ports WHERE state = 'installed';") { statement in
            guard let name = sqlite3_column_text(statement, 1), let version = sqlite3_column_text(statement, 3) else { return }
            let id = sqlite3_column_int64(statement, 0)
            ports.append(
                MacPort(
                    name: String(cString: name), epoch: Int(sqlite3_column_int(statement, 2)), version: String(cString: version),
                    revision: Int(sqlite3_column_int(statement, 4)), requested: sqlite3_column_int(statement, 5) == 1,
                    applicationPaths: (applications[id] ?? []).sorted()))
        }
        return ports.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func query(_ handle: OpaquePointer, _ sql: String, row: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MacPortsError.registry(String(cString: sqlite3_errmsg(handle)))
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(statement)
            case SQLITE_DONE: return
            default: throw MacPortsError.registry(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    // MARK: Port index

    /// The PortIndex for each configured source, in sources.conf order. Synced sources live under
    /// var/macports/sources/<host>/<path without archive extension>; file:// sources are local.
    private func portIndexFiles() -> [URL] {
        let configuration = prefix.appending(path: "etc/macports/sources.conf")
        guard let text = try? String(contentsOf: configuration, encoding: .utf8) else { return [] }
        var files: [URL] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let field = trimmed.split(separator: " ").first, let url = URL(string: String(field)),
                let scheme = url.scheme
            else { continue }
            let directory: URL
            if scheme == "file" {
                directory = URL(filePath: url.path, directoryHint: .isDirectory)
            } else {
                guard let host = url.host else { continue }
                var path = url.path
                for suffix in [".tar.gz", ".tar.bz2", ".tar"] where path.hasSuffix(suffix) { path = String(path.dropLast(suffix.count)) }
                directory = prefix.appending(path: "var/macports/sources").appending(path: host).appending(path: path, directoryHint: .isDirectory)
            }
            let file = directory.appending(path: "PortIndex")
            if FileManager.default.fileExists(atPath: file.path) { files.append(file) }
        }
        return files
    }

    /// PortIndex alternates a "<name> <length>" header line with a Tcl list of key/value pairs.
    /// Only entries for `names` are decoded.
    ///
    /// An entry ends at the first newline outside braces, not at the first newline: a few
    /// descriptions span lines (xz's, for one), and Tcl only writes a raw newline inside braces.
    /// The length isn't used either: Tcl counts characters its own way (an emoji in arangodb's
    /// description throws it off).
    static func parsePortIndex(at url: URL, names: Set<String>) -> [String: MacPortsIndexEntry] {
        guard !names.isEmpty, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [:] }
        let lowercasedNames = Set(names.map { $0.lowercased() })
        var entries: [String: MacPortsIndexEntry] = [:]
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var index = 0
            // The next record: from `index` to the first newline at brace depth zero.
            func nextRecord() -> UnsafeRawBufferPointer.SubSequence? {
                guard index < bytes.count else { return nil }
                let start = index
                var depth = 0
                while index < bytes.count {
                    switch bytes[index] {
                    case UInt8(ascii: "\\"): index += 1
                    case UInt8(ascii: "{"): depth += 1
                    case UInt8(ascii: "}") where depth > 0: depth -= 1
                    case UInt8(ascii: "\n") where depth == 0:
                        index += 1
                        return bytes[start..<(index - 1)]
                    default: break
                    }
                    index += 1
                }
                return bytes[start..<min(index, bytes.count)]
            }
            while let header = nextRecord(), let body = nextRecord() {
                guard let space = header.lastIndex(of: UInt8(ascii: " ")) else { continue }
                let name = String(decoding: header[header.startIndex..<space], as: UTF8.self)
                guard lowercasedNames.contains(name.lowercased()) else { continue }
                let fields = tclPairs(String(decoding: body, as: UTF8.self))
                guard let version = fields["version"], !version.isEmpty else { continue }
                entries[name] = MacPortsIndexEntry(epoch: Int(fields["epoch"] ?? "") ?? 0, version: version, revision: Int(fields["revision"] ?? "") ?? 0)
            }
        }
        return entries
    }

    /// Splits a flat Tcl list into key/value pairs, honoring braces and backslash escapes.
    private static func tclPairs(_ text: String) -> [String: String] {
        var words: [String] = []
        var current = ""
        var depth = 0
        var inWord = false
        var escaped = false
        for character in text {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; inWord = true; continue }
            if character == "{" {
                if depth > 0 { current.append(character) }
                depth += 1; inWord = true
                continue
            }
            if character == "}", depth > 0 {
                depth -= 1
                if depth > 0 { current.append(character) }
                continue
            }
            if character.isWhitespace, depth == 0 {
                if inWord { words.append(current); current = ""; inWord = false }
                continue
            }
            current.append(character); inWord = true
        }
        if inWord { words.append(current) }
        var pairs: [String: String] = [:]
        var index = 0
        while index + 1 < words.count {
            pairs[words[index]] = words[index + 1]
            index += 2
        }
        return pairs
    }
}

public enum MacPortsError: LocalizedError {
    case registry(String)
    public var errorDescription: String? {
        switch self {
        case let .registry(message): "The MacPorts registry could not be read: \(message)"
        }
    }
}
