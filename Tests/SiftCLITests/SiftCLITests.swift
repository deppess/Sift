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
}
