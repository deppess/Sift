import Foundation
import XCTest
@testable import SiftCLI

final class SiftCLITests: XCTestCase {

    func testEmptyCompletionPrefixMatchesCatalogCandidates() {
        XCTAssertTrue("ffmpeg".localizedCaseInsensitiveHasPrefix(""))
    }
    func testHelpSucceeds() {
        XCTAssertEqual(SiftCLI.run(arguments: ["--help"]), EXIT_SUCCESS)
    }

    func testAppsAndRefreshAreRecognizedCommands() {
        XCTAssertEqual(SiftCLI.run(arguments: ["apps", "apps"]), 2)
        XCTAssertEqual(SiftCLI.run(arguments: ["refresh", "refresh"]), 2)
    }

    func testUsageErrorsReturnStatusTwo() {
        XCTAssertEqual(SiftCLI.run(arguments: ["refresh", "refresh"]), 2)
        XCTAssertEqual(SiftCLI.run(arguments: ["--database", "--json"]), 2)
        XCTAssertEqual(SiftCLI.run(arguments: ["--json", "--json"]), 2)
    }

    func testBashCompletionDoesNotUseCommandSubstitutionForCandidates() {
        let script = CompletionRenderer.script(for: .bash)
        XCTAssertFalse(script.contains("COMPREPLY=( $("))
        XCTAssertTrue(script.contains("while IFS= read -r value"))
    }

    func testZshCompletionQuotesInstallPath() throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "sift zsh ' test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(atPath: directory.path) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let completion = try CompletionInstaller.install(environment: ["SHELL": "/bin/zsh", "ZDOTDIR": directory.path])
        let zshrc = try String(contentsOf: directory.appending(path: ".zshrc"), encoding: .utf8)
        XCTAssertTrue(zshrc.contains("fpath=('\(directory.appending(path: ".zfunc").path.replacingOccurrences(of: "'", with: "'\\\\''"))' $fpath)"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: completion.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: completion.deletingLastPathComponent().path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.appending(path: ".zshrc").path)[.posixPermissions] as? Int, 0o600)
    }

    func testCompletionInstallerRejectsUnsafeConfiguredPaths() throws {
        XCTAssertThrowsError(try CompletionInstaller.install(environment: ["SHELL": "/bin/fish", "XDG_CONFIG_HOME": "relative"]))

        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "sift-completion-link-\(UUID().uuidString)", directoryHint: .isDirectory)
        let target = root.appending(path: "target", directoryHint: .isDirectory)
        let link = root.appending(path: "link", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try CompletionInstaller.install(environment: ["SHELL": "/bin/fish", "XDG_CONFIG_HOME": link.path]))
    }

    func testCompletionInstallerRejectsSymlinkDestinationAndZshrc() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "sift-completion-destination-link-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let fish = root.appending(path: "fish/completions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fish, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = root.appending(path: "target")
        try "target".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: fish.appending(path: "sift.fish"), withDestinationURL: target)
        XCTAssertThrowsError(try CompletionInstaller.install(environment: ["SHELL": "/bin/fish", "XDG_CONFIG_HOME": root.path]))

        let zshrcTarget = root.appending(path: "zshrc-target")
        try "target".write(to: zshrcTarget, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appending(path: ".zshrc"), withDestinationURL: zshrcTarget)
        XCTAssertThrowsError(try CompletionInstaller.install(environment: ["SHELL": "/bin/zsh", "ZDOTDIR": root.path]))
    }
}
