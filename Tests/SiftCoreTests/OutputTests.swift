import Darwin
import Foundation
import XCTest
@testable import SiftCore

final class OutputTests: XCTestCase {
    func testJSONIsDecodableAndContainsExplicitNulls() throws {
        let dashboard = Dashboard(generatedAt: Date(timeIntervalSince1970: 1_000), lastAttemptAt: nil, dataAsOf: nil, freshness: .unknown, latestRefreshStatus: .never, data: DashboardData(availableUpdateCount: 0, recentTransitionCount: 0, failedProviderCount: 0))
        let output = try DashboardRenderer.json(dashboard)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(Dashboard.self, from: Data(output.utf8)), dashboard)
        XCTAssertTrue(output.contains("\"lastAttemptAt\" : null"))
        XCTAssertTrue(output.contains("\"dataAsOf\" : null"))
    }

    func testUpdatesRendererSurfacesStaleSnapshot() {
        let stale = UnifiedUpdate(provider: "homebrew", scope: "/opt/homebrew", name: "example", installedVersion: "1.0", availableVersion: "2.0", freshness: .stale, dataAsOf: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(UpdatesRenderer.humanReadable([stale]).contains("Snapshot is stale"))

        let current = UnifiedUpdate(provider: "homebrew", scope: "/opt/homebrew", name: "example", installedVersion: "1.0", availableVersion: "2.0", freshness: .current, dataAsOf: Date(timeIntervalSince1970: 1_000))
        XCTAssertFalse(UpdatesRenderer.humanReadable([current]).contains("Snapshot is stale"))
    }

    func testHumanReadableOutputStripsTerminalControlSequences() {
        let notes = HomebrewReleaseNotes(name: "Example\u{1B}[2J", installedVersion: "1.0\r", availableVersion: "2.0", content: "- Safe\n\u{1B}[31mnot terminal formatting", sourceURL: "https://example.test/\u{1B}[8m", coverage: "targetOnly")
        let output = HomebrewRenderer.show(notes, full: true)

        XCTAssertFalse(output.unicodeScalars.contains { $0 == "\u{1B}" || $0 == "\r" })
        XCTAssertTrue(output.contains("Safe"))
        XCTAssertTrue(output.contains("not terminal formatting"))
    }

    func testReleaseNotesRendererPreservesMarkdownBlocks() {
        let notes = HomebrewReleaseNotes(name: "example", installedVersion: "1.0", availableVersion: "2.0", content: "## Bug fixes\n- Fix an important issue\n\n## Install example\n```sh\ncurl example\n```\n\n## Download example\n| File | Platform |\n| --- | --- |", sourceURL: "https://example.test/release", coverage: "targetOnly")

        let output = HomebrewRenderer.show(notes, full: true)
        XCTAssertTrue(output.contains("Bug fixes"))
        XCTAssertTrue(output.contains("Fix an important issue"))
        XCTAssertTrue(output.contains("curl example"))
        XCTAssertTrue(output.contains("File"))
        XCTAssertTrue(output.contains("Platform"))
    }

    func testTerminalSanitizerRemovesWholeEscapeSequences() {
        let text = "safe\u{1B}[31mcolored\u{1B}]8;;https://attacker.example\u{7}link\u{1B}Ppayload\u{1B}\\done\u{1B}Xhidden\u{1B}\\after\u{9B}2J"

        XCTAssertEqual(text.terminalText, "safecoloredlinkdoneafter")
        XCTAssertEqual("one\n\u{1B}]0;title\u{7}two".terminalInline, "one two")
        XCTAssertEqual("one\u{9D}title\u{1B}\\two".terminalText, "onetwo")
    }

    func testTableFormatterAlignsColumnsToWidestCell() {
        let rows = TableFormatter.rows([
            ["a", "1.0 -> 2.0", "homebrew", "/opt/homebrew"],
            ["clang-format", "23.1.0 -> 23.1.1", "homebrew", "/opt/homebrew"],
        ])
        XCTAssertEqual(rows[1], "clang-format  23.1.0 -> 23.1.1  homebrew  /opt/homebrew")
        // Every row's "homebrew" column must start at the same offset — the whole point of not using
        // raw tabs, whose alignment depends on the terminal's fixed stops rather than actual content
        // width.
        let offsets = rows.map { $0.range(of: "homebrew")!.lowerBound.utf16Offset(in: $0) }
        XCTAssertEqual(offsets[0], offsets[1])
    }

    func testRefreshRendererAlignsProviderStatusColumn() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let finishedAt = Date(timeIntervalSince1970: 1_001)
        // "npm-global" and "homebrew-release-notes" differ by well over one terminal tab stop; a raw
        // tab join would misalign every status column after the shortest provider name.
        let summary = RefreshSummary(startedAt: startedAt, finishedAt: finishedAt, status: .success, discoveredCount: 0, addedCount: 0, changedCount: 0, unchangedCount: 0, inactiveCount: 0, providerResults: [
            ProviderRefreshResult(provider: .npmGlobal, status: .success, startedAt: startedAt, finishedAt: finishedAt),
            ProviderRefreshResult(provider: .homebrewReleaseNotes, status: .success, startedAt: startedAt, finishedAt: finishedAt),
        ], warningCount: 0)
        let lines = RefreshRenderer.humanReadable(summary).split(separator: "\n").map(String.init)
        let providerLines = lines.filter { $0.hasPrefix("npm-global") || $0.hasPrefix("homebrew-release-notes") }
        XCTAssertEqual(providerLines.count, 2)
        let statusOffsets = providerLines.map { $0.range(of: "success")!.lowerBound.utf16Offset(in: $0) }
        XCTAssertEqual(statusOffsets[0], statusOffsets[1])
    }

    func testTableFormatterDoesNotPadTheLastColumn() {
        let rows = TableFormatter.rows([["short", "x"], ["a much longer name", "y"]])
        XCTAssertFalse(rows[0].hasSuffix(" "))
        XCTAssertFalse(rows[1].hasSuffix(" "))
    }

    func testTableFormatterHandlesEmptyAndRaggedInput() {
        XCTAssertEqual(TableFormatter.rows([]), [])
        XCTAssertEqual(TableFormatter.rows([["only"]]), ["only"])
    }

    func testTableFormatterAccountsForWideCharacterDisplayWidth() {
        XCTAssertEqual("日本語アプリ".terminalDisplayWidth, 12)
        XCTAssertEqual("a".terminalDisplayWidth, 1)

        // "日本語アプリ" is 6 `Character`s but renders as 12 terminal columns; padding by
        // `String.count` alone would under-pad this column by 6 columns and misalign "homebrew"
        // in every other row. A plain string-index offset can't detect that misalignment (each
        // wide character is still just one index position), so compare visual display width of
        // everything before "homebrew" instead of its string-index offset.
        let rows = TableFormatter.rows([
            ["日本語アプリ", "1.0 -> 2.0", "homebrew"],
            ["a", "1.0 -> 2.0", "homebrew"],
        ])
        let visualOffsets = rows.map { row -> Int in
            let range = row.range(of: "homebrew")!
            return String(row[..<range.lowerBound]).terminalDisplayWidth
        }
        XCTAssertEqual(visualOffsets[0], visualOffsets[1])
    }

    func testTerminalSanitizerRemovesBidiAndZeroWidthControls() {
        XCTAssertEqual("visible \u{202E}text\u{2066}!\u{200B}\u{200D}\u{FEFF}".terminalText, "visible text!")
        XCTAssertEqual("cafe \u{2615} \u{1F642}".terminalText, "cafe \u{2615} \u{1F642}")
    }
}
