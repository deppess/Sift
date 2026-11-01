import CSQLite
import Foundation
import XCTest

final class SiftIntegrationTests: XCTestCase {
    private var root: URL!
    private var executable: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIFT_RUN_INTEGRATION_TESTS"] == "1", "Integration tests require SIFT_RUN_INTEGRATION_TESTS=1.")
        guard let path = ProcessInfo.processInfo.environment["SIFT_EXECUTABLE"] else {
            throw XCTSkip("Integration tests require SIFT_EXECUTABLE.")
        }
        executable = URL(fileURLWithPath: path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        root = FileManager.default.temporaryDirectory.appending(path: "sift-integration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testHelpDoesNotCreateDatabase() throws {
        let database = root.appending(path: "unused.sqlite3")
        let help = try Self.run(executable: executable, ["--help", "--database", database.path])
        XCTAssertEqual(help.status, 0)
        XCTAssertEqual(
            help.stdout,
            "Usage: sift [refresh|apps [name]|updates|log [name]|changelog <name>|show <name>|completions <fish|bash|zsh>] [--version] [--json] [--all] [--full] [--fetch] [--since <30d|2w|12h|YYYY-MM-DD>] [--no-color] [--update-homebrew|--no-update-homebrew] [--database <path>]\n"
        )
        XCTAssertEqual(help.stderr, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))

    }

