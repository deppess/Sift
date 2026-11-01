import Darwin
import Foundation
import XCTest
@testable import SiftCore

final class RefreshDatabaseTests: XCTestCase {
    func testEmptyDatabaseHasUnknownFreshness() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)

        let dashboard = try database.dashboard(now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(dashboard.schemaVersion, 1)
        XCTAssertNil(dashboard.lastAttemptAt)
        XCTAssertNil(dashboard.dataAsOf)
        XCTAssertEqual(dashboard.freshness, .unknown)
        XCTAssertEqual(dashboard.latestRefreshStatus, .never)
    }

    func testWritableDatabaseRefreshLockRejectsSecondWriter() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let first = try Database(url: url)
        XCTAssertThrowsError(try Database(url: url)) { error in
            guard case .refreshInProgress = error as? DatabaseError else { return XCTFail("Expected refresh lock error, got \(error)") }
        }
        _ = first
    }

    func testWritableDatabaseRejectsNonStickyWritableParent() throws {
        let directory = try temporaryDatabaseDirectory(mode: 0o777)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try Database(url: directory.appending(path: "sift.sqlite3"))) { error in
            guard case .unsafeFilesystemPath = error as? DatabaseError else { return XCTFail("Expected unsafe parent error, got \(error)") }
        }
    }

    func testWritableDatabaseAcceptsStickyParent() throws {
        let directory = try temporaryDatabaseDirectory(mode: 0o1777)
        let url = directory.appending(path: "sift.sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try Database(url: url)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    }

    func testDatabaseRejectsSymlinkAndHardlink() throws {
        let directory = try temporaryDatabaseDirectory(mode: 0o700)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "target.sqlite3")
        try Data().write(to: target)
        let symlink = directory.appending(path: "symlink.sqlite3")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        XCTAssertThrowsError(try Database(url: symlink))

        let hardlink = directory.appending(path: "hardlink.sqlite3")
        XCTAssertEqual(link(target.path, hardlink.path), 0)
        XCTAssertThrowsError(try Database(url: hardlink)) { error in
            guard case .invalidDatabasePath = error as? DatabaseError else { return XCTFail("Expected invalid database path, got \(error)") }
        }
    }

    func testRefreshLockRejectsHardlinkedFile() throws {
        let directory = try temporaryDatabaseDirectory(mode: 0o700)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "sift.sqlite3")
        let lock = url.appendingPathExtension("refresh.lock")
        try Data().write(to: lock)
        XCTAssertEqual(link(lock.path, directory.appending(path: "other.lock").path), 0)

        XCTAssertThrowsError(try Database(url: url)) { error in
            guard case .refreshLockUnavailable = error as? DatabaseError else { return XCTFail("Expected unsafe lock error, got \(error)") }
        }
    }

    func testFailedRefreshDoesNotAdvanceSuccessfulDataAge() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let successfulDate = Date(timeIntervalSince1970: 1_000)
        _ = try database.applyRefresh(refreshInput(at: successfulDate))
        _ = try database.applyRefresh(
            refreshInput(
                at: Date(timeIntervalSince1970: 2_000), providerStatuses: Dictionary(uniqueKeysWithValues: RefreshProvider.allCases.map { ($0, .failure) })))

        let dashboard = try database.dashboard(now: Date(timeIntervalSince1970: 2_100), staleAfter: 1_500)
        XCTAssertEqual(dashboard.lastAttemptAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(dashboard.dataAsOf, successfulDate)
        XCTAssertEqual(dashboard.latestRefreshStatus, .failure)
        XCTAssertEqual(dashboard.freshness, .current)
        XCTAssertEqual(dashboard.data.failedProviderCount, RefreshProvider.allCases.count)
    }

    func testDashboardDataAsOfIsTheNewestAvailableProviderData() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let olderDate = Date(timeIntervalSince1970: 1_000)
        _ = try database.applyRefresh(refreshInput(at: olderDate))

        // Every provider refreshes successfully again except homebrew-release-notes, which has a
        // transient failure this round; its previously cached dataAsOf (olderDate) is retained via
        // COALESCE. PROJECT.md specifies dataAsOf as the newest successfully collected data, so the
        // dashboard should reflect newerDate from the providers that did refresh, not be dragged
        // down by the one that didn't.
        let newerDate = Date(timeIntervalSince1970: 2_000)
        _ = try database.applyRefresh(refreshInput(at: newerDate, providerStatuses: [.homebrewReleaseNotes: .failure]))

        let dashboard = try database.dashboard(now: newerDate, staleAfter: 1_500)
        XCTAssertEqual(dashboard.dataAsOf, newerDate)
    }

    func testDashboardFreshnessReflectsProvidersThatHaveDataNotAllOrNothing() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let date = Date(timeIntervalSince1970: 1_000)
        // npm has never succeeded even once, but every other provider has; the dashboard must
        // still report current freshness from the providers that do have data, rather than
        // treating one perpetually-broken provider as blanking out everything else.
        _ = try database.applyRefresh(refreshInput(at: date, providerStatuses: [.npmGlobal: .failure]))

        let dashboard = try database.dashboard(now: date.addingTimeInterval(60), staleAfter: 1_500)
        XCTAssertEqual(dashboard.dataAsOf, date)
        XCTAssertEqual(dashboard.freshness, .current)
    }

    func testStalenessBeginsAtConfiguredBoundary() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let refreshedAt = Date(timeIntervalSince1970: 1_000)
        _ = try database.applyRefresh(refreshInput(at: refreshedAt))

        XCTAssertEqual(try database.dashboard(now: refreshedAt.addingTimeInterval(120), staleAfter: 120).freshness, .stale)
    }

    func testUnifiedPartialRefreshKeepsMissingNativeApplicationsActive() throws {
        let url = temporaryDatabaseURL()
        do {
            let database = try Database(url: url)
            let application = NativeApplication(
                path: "/Applications/Example.app", bundleIdentifier: "com.example.app", displayName: "Example", shortVersion: "1.0", buildVersion: nil,
                classification: .user, discoveryRoot: "/Applications")
            _ = try database.applyRefresh(
                refreshInput(
                    at: Date(timeIntervalSince1970: 1_000),
                    nativeInventory: NativeInventoryResult(applications: [application], scannedRoots: ["/Applications"], candidatePaths: [application.path])))

            let startedAt = Date(timeIntervalSince1970: 2_000)
            let finishedAt = Date(timeIntervalSince1970: 2_001)
            let results = RefreshProvider.allCases.map { provider in
                provider == .nativeApplications
                    ? ProviderRefreshResult(
                        provider: provider, status: .partial, message: "root unavailable", warningCount: 1, startedAt: startedAt, finishedAt: finishedAt)
                    : ProviderRefreshResult(provider: provider, status: .success, startedAt: startedAt, finishedAt: finishedAt, dataAsOf: finishedAt)
            }
            let summary = try database.applyRefresh(
                RefreshPersistenceInput(
                    startedAt: startedAt, finishedAt: finishedAt,
                    nativeInventory: NativeInventoryResult(applications: [], warnings: ["root unavailable"], complete: false, scannedRoots: ["/Applications"]),
                    homebrewInventory: HomebrewInventory(prefixes: []), targetResults: [:], releaseNoteResults: [:], providerResults: results))

            XCTAssertEqual(summary.status, .partial)
            XCTAssertEqual(summary.providerResults.count, RefreshProvider.allCases.count)
            XCTAssertEqual(try database.catalogItems(includeAll: true).first?.active, true)
            XCTAssertEqual(try database.dashboard(now: finishedAt).data.partialProviderCount, 1)
        }
        removeDatabase(at: url)
    }

    func testUnifiedRefreshRejectsReplayedCompletionTime() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let startedAt = Date(timeIntervalSince1970: 2_000)
        let finishedAt = Date(timeIntervalSince1970: 2_001)
        let results = RefreshProvider.allCases.map {
            ProviderRefreshResult(provider: $0, status: .success, startedAt: startedAt, finishedAt: finishedAt, dataAsOf: finishedAt)
        }
        let input = RefreshPersistenceInput(
            startedAt: startedAt, finishedAt: finishedAt, nativeInventory: NativeInventoryResult(applications: []),
            homebrewInventory: HomebrewInventory(prefixes: []), targetResults: [:], releaseNoteResults: [:], providerResults: results)

        _ = try database.applyRefresh(input)
        XCTAssertThrowsError(try database.applyRefresh(input)) { error in
            guard case .invalidRefreshInput = error as? DatabaseError else { return XCTFail("Expected refresh ordering error, got \(error)") }
        }
    }
}
