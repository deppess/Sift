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

        _ = try CompletionInstaller.install(environment: ["SHELL": "/bin/zsh", "ZDOTDIR": directory.path])
        let zshrc = try String(contentsOf: directory.appending(path: ".zshrc"), encoding: .utf8)
        XCTAssertTrue(zshrc.contains("fpath=('\(directory.appending(path: ".zfunc").path.replacingOccurrences(of: "'", with: "'\\\\''"))' $fpath)"))
    }

    func testCompletionInstallerRejectsUnsafeConfiguredPaths() throws {
        XCTAssertThrowsError(try CompletionInstaller.install(environment: ["SHELL": "/bin/fish", "XDG_CONFIG_HOME": "relative"]))

        let root = FileManager.default.temporaryDirectory.appending(path: "sift-completion-link-\(UUID().uuidString)", directoryHint: .isDirectory)
        let target = root.appending(path: "target", directoryHint: .isDirectory)
        let link = root.appending(path: "link", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try CompletionInstaller.install(environment: ["SHELL": "/bin/fish", "XDG_CONFIG_HOME": link.path]))
    }
}
