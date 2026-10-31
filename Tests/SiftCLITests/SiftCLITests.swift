import Foundation
import XCTest
@testable import SiftCLI
@testable import SiftCore

final class SiftCLITests: XCTestCase {

    func testEmptyCompletionPrefixMatchesCatalogCandidates() {
        XCTAssertTrue("ffmpeg".localizedCaseInsensitiveHasPrefix(""))
    }
    func testHelpSucceeds() {
        XCTAssertEqual(SiftCLI.run(arguments: ["--help"]), EXIT_SUCCESS)
    }

    func testVersionSucceeds() {
        XCTAssertEqual(SiftCLI.run(arguments: ["--version"]), EXIT_SUCCESS)
    }

    func testVersionJSONRendersVersionField() throws {
        let (status, output) = captureStdout { SiftCLI.run(arguments: ["--version", "--json"]) }
        XCTAssertEqual(status, EXIT_SUCCESS)
        let object = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        XCTAssertEqual(object?["version"] as? String, SiftVersion.current)
    }

    func testChangesReturnsAnEmptyCacheResult() {
        XCTAssertEqual(SiftCLI.run(arguments: ["changes", "--database", "/tmp/sift-missing-\(UUID().uuidString).sqlite3"]), EXIT_SUCCESS)
    }

    func testLogAcceptsDurationsAndDatesForSince() throws {
        let now = Date(timeIntervalSince1970: 10_000_000)
        XCTAssertEqual(Invocation.parseSince("30d", now: now), now.addingTimeInterval(-30 * 24 * 60 * 60))
        XCTAssertEqual(Invocation.parseSince("2w", now: now), now.addingTimeInterval(-14 * 24 * 60 * 60))
        XCTAssertEqual(Invocation.parseSince("12h", now: now), now.addingTimeInterval(-12 * 60 * 60))
        XCTAssertEqual(Invocation.parseSince("2026-10-01", now: now), Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        XCTAssertNil(Invocation.parseSince("soon", now: now))
        XCTAssertEqual(SiftCLI.run(arguments: ["log", "--since", "7d", "--database", "/tmp/sift-missing-\(UUID().uuidString).sqlite3"]), EXIT_SUCCESS)
        XCTAssertEqual(SiftCLI.run(arguments: ["updates", "--since", "7d"]), 2)
    }

    func testAppsAndRefreshAreRecognizedCommands() {
        XCTAssertEqual(SiftCLI.run(arguments: ["apps", "apps", "apps"]), 2)
        XCTAssertEqual(SiftCLI.run(arguments: ["refresh", "refresh"]), 2)
    }

    func testUsageErrorsReturnStatusTwo() {
        XCTAssertEqual(SiftCLI.run(arguments: ["refresh", "refresh"]), 2)
        XCTAssertEqual(SiftCLI.run(arguments: ["--database", "--json"]), 2)
        XCTAssertEqual(SiftCLI.run(arguments: ["--json", "--json"]), 2)
        XCTAssertEqual(SiftCLI.run(arguments: ["changes", "--full"]), 2)
        XCTAssertEqual(SiftCLI.run(arguments: ["apps", "--full"]), 2)
        XCTAssertEqual(SiftCLI.run(arguments: ["updates", "--update-homebrew"]), 2)
    }

    func testBashCompletionDoesNotUseCommandSubstitutionForCandidates() {
        let script = CompletionRenderer.script(for: .bash)
        XCTAssertFalse(script.contains("COMPREPLY=( $("))
        XCTAssertTrue(script.contains("while IFS= read -r value"))
    }

    func testFishCompletionResolvesSubcommandRegardlessOfPosition() {
        // `(commandline -opc)[2]` used to assume the subcommand was always the second token, so
        // `sift --json apps <TAB>` (a global flag before the subcommand) silently produced zero
        // completions. Guard against regressing back to positional indexing.
        let script = CompletionRenderer.script(for: .fish)
        XCTAssertTrue(script.contains(#"string match -r -- "^apps\$|^show\$|^log\$|^changelog\$""#))
        XCTAssertFalse(script.contains("(commandline -opc)[2]"))
    }

    func testBashCompletionResolvesSubcommandRegardlessOfPosition() {
        // `${COMP_WORDS[1]}` had the same positional-index bug as fish's `(commandline -opc)[2]`:
        // `sift --json apps <TAB>` fell through to the generic keyword list instead of calling
        // `sift __complete`. Verified live against bash 5.3 by simulating COMP_WORDS/COMP_CWORD for
        // both `sift apps <TAB>` and `sift --json apps <TAB>` and confirming they return the same
        // app-name candidates via `sift __complete`, not the generic word list.
        let script = CompletionRenderer.script(for: .bash)
        XCTAssertTrue(script.contains(#"case "${COMP_WORDS[i]}" in"#))
        XCTAssertFalse(script.contains(#""${COMP_WORDS[1]}" == "apps""#))
    }

    func testZshCompletionResolvesSubcommandRegardlessOfPosition() {
        // `$words[2]` had the same positional-index bug: zsh's `$words` is the raw command-line
        // token array (documented in `man zshcompwid`), so a preceding global flag shifted the
        // subcommand out of position 2. Fixed to scan `$words` for "apps"/"show" instead of
        // assuming a fixed index, mirroring the bash and fish fixes.
        let script = CompletionRenderer.script(for: .zsh)
        XCTAssertTrue(script.contains("for w in $words[2,CURRENT-1]"))
        XCTAssertFalse(script.contains("case $words[2] in"))
    }

    func testCompletionsOfferChangelogFlagsNamesAndShells() {
        let fish = CompletionRenderer.script(for: .fish)
        XCTAssertTrue(fish.contains("-n '__fish_seen_subcommand_from changelog' -l fetch"))
        XCTAssertTrue(fish.contains("-n '__fish_seen_subcommand_from completions' -a 'fish bash zsh'"))
        let bash = CompletionRenderer.script(for: .bash)
        XCTAssertTrue(bash.contains(#"changelog) words="--all --full --fetch" ;;"#))
        XCTAssertTrue(bash.contains(#"completions) words="fish bash zsh" ;;"#))
        let zsh = CompletionRenderer.script(for: .zsh)
        XCTAssertTrue(zsh.contains("{_sift_names changelog}"))
        XCTAssertTrue(zsh.contains("completions) _values shell fish bash zsh"))
    }

    func testAppsJSONRendersCachedNativeApplication() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let application = NativeApplication(path: "/Applications/Example.app", bundleIdentifier: "com.example.app", displayName: "Example", shortVersion: "1.0", buildVersion: nil, classification: .user, discoveryRoot: "/Applications")
        _ = try database.applyRefresh(refreshInput(nativeInventory: NativeInventoryResult(applications: [application])))

        let (status, output) = captureStdout { SiftCLI.run(arguments: ["apps", "--json", "--database", url.path]) }
        XCTAssertEqual(status, EXIT_SUCCESS)
        let items = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]]
        XCTAssertEqual(items?.count, 1)
        XCTAssertEqual(items?.first?["name"] as? String, "Example")
        XCTAssertEqual(items?.first?["installedVersion"] as? String, "1.0")
        XCTAssertEqual(items?.first?["kind"] as? String, "nativeApp")
    }

    func testAppsSelectorResolvesAgainstNativeCatalog() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let example = NativeApplication(path: "/Applications/Example.app", bundleIdentifier: "com.example.app", displayName: "Example", shortVersion: "1.0", buildVersion: nil, classification: .user, discoveryRoot: "/Applications")
        let other = NativeApplication(path: "/Applications/Other.app", bundleIdentifier: "com.example.other", displayName: "Other", shortVersion: "2.0", buildVersion: nil, classification: .user, discoveryRoot: "/Applications")
        _ = try database.applyRefresh(refreshInput(nativeInventory: NativeInventoryResult(applications: [example, other])))

        let (status, output) = captureStdout { SiftCLI.run(arguments: ["apps", "Example", "--json", "--database", url.path]) }
        XCTAssertEqual(status, EXIT_SUCCESS)
        let item = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        XCTAssertEqual(item?["name"] as? String, "Example")
        XCTAssertEqual(item?["installedVersion"] as? String, "1.0")
    }

    func testShowJSONRendersCachedHomebrewFormula() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let package = HomebrewPackage(prefix: "/opt/homebrew", kind: .formula, name: "example", fullName: "example", tap: "homebrew/core", ownership: .explicitlyRequested, installedVersion: "1.0", sourceURL: nil, artifactPaths: [], autoUpdates: false)
        let homebrewInventory = HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: "/opt/homebrew", packages: [package], complete: true, warnings: [])])
        let targetResults: [HomebrewPackageKey: HomebrewTargetResolution] = [HomebrewPackageKey(package): .unavailable("Homebrew does not report this package as outdated.")]
        _ = try database.applyRefresh(refreshInput(homebrewInventory: homebrewInventory, targetResults: targetResults))

        let (status, output) = captureStdout { SiftCLI.run(arguments: ["show", "example", "--json", "--database", url.path]) }
        XCTAssertEqual(status, EXIT_SUCCESS)
        let item = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        XCTAssertEqual(item?["name"] as? String, "example")
        XCTAssertEqual(item?["kind"] as? String, "homebrewFormula")
        XCTAssertEqual(item?["installedVersion"] as? String, "1.0")
        XCTAssertEqual(item?["prefix"] as? String, "/opt/homebrew")
    }

    func testChangesJSONRendersNativeVersionTransition() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let first = NativeApplication(path: "/Applications/Example.app", bundleIdentifier: "com.example.app", displayName: "Example", shortVersion: "1.0", buildVersion: nil, classification: .user, discoveryRoot: "/Applications")
        _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 1_000), nativeInventory: NativeInventoryResult(applications: [first])))
        let updated = NativeApplication(path: first.path, bundleIdentifier: first.bundleIdentifier, displayName: first.displayName, shortVersion: "2.0", buildVersion: nil, classification: .user, discoveryRoot: "/Applications")
        _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 2_000), nativeInventory: NativeInventoryResult(applications: [updated])))

        let (status, output) = captureStdout { SiftCLI.run(arguments: ["changes", "--json", "--database", url.path]) }
        XCTAssertEqual(status, EXIT_SUCCESS)
        let changes = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]]
        XCTAssertEqual(changes?.count, 1)
        XCTAssertEqual(changes?.first?["name"] as? String, "Example")
        XCTAssertEqual(changes?.first?["fromVersion"] as? String, "1.0")
        XCTAssertEqual(changes?.first?["toVersion"] as? String, "2.0")
    }

    /// Redirects fd 1 for the duration of `body` and returns what it printed, since `SiftCLI.run`
    /// writes directly to standard output rather than through an injectable sink.
    private func captureStdout(_ body: () -> Int32) -> (status: Int32, output: String) {
        fflush(stdout)
        let pipe = Pipe()
        let savedStdout = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        let status = body()
        fflush(stdout)
        // Restore the original fd before closing the pipe's write handle: dup2 left a second
        // descriptor (fd 1 itself) pointing at the pipe, so closing only the handle never
        // signals EOF and readDataToEndOfFile() would block forever.
        dup2(savedStdout, STDOUT_FILENO)
        close(savedStdout)
        try? pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (status, String(decoding: data, as: UTF8.self))
    }

    private func refreshInput(at date: Date = .now, nativeInventory: NativeInventoryResult = NativeInventoryResult(applications: []), homebrewInventory: HomebrewInventory = HomebrewInventory(prefixes: []), targetResults: [HomebrewPackageKey: HomebrewTargetResolution] = [:]) -> RefreshPersistenceInput {
        let providerResults = RefreshProvider.allCases.map { ProviderRefreshResult(provider: $0, status: .success, startedAt: date, finishedAt: date, dataAsOf: date) }
        return RefreshPersistenceInput(startedAt: date, finishedAt: date, nativeInventory: nativeInventory, homebrewInventory: homebrewInventory, targetResults: targetResults, releaseNoteResults: [:], providerResults: providerResults)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "sift-cli-test-\(UUID().uuidString).sqlite3")
    }

    private func removeDatabase(at url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal", ".refresh.lock"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

}
