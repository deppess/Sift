import Foundation

/// A cached Homebrew receipt is not proof that its cask is still on disk. In particular, a
/// manually removed cask can remain in Sift's last snapshot until the next full refresh.
/// This is a local, read-only check; it never invokes Homebrew or changes the database.
struct HomebrewCaskPresence {
    private var caskrooms: [String: Bool] = [:]
    private var installations: [String: Bool] = [:]

    mutating func isPresent(prefix: String, name: String, version: String) -> Bool {
        let caskroom = URL(filePath: prefix, directoryHint: .isDirectory).appending(path: "Caskroom", directoryHint: .isDirectory).path
        let knownCaskroom: Bool
        if let cached = caskrooms[caskroom] {
            knownCaskroom = cached
        } else {
            var directory: ObjCBool = false
            knownCaskroom =
                FileManager.default.fileExists(atPath: caskroom, isDirectory: &directory) && directory.boolValue
                && FileManager.default.isReadableFile(atPath: caskroom)
            caskrooms[caskroom] = knownCaskroom
        }
        // A synthetic database or a temporarily unavailable prefix cannot disprove the cached
        // record. Only a readable Homebrew Caskroom can tell us the installed version is gone.
        guard knownCaskroom else { return true }
        let path = URL(filePath: caskroom, directoryHint: .isDirectory).appending(path: name, directoryHint: .isDirectory)
            .appending(path: version, directoryHint: .isDirectory).path
        if let cached = installations[path] { return cached }
        var directory: ObjCBool = false
        let present = FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        installations[path] = present
        return present
    }

    /// A command for the Homebrew installation that owns the cached cask, not whichever `brew`
    /// happens to be first on PATH. Refuse malformed tokens instead of suggesting a command
    /// constructed from untrusted package metadata.
    static func uninstallCommand(prefix: String, token: String, force: Bool = false) -> String? {
        guard token.first?.isASCII == true, token.first?.isLetter == true || token.first?.isNumber == true,
            token.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@+._-").contains($0) }),
            prefix.hasPrefix("/"), !prefix.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
        else { return nil }
        let executable = URL(filePath: prefix, directoryHint: .isDirectory).appending(path: "bin/brew").path
        let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "\(quoted) uninstall --cask\(force ? " --force" : "") \(token)"
    }
}