    func testCompletionsAreGeneratedWithoutDatabaseAccess() throws {
        let database = root.appending(path: "unused.sqlite3")
        for shell in ["fish", "bash", "zsh"] {
            let result = try Self.run(executable: executable, ["completions", shell, "--database", database.path])
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.stderr, "")
            XCTAssertTrue(result.stdout.contains("sift"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        }
        let invalid = try Self.run(executable: executable, ["completions", "powershell"])
        XCTAssertEqual(invalid.status, 2)
        XCTAssertEqual(invalid.stdout, "")
    }

    func testRefreshAndAppsUseActualNativeInventory() throws {
        let database = root.appending(path: "inventory.sqlite3")
        let refresh = try Self.run(executable: executable, ["refresh", "--json", "--database", database.path])
        XCTAssertTrue([0, 1].contains(refresh.status))
        let summary = try JSONSerialization.jsonObject(with: Data(refresh.stdout.utf8)) as? [String: Any]
        XCTAssertTrue((summary?["discoveredCount"] as? Int ?? 0) > 0)
        XCTAssertTrue(["success", "partial"].contains(summary?["status"] as? String))
        let apps = try Self.run(executable: executable, ["apps", "--json", "--database", database.path])
        XCTAssertEqual(apps.status, 0)
        XCTAssertTrue((try JSONSerialization.jsonObject(with: Data(apps.stdout.utf8)) as? [[String: Any]] ?? []).count > 0)
    }

    func testJSONDashboardDoesNotCreateMissingDatabase() throws {
        let database = root.appending(path: "missing-dashboard.sqlite3")
        let result = try Self.run(executable: executable, ["--json", "--database", database.path])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stderr, "")
        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        XCTAssertEqual(object?["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object?["freshness"] as? String, "unknown")
        XCTAssertEqual(object?["latestRefreshStatus"] as? String, "never")
        XCTAssertTrue(object?.keys.contains("lastAttemptAt") == true)
        XCTAssertTrue(object?.keys.contains("dataAsOf") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + "-shm"))
    }

    func testUsageFailuresDoNotCreateDatabase() throws {
        let database = root.appending(path: "unused.sqlite3")
        for arguments in [["--database", "--json"], ["--json", "--json"], ["refresh", "refresh"]] {
            let result = try Self.run(executable: executable, arguments + ["--database", database.path])
            XCTAssertEqual(result.status, 2)
            XCTAssertEqual(result.stdout, "")
            XCTAssertTrue(result.stderr.contains("Usage: sift"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        }
    }

    func testRejectsMissingDirectoryAndSymlink() throws {
        let missing = root.appending(path: "missing/database.sqlite3")
        let missingResult = try Self.run(executable: executable, ["refresh", "--database", missing.path])
        XCTAssertEqual(missingResult.status, 1)
        XCTAssertTrue(missingResult.stderr.contains("parent directory does not exist"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))

        let target = root.appending(path: "target.sqlite3")
        try Data("not a database".utf8).write(to: target)
        let link = root.appending(path: "link.sqlite3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let linkResult = try Self.run(executable: executable, ["refresh", "--database", link.path])
        XCTAssertEqual(linkResult.status, 1)
        XCTAssertTrue(linkResult.stderr.contains("not a regular file path"))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "not a database")
    }

    func testRejectsObsoleteAndFutureSchema() throws {
        for version in [1, 999] {
            let database = root.appending(path: "schema-\(version).sqlite3")
            try execute(database, "CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY NOT NULL); INSERT INTO schema_migrations VALUES (\(version));")
            let result = try Self.run(executable: executable, ["--database", database.path])
            XCTAssertEqual(result.status, 1)
            XCTAssertTrue(result.stderr.contains(version == 1 ? "obsolete pre-release" : "newer"))
            XCTAssertEqual(try scalar(database, "SELECT version FROM schema_migrations;"), "\(version)")
        }
    }

    func testConcurrentCachedReadsKeepDatabaseHealthy() throws {
        let database = root.appending(path: "concurrent.sqlite3")
        let refresh = try Self.run(executable: executable, ["refresh", "--json", "--database", database.path])
        XCTAssertTrue([0, 1].contains(refresh.status))
        let group = DispatchGroup()
        let results = ProcessResults()
        let executable = executable!
        for _ in 0..<16 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                if let result = try? Self.run(executable: executable, ["--json", "--database", database.path]) {
                    results.append(result)
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertEqual(results.values.count, 16)
        XCTAssertTrue(results.values.allSatisfy { $0.status == 0 && $0.stderr.isEmpty })
        XCTAssertEqual(try scalar(database, "PRAGMA integrity_check;"), "ok")
        XCTAssertEqual(try scalar(database, "SELECT COUNT(*) FROM schema_migrations WHERE version = 15;"), "1")
    }

    func testRejectsCorruptDatabase() throws {
        let database = root.appending(path: "corrupt.sqlite3")
        try Data("this is not sqlite".utf8).write(to: database)
        let result = try Self.run(executable: executable, ["--database", database.path])
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("file is not a database"))
    }

    func testLockedDatabaseFailsWithinBusyTimeout() throws {
        let database = root.appending(path: "locked.sqlite3")
        _ = try Self.run(executable: executable, ["--database", database.path])
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var error: UnsafeMutablePointer<CChar>?
        defer { sqlite3_free(error) }
        XCTAssertEqual(sqlite3_exec(handle, "BEGIN EXCLUSIVE;", nil, nil, &error), SQLITE_OK)

        let startedAt = Date()
        let result = try Self.run(executable: executable, ["--database", database.path])
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("database is locked"))
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 7)
    }

    private static func run(executable: URL, _ arguments: [String], timeout: TimeInterval = 600) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let outputGroup = DispatchGroup()
        let stdoutData = ProcessData()
        let stderrData = ProcessData()
        outputGroup.enter()
        DispatchQueue.global().async {
            stdoutData.set(stdout.fileHandleForReading.readDataToEndOfFile())
            outputGroup.leave()
        }
        outputGroup.enter()
        DispatchQueue.global().async {
            stderrData.set(stderr.fileHandleForReading.readDataToEndOfFile())
            outputGroup.leave()
        }
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        if completion.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = completion.wait(timeout: .now() + 2)
            throw ProcessTimeout()
        }
        XCTAssertEqual(outputGroup.wait(timeout: .now() + 2), .success)
        return ProcessResult(
            status: process.terminationStatus, stdout: String(decoding: stdoutData.value, as: UTF8.self),
            stderr: String(decoding: stderrData.value, as: UTF8.self))
    }

    private func execute(_ url: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw SQLiteFailure() }
        defer { sqlite3_close(handle) }
        var error: UnsafeMutablePointer<CChar>?
        defer { sqlite3_free(error) }
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else { throw SQLiteFailure() }
    }

    private func scalar(_ url: URL, _ sql: String) throws -> String {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else { throw SQLiteFailure() }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SQLiteFailure() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw SQLiteFailure() }
        return String(cString: value)
    }

}

private struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private final class ProcessResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProcessResult] = []

    var values: [ProcessResult] {
        lock.withLock { storage }
    }

    func append(_ result: ProcessResult) {
        lock.withLock { storage.append(result) }
    }
}

private final class ProcessData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var value: Data { lock.withLock { storage } }

    func set(_ data: Data) {
        lock.withLock { storage = data }
    }
}

private struct ProcessTimeout: Error {}

private struct SQLiteFailure: Error {}
