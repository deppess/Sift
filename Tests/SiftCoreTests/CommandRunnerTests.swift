import Darwin
import Foundation
import XCTest
@testable import SiftCore

final class CommandRunnerTests: XCTestCase {
    func testCommandRunnerStopsOversizedStreamingOutput() throws {
        let runner = CommandRunner()
        XCTAssertThrowsError(
            try runner.run(
                executable: URL(filePath: "/usr/bin/yes"), arguments: [], environment: ProcessInfo.processInfo.environment, timeout: 5, outputLimit: 1_024)
        ) { error in
            XCTAssertEqual((error as? CommandRunnerError)?.errorDescription, CommandRunnerError.outputTooLarge(URL(filePath: "/usr/bin/yes")).errorDescription)
        }
    }

    func testCommandRunnerKillsOutputProducingDescendant() throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "sift-command-runner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = "trap '' TERM; sleep 0.1; (trap '' TERM; printf '%s' \"$$\" > \"$1\"; while :; do printf x; done) & wait"

        XCTAssertThrowsError(
            try CommandRunner().run(
                executable: URL(filePath: "/bin/sh"), arguments: ["-c", script, "sh", pidFile.path], environment: ProcessInfo.processInfo.environment,
                timeout: 5, outputLimit: 1_024)
        ) { error in
            XCTAssertEqual((error as? CommandRunnerError)?.errorDescription, CommandRunnerError.outputTooLarge(URL(filePath: "/bin/sh")).errorDescription)
        }
        let childPID = try XCTUnwrap(Int32(String(decoding: try Data(contentsOf: pidFile), as: UTF8.self)))
        XCTAssertEqual(kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testCommandRunnerReturnsNonzeroStatus() throws {
        let runner = CommandRunner()
        let result = try runner.run(
            executable: URL(filePath: "/bin/sh"), arguments: ["-c", "printf failure >&2; exit 7"], environment: ProcessInfo.processInfo.environment)
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "failure")
    }

    func testCommandRunnerGivesChildrenNoInputAndOnlyStandardDescriptors() throws {
        // A descriptor the parent leaves open (here a pipe, as concurrent commands do) must not
        // reach the child.
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { descriptors.forEach { close($0) } }

        let result = try CommandRunner().run(
            executable: URL(filePath: "/bin/sh"),
            arguments: [
                "-c",
                "read line; echo \"[$line]\"; for fd in 3 4 5 6 7 8 9 \(descriptors[0]) \(descriptors[1]); do (: <&$fd) 2>/dev/null && echo open $fd; done"
            ], environment: ["PATH": "/usr/bin:/bin"], timeout: 5)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "[]\n", "stdin is /dev/null and nothing beyond 0–2 is inherited")
    }
}
