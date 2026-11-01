import Foundation

/// Valve's KeyValues text format (`.vdf`, `.acf`): quoted keys mapped to quoted strings or to
/// braced child objects.
enum ValveKeyValues {
    indirect enum Value: Equatable {
        case string(String)
        case object([(String, Value)])

        static func == (lhs: Value, rhs: Value) -> Bool {
            switch (lhs, rhs) {
            case let (.string(a), .string(b)): a == b
            case let (.object(a), .object(b)): a.map(\.0) == b.map(\.0) && zip(a, b).allSatisfy { $0.1 == $1.1 }
            default: false
            }
        }

        subscript(key: String) -> Value? {
            guard case let .object(pairs) = self else { return nil }
            return pairs.first { $0.0.caseInsensitiveCompare(key) == .orderedSame }?.1
        }

        var string: String? { if case let .string(value) = self { value } else { nil } }
        var children: [(String, Value)] { if case let .object(pairs) = self { pairs } else { [] } }
    }

    static func parse(_ text: String) -> Value? {
        var tokens = tokenize(text)[...]
        guard let pairs = parseObject(&tokens, nested: false) else { return nil }
        return .object(pairs)
    }

    private enum Token: Equatable { case string(String), open, close }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "{" { tokens.append(.open); index = text.index(after: index); continue }
            if character == "}" { tokens.append(.close); index = text.index(after: index); continue }
            if character == "/", text[index...].hasPrefix("//") {
                index = text[index...].firstIndex(of: "\n") ?? text.endIndex
                continue
            }
            if character == "\"" {
                var value = ""
                index = text.index(after: index)
                while index < text.endIndex, text[index] != "\"" {
                    if text[index] == "\\", text.index(after: index) < text.endIndex {
                        index = text.index(after: index)
                        value.append(text[index] == "n" ? "\n" : text[index] == "t" ? "\t" : text[index])
                    } else {
                        value.append(text[index])
                    }
                    index = text.index(after: index)
                }
                tokens.append(.string(value))
                if index < text.endIndex { index = text.index(after: index) }
                continue
            }
            if character.isWhitespace { index = text.index(after: index); continue }
            // Unquoted token (rare in Steam files): read up to whitespace or a brace.
            let end = text[index...].firstIndex { $0.isWhitespace || $0 == "{" || $0 == "}" || $0 == "\"" } ?? text.endIndex
            tokens.append(.string(String(text[index..<end])))
            index = end
        }
        return tokens
    }

    private static func parseObject(_ tokens: inout ArraySlice<Token>, nested: Bool) -> [(String, Value)]? {
        var pairs: [(String, Value)] = []
        while let token = tokens.popFirst() {
            switch token {
            case .close:
                return nested ? pairs : nil
            case .open:
                return nil
            case let .string(key):
                switch tokens.popFirst() {
                case let .string(value)?: pairs.append((key, .string(value)))
                case .open?:
                    guard let children = parseObject(&tokens, nested: true) else { return nil }
                    pairs.append((key, .object(children)))
                default: return nil
                }
            }
        }
        return nested ? nil : pairs
    }
}

public struct SteamGame: Equatable, Sendable {
    public let appID: String
    public let name: String
    public let buildID: String
    /// The build Steam has queued to install, when it differs from the installed one.
    public let pendingBuildID: String?
    public let installDirectory: String
}

public struct SteamLibrary: Equatable, Sendable {
    public let path: String
    public let games: [SteamGame]
}

public struct SteamInventory: Sendable {
    public let libraries: [SteamLibrary]
    public let warnings: [String]
    /// False when Steam isn't installed for this user at all.
    public let detected: Bool
}

/// Reads Steam's own library manifests. Nothing is executed and nothing touches the network:
/// Steam records each game's installed build and any build it has queued for update.
public struct SteamProvider: Sendable {
    public let steamDirectory: URL

    public init(
        steamDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Steam", directoryHint: .isDirectory)
    ) {
        self.steamDirectory = steamDirectory
    }

    // Steam's EAppState: bit 2 is "update required".
    private static let updateRequiredFlag = 2

    public func discover() -> SteamInventory {
        let libraryFile = steamDirectory.appending(path: "steamapps/libraryfolders.vdf")
        guard FileManager.default.fileExists(atPath: libraryFile.path) else {
            return SteamInventory(libraries: [], warnings: [], detected: false)
        }
        var warnings: [String] = []
        var libraryPaths = [steamDirectory.path]
        if let text = Self.readText(libraryFile), let document = ValveKeyValues.parse(text) {
            for (_, folder) in document["libraryfolders"]?.children ?? [] {
                if let path = folder["path"]?.string, path.hasPrefix("/"), !libraryPaths.contains(path) { libraryPaths.append(path) }
            }
        } else {
            warnings.append("Steam library list at \(libraryFile.path) could not be read.")
        }
        var libraries: [SteamLibrary] = []
        for path in libraryPaths {
            let steamapps = URL(filePath: path).appending(path: "steamapps", directoryHint: .isDirectory)
            // An external library on an unmounted drive is absent, not broken.
            guard let entries = try? FileManager.default.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: nil) else { continue }
            var games: [SteamGame] = []
            for manifest in entries where manifest.lastPathComponent.hasPrefix("appmanifest_") && manifest.pathExtension == "acf" {
                guard let text = Self.readText(manifest), let state = ValveKeyValues.parse(text)?["AppState"],
                    let appID = state["appid"]?.string, let name = state["name"]?.string?.nonEmpty,
                    let buildID = state["buildid"]?.string?.nonEmpty, let installDirectory = state["installdir"]?.string?.nonEmpty
                else {
                    warnings.append("Skipped unreadable Steam manifest \(manifest.lastPathComponent).")
                    continue
                }
                let flags = Int(state["StateFlags"]?.string ?? "") ?? 0
                let target = state["TargetBuildID"]?.string.flatMap { $0 == "0" ? nil : $0.nonEmpty }
                let pending = target.flatMap { $0 != buildID ? $0 : nil } ?? (flags & Self.updateRequiredFlag != 0 ? "newer build" : nil)
                games.append(
                    SteamGame(
                        appID: appID, name: name, buildID: buildID, pendingBuildID: pending,
                        installDirectory: steamapps.appending(path: "common").appending(path: installDirectory).path))
            }
            libraries.append(SteamLibrary(path: path, games: games.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }))
        }
        return SteamInventory(libraries: libraries, warnings: warnings, detected: true)
    }

    private static func readText(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
            (values.fileSize ?? .max) <= 4 * 1_048_576,
            let data = try? Data(contentsOf: url)
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
