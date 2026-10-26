import Darwin
import Foundation
import XCTest
@testable import SiftCore

final class ManagedPackageTests: XCTestCase {
    func testManagedPackageUpdatesAreUnifiedAndFailedProviderRetainsCachedData() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let firstDate = Date(timeIntervalSince1970: 1_000)
        let inventory = ManagedPackageInventory(provider: .npmGlobal, scopes: [
            ManagedPackageScope(scope: "/opt/homebrew", packages: [ManagedPackage(name: "typescript", installedVersion: "5.7.0", availableVersion: "5.8.0")]),
        ])
        _ = try database.applyRefresh(RefreshPersistenceInput(startedAt: firstDate, finishedAt: firstDate, nativeInventory: NativeInventoryResult(applications: []), homebrewInventory: HomebrewInventory(prefixes: []), targetResults: [:], releaseNoteResults: [:], managedPackageInventories: [inventory], providerResults: refreshInput(at: firstDate).providerResults))

        XCTAssertEqual(try database.updates(now: firstDate), [UnifiedUpdate(provider: "npm-global", scope: "/opt/homebrew", name: "typescript", installedVersion: "5.7.0", availableVersion: "5.8.0", freshness: .current, dataAsOf: firstDate)])
        XCTAssertEqual(try database.dashboard(now: firstDate).data.availableUpdateCount, 1)

        let failedDate = Date(timeIntervalSince1970: 2_000)
        var statuses = Dictionary(uniqueKeysWithValues: RefreshProvider.allCases.map { ($0, ProviderRefreshStatus.success) })
        statuses[.npmGlobal] = .failure
        _ = try database.applyRefresh(refreshInput(at: failedDate, providerStatuses: statuses))

        XCTAssertEqual(try database.updates(now: failedDate).map(\.freshness), [.stale])
        XCTAssertEqual(try database.dashboard(now: failedDate).data.providerResults.first(where: { $0.provider == .npmGlobal })?.status, .failure)
    }

    func testEveryManagedProviderReportsCurrentUpdatesAfterASuccessfulRefresh() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let date = Date(timeIntervalSince1970: 1_000)
        let inventories = RefreshProvider.managedPackageProviders.map { provider in
            ManagedPackageInventory(provider: provider, scopes: [
                ManagedPackageScope(scope: "/scope", packages: [ManagedPackage(name: "pkg-\(provider.rawValue)", installedVersion: "1.0", availableVersion: "2.0")]),
            ])
        }
        _ = try database.applyRefresh(RefreshPersistenceInput(startedAt: date, finishedAt: date, nativeInventory: NativeInventoryResult(applications: []), homebrewInventory: HomebrewInventory(prefixes: []), targetResults: [:], releaseNoteResults: [:], managedPackageInventories: inventories, providerResults: refreshInput(at: date).providerResults))

        let updates = try database.updates(includeAll: true, now: date)
        XCTAssertEqual(updates.count, RefreshProvider.managedPackageProviders.count)
        XCTAssertEqual(updates.filter { $0.freshness != .current }.map(\.provider), [], "cargo, Steam, and MacPorts updates were reported stale right after a successful refresh")
    }

    func testManagedPackageInventoryAcceptedForPartialProviderResult() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let date = Date(timeIntervalSince1970: 1_000)
        // A provider that scanned one npm prefix successfully but failed on another must
        // still persist the successful prefix's data, so its status is `.partial`, not `.failure`.
        let inventory = ManagedPackageInventory(provider: .npmGlobal, scopes: [
            ManagedPackageScope(scope: "/opt/homebrew", packages: [ManagedPackage(name: "typescript", installedVersion: "5.7.0", availableVersion: "5.8.0")]),
        ])
        var statuses = Dictionary(uniqueKeysWithValues: RefreshProvider.allCases.map { ($0, ProviderRefreshStatus.success) })
        statuses[.npmGlobal] = .partial
        let providerResults = RefreshProvider.allCases.map { provider in
            ProviderRefreshResult(provider: provider, status: statuses[provider]!, startedAt: date, finishedAt: date, dataAsOf: statuses[provider] == .success ? date : nil)
        }
        _ = try database.applyRefresh(RefreshPersistenceInput(startedAt: date, finishedAt: date, nativeInventory: NativeInventoryResult(applications: []), homebrewInventory: HomebrewInventory(prefixes: []), targetResults: [:], releaseNoteResults: [:], managedPackageInventories: [inventory], providerResults: providerResults))

        XCTAssertEqual(try database.updates(now: date), [UnifiedUpdate(provider: "npm-global", scope: "/opt/homebrew", name: "typescript", installedVersion: "5.7.0", availableVersion: "5.8.0", freshness: .stale, dataAsOf: date)])
    }

    func testManagedPackageAvailableVersionSurvivesATransientOutdatedCheckFailure() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let firstDate = Date(timeIntervalSince1970: 1_000)
        let known = ManagedPackageInventory(provider: .npmGlobal, scopes: [
            ManagedPackageScope(scope: "/opt/homebrew", packages: [ManagedPackage(name: "typescript", installedVersion: "5.7.0", availableVersion: "5.8.0")]),
        ])
        _ = try database.applyRefresh(RefreshPersistenceInput(startedAt: firstDate, finishedAt: firstDate, nativeInventory: NativeInventoryResult(applications: []), homebrewInventory: HomebrewInventory(prefixes: []), targetResults: [:], releaseNoteResults: [:], managedPackageInventories: [known], providerResults: refreshInput(at: firstDate).providerResults))
        XCTAssertEqual(try database.updates(now: firstDate).map(\.availableVersion), ["5.8.0"])

        // The installed version is unchanged but this round's outdated check failed to report an
        // available version; the previously known value must not be overwritten with nil.
        let secondDate = Date(timeIntervalSince1970: 2_000)
        let unknown = ManagedPackageInventory(provider: .npmGlobal, scopes: [
            ManagedPackageScope(scope: "/opt/homebrew", packages: [ManagedPackage(name: "typescript", installedVersion: "5.7.0", availableVersion: nil)], outdatedDataComplete: false),
        ])
        var statuses = Dictionary(uniqueKeysWithValues: RefreshProvider.allCases.map { ($0, ProviderRefreshStatus.success) })
        statuses[.npmGlobal] = .partial
        let providerResults = RefreshProvider.allCases.map { provider in
            ProviderRefreshResult(provider: provider, status: statuses[provider]!, startedAt: secondDate, finishedAt: secondDate, dataAsOf: statuses[provider] == .success ? secondDate : nil)
        }
        _ = try database.applyRefresh(RefreshPersistenceInput(startedAt: secondDate, finishedAt: secondDate, nativeInventory: NativeInventoryResult(applications: []), homebrewInventory: HomebrewInventory(prefixes: []), targetResults: [:], releaseNoteResults: [:], managedPackageInventories: [unknown], providerResults: providerResults))

        XCTAssertEqual(try database.updates(now: secondDate).map(\.availableVersion), ["5.8.0"])
    }

    func testManagedPackageAvailableVersionClearsWhenOutdatedCheckConfirmsNoUpdate() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let firstDate = Date(timeIntervalSince1970: 1_000)
        let known = ManagedPackageInventory(provider: .npmGlobal, scopes: [
            ManagedPackageScope(scope: "/opt/homebrew", packages: [ManagedPackage(name: "typescript", installedVersion: "5.7.0", availableVersion: "5.8.0")]),
        ])
        _ = try database.applyRefresh(RefreshPersistenceInput(startedAt: firstDate, finishedAt: firstDate, nativeInventory: NativeInventoryResult(applications: []), homebrewInventory: HomebrewInventory(prefixes: []), targetResults: [:], releaseNoteResults: [:], managedPackageInventories: [known], providerResults: refreshInput(at: firstDate).providerResults))
        XCTAssertEqual(try database.updates(now: firstDate).map(\.availableVersion), ["5.8.0"])

        // The user upgraded to 5.9.0 outside Sift. This round's outdated check succeeded and
        // confirms nothing is pending (availableVersion nil), so the stale cached "5.8.0" must be
        // cleared rather than preserved, or `sift updates` would report a phantom downgrade.
        let secondDate = Date(timeIntervalSince1970: 2_000)
        let resolved = ManagedPackageInventory(provider: .npmGlobal, scopes: [
            ManagedPackageScope(scope: "/opt/homebrew", packages: [ManagedPackage(name: "typescript", installedVersion: "5.9.0", availableVersion: nil)]),
        ])
        _ = try database.applyRefresh(RefreshPersistenceInput(startedAt: secondDate, finishedAt: secondDate, nativeInventory: NativeInventoryResult(applications: []), homebrewInventory: HomebrewInventory(prefixes: []), targetResults: [:], releaseNoteResults: [:], managedPackageInventories: [resolved], providerResults: refreshInput(at: secondDate).providerResults))

        XCTAssertEqual(try database.updates(now: secondDate), [])
    }

    func testNPMGlobalProviderIsolatesFailedInstallationWithoutDiscardingOthers() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sift-npm-fake-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let workingDirectory = root.appending(path: "working", directoryHint: .isDirectory)
        let brokenDirectory = root.appending(path: "broken", directoryHint: .isDirectory)
        try writeExecutable(at: workingDirectory.appending(path: "npm"), contents: """
            #!/bin/sh
            case "$1" in
                prefix) echo "/fake/prefixA" ;;
                list) printf '{"dependencies":{"widget":{"version":"1.0.0"}}}' ;;
                outdated) printf '{}' ;;
                *) exit 1 ;;
            esac
            """)
        try writeExecutable(at: brokenDirectory.appending(path: "npm"), contents: """
            #!/bin/sh
            exit 1
            """)

        let provider = NPMGlobalProvider(environment: [:], standardDirectories: [workingDirectory.path, brokenDirectory.path])
        let inventory = provider.discover()

        XCTAssertEqual(inventory.prefixes.map(\.prefix), ["/fake/prefixA"])
        XCTAssertEqual(inventory.prefixes.first?.packages, [NPMGlobalPackage(name: "widget", installedVersion: "1.0.0")])
        XCTAssertEqual(inventory.warnings.count, 1)
    }

    func testNPMGlobalProviderSkipsMalformedInventoryEntryWithoutDiscardingOtherPackages() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sift-npm-inventory-shape-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        // "widget" has no "version" field at all (e.g. a broken symlink or an "invalid"/
        // "extraneous" global install), alongside a normal, well-formed "gadget" entry. The
        // malformed entry must not discard gadget from the whole prefix's inventory.
        try writeExecutable(at: directory.appending(path: "npm"), contents: """
            #!/bin/sh
            case "$1" in
                prefix) echo "/fake/prefixA" ;;
                list) printf '{"dependencies":{"widget":{},"gadget":{"version":"2.0.0"}}}' ;;
                outdated) printf '{}' ;;
                *) exit 1 ;;
            esac
            """)

        let provider = NPMGlobalProvider(environment: [:], standardDirectories: [directory.path])
        let inventory = provider.discover()

        XCTAssertEqual(inventory.prefixes.first?.packages, [NPMGlobalPackage(name: "gadget", installedVersion: "2.0.0")])
        XCTAssertTrue(inventory.warnings.first?.contains("widget") ?? false)
    }

    func testNPMGlobalProviderMarksOutdatedIncompleteWhenStderrReportsAPackageError() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sift-npm-stderr-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        // npm can print "npm error" to stderr for one package that failed a registry check while
        // still exiting 0/1 and returning valid JSON for every package it did check — the failed
        // package is simply missing from the JSON, indistinguishable from "no update available."
        // A previously cached update for "widget" must not be silently cleared by this.
        try writeExecutable(at: directory.appending(path: "npm"), contents: """
            #!/bin/sh
            case "$1" in
                prefix) echo "/fake/prefixA" ;;
                list) printf '{"dependencies":{"widget":{"version":"1.0.0"},"gadget":{"version":"2.0.0"}}}' ;;
                outdated)
                    echo "npm error network timeout while checking widget" 1>&2
                    printf '{"gadget":{"current":"2.0.0","wanted":"2.1.0","latest":"2.1.0"}}'
                    ;;
                *) exit 1 ;;
            esac
            """)

        let provider = NPMGlobalProvider(environment: [:], standardDirectories: [directory.path])
        let inventory = provider.discover()

        XCTAssertEqual(inventory.prefixes.first?.outdatedComplete, false)
        XCTAssertEqual(inventory.prefixes.first?.updateCandidates.map(\.name), ["gadget"])
        XCTAssertTrue(inventory.warnings.contains { $0.contains("widget") })
    }

    func testRefreshCoordinatorPersistsPartialNPMResultWithoutThrowing() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)

        let root = FileManager.default.temporaryDirectory.appending(path: "sift-refresh-npm-fake-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let workingDirectory = root.appending(path: "working", directoryHint: .isDirectory)
        let brokenDirectory = root.appending(path: "broken", directoryHint: .isDirectory)
        try writeExecutable(at: workingDirectory.appending(path: "npm"), contents: """
            #!/bin/sh
            case "$1" in
                prefix) echo "/fake/prefixA" ;;
                list) printf '{"dependencies":{"widget":{"version":"1.0.0"}}}' ;;
                outdated) printf '{}' ;;
                *) exit 1 ;;
            esac
            """)
        try writeExecutable(at: brokenDirectory.appending(path: "npm"), contents: """
            #!/bin/sh
            exit 1
            """)

        // A partial npm result must not fail Database's provider-result validation, which is what
        // this reproduces: RefreshCoordinator previously set a non-nil dataAsOf for `.partial`
        // results, and Database requires dataAsOf to be nil for any non-`.success` status.
        let coordinator = RefreshCoordinator(
            database: database,
            nativeProvider: NativeApplicationProvider(roots: [], includeSpotlight: false),
            homebrewProvider: HomebrewProvider(environment: [:], standardDirectories: []),
            npmGlobalProvider: NPMGlobalProvider(environment: [:], standardDirectories: [workingDirectory.path, brokenDirectory.path]),
            uvToolProvider: UVToolProvider(environment: [:], standardDirectories: []), steamProvider: .absent, macPortsProvider: .absent, cargoProvider: .absent
        )
        let summary = try coordinator.refresh()

        XCTAssertEqual(summary.status, .partial)
        let npmResult = summary.providerResults.first { $0.provider == .npmGlobal }
        XCTAssertEqual(npmResult?.status, .partial)
        XCTAssertNil(npmResult?.dataAsOf)
        XCTAssertEqual(npmResult?.warningCount, 1)
    }

    func testRefreshCoordinatorRetainsCachedNPMDataWhenNPMIsUninstalled() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)

        let root = FileManager.default.temporaryDirectory.appending(path: "sift-refresh-npm-uninstall-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let workingDirectory = root.appending(path: "working", directoryHint: .isDirectory)
        try writeExecutable(at: workingDirectory.appending(path: "npm"), contents: """
            #!/bin/sh
            case "$1" in
                prefix) echo "/fake/prefixA" ;;
                list) printf '{"dependencies":{"widget":{"version":"1.0.0"}}}' ;;
                outdated) printf '{"widget":{"current":"1.0.0","wanted":"1.1.0","latest":"1.1.0"}}' ;;
                *) exit 1 ;;
            esac
            """)
        func coordinator(standardDirectories: [String]) -> RefreshCoordinator {
            RefreshCoordinator(
                database: database,
                nativeProvider: NativeApplicationProvider(roots: [], includeSpotlight: false),
                homebrewProvider: HomebrewProvider(environment: [:], standardDirectories: []),
                npmGlobalProvider: NPMGlobalProvider(environment: [:], standardDirectories: standardDirectories),
                uvToolProvider: UVToolProvider(environment: [:], standardDirectories: []), steamProvider: .absent, macPortsProvider: .absent, cargoProvider: .absent
            )
        }

        let firstSummary = try coordinator(standardDirectories: [workingDirectory.path]).refresh(now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(firstSummary.status, .success)
        XCTAssertEqual(try database.updates(now: Date(timeIntervalSince1970: 1_000)).map(\.availableVersion), ["1.1.0"])

        // npm is fully uninstalled: no executable is found and there is nothing to warn about,
        // which must not be mistaken for "checked and found nothing outdated" — the cached
        // update has to be retained (marked stale), not silently dropped or kept as "current".
        let secondSummary = try coordinator(standardDirectories: []).refresh(now: Date(timeIntervalSince1970: 200_000))
        XCTAssertEqual(secondSummary.status, .partial)
        let npmResult = secondSummary.providerResults.first { $0.provider == .npmGlobal }
        XCTAssertEqual(npmResult?.status, .partial)
        XCTAssertNil(npmResult?.dataAsOf)
        XCTAssertTrue(npmResult?.message?.contains("retained") == true)
        let updates = try database.updates(now: Date(timeIntervalSince1970: 200_000))
        XCTAssertEqual(updates.map(\.availableVersion), ["1.1.0"])
        XCTAssertEqual(updates.map(\.freshness), [.stale])
    }

    func testRefreshCoordinatorRetainsCachedNPMDataWhenListAndOutdatedDisagree() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)

        let root = FileManager.default.temporaryDirectory.appending(path: "sift-refresh-npm-mismatch-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let workingDirectory = root.appending(path: "working", directoryHint: .isDirectory)
        let npmURL = workingDirectory.appending(path: "npm")
        try writeExecutable(at: npmURL, contents: """
            #!/bin/sh
            case "$1" in
                prefix) echo "/fake/prefixA" ;;
                list) printf '{"dependencies":{"widget":{"version":"1.0.0"}}}' ;;
                outdated) printf '{"widget":{"current":"1.0.0","wanted":"1.1.0","latest":"1.1.0"}}' ;;
                *) exit 1 ;;
            esac
            """)
        let coordinator = RefreshCoordinator(
            database: database,
            nativeProvider: NativeApplicationProvider(roots: [], includeSpotlight: false),
            homebrewProvider: HomebrewProvider(environment: [:], standardDirectories: []),
            npmGlobalProvider: NPMGlobalProvider(environment: [:], standardDirectories: [workingDirectory.path]),
            uvToolProvider: UVToolProvider(environment: [:], standardDirectories: []), steamProvider: .absent, macPortsProvider: .absent, cargoProvider: .absent
        )

        let firstSummary = try coordinator.refresh(now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(firstSummary.status, .success)
        XCTAssertEqual(try database.updates(now: Date(timeIntervalSince1970: 1_000)).map(\.availableVersion), ["1.1.0"])

        // `npm list` and `npm outdated` are separate subprocess calls; here `outdated` reports a
        // different installed version (0.9.0) than `list` just reported (1.0.0) for the same
        // package, simulating another process changing it mid-refresh. That mismatch must not be
        // read as "confirmed not outdated" — the previously cached 1.1.0 must survive, not be
        // cleared to nil or replaced by the mismatched candidate's 2.0.0.
        try writeExecutable(at: npmURL, contents: """
            #!/bin/sh
            case "$1" in
                prefix) echo "/fake/prefixA" ;;
                list) printf '{"dependencies":{"widget":{"version":"1.0.0"}}}' ;;
                outdated) printf '{"widget":{"current":"0.9.0","wanted":"2.0.0","latest":"2.0.0"}}' ;;
                *) exit 1 ;;
            esac
            """)
        _ = try coordinator.refresh(now: Date(timeIntervalSince1970: 200_000))
        let updates = try database.updates(now: Date(timeIntervalSince1970: 200_000))
        XCTAssertEqual(updates.map(\.availableVersion), ["1.1.0"])
    }

    func testRefreshCoordinatorVersionMismatchOnOnePackageDoesNotBlockAnotherPackagesUpdate() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)

        let root = FileManager.default.temporaryDirectory.appending(path: "sift-refresh-npm-partial-mismatch-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let workingDirectory = root.appending(path: "working", directoryHint: .isDirectory)
        let npmURL = workingDirectory.appending(path: "npm")
        try writeExecutable(at: npmURL, contents: """
            #!/bin/sh
            case "$1" in
                prefix) echo "/fake/prefixA" ;;
                list) printf '{"dependencies":{"widget":{"version":"1.0.0"},"gadget":{"version":"1.0.0"}}}' ;;
                outdated) printf '{"widget":{"current":"1.0.0","wanted":"1.1.0","latest":"1.1.0"}}' ;;
                *) exit 1 ;;
            esac
            """)
        let coordinator = RefreshCoordinator(
            database: database,
            nativeProvider: NativeApplicationProvider(roots: [], includeSpotlight: false),
            homebrewProvider: HomebrewProvider(environment: [:], standardDirectories: []),
            npmGlobalProvider: NPMGlobalProvider(environment: [:], standardDirectories: [workingDirectory.path]),
            uvToolProvider: UVToolProvider(environment: [:], standardDirectories: []), steamProvider: .absent, macPortsProvider: .absent, cargoProvider: .absent
        )

        let firstSummary = try coordinator.refresh(now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(firstSummary.status, .success)
        XCTAssertEqual(try database.updates(now: Date(timeIntervalSince1970: 1_000)).map(\.name), ["widget"])

        // Second round: widget's outdated entry now disagrees with `list` on its installed version
        // (the same mismatch as above), but gadget gets a brand-new, internally consistent update.
        // The mismatch is specific to widget and must not prevent gadget's legitimate update from
        // being recorded — this is what distinguishes per-package tracking from a single scope-wide
        // "outdated data is complete" flag, which would block both.
        try writeExecutable(at: npmURL, contents: """
            #!/bin/sh
            case "$1" in
                prefix) echo "/fake/prefixA" ;;
                list) printf '{"dependencies":{"widget":{"version":"1.0.0"},"gadget":{"version":"1.0.0"}}}' ;;
                outdated) printf '{"widget":{"current":"0.9.0","wanted":"2.0.0","latest":"2.0.0"},"gadget":{"current":"1.0.0","wanted":"1.2.0","latest":"1.2.0"}}' ;;
                *) exit 1 ;;
            esac
            """)
        _ = try coordinator.refresh(now: Date(timeIntervalSince1970: 200_000))
        let updates = try database.updates(now: Date(timeIntervalSince1970: 200_000))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: updates.map { ($0.name, $0.availableVersion) }), ["widget": "1.1.0", "gadget": "1.2.0"])
    }

    func testUVToolProviderIsolatesFailedInstallationWithoutDiscardingOthers() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sift-uv-fake-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let workingDirectory = root.appending(path: "working", directoryHint: .isDirectory)
        let brokenDirectory = root.appending(path: "broken", directoryHint: .isDirectory)
        try writeExecutable(at: workingDirectory.appending(path: "uv"), contents: """
            #!/bin/sh
            if [ "$1 $2" = "tool dir" ]; then
                echo "/fake/tools"
            elif [ "$1 $2" = "tool list" ]; then
                case "$*" in
                    *--outdated*) printf '' ;;
                    *) printf 'widget v1.0.0 [CPython 3.12.0] (/fake/tools/widget)\\n- widget (/fake/bin/widget)\\n' ;;
                esac
            else
                exit 1
            fi
            """)
        try writeExecutable(at: brokenDirectory.appending(path: "uv"), contents: """
            #!/bin/sh
            exit 1
            """)

        let provider = UVToolProvider(environment: [:], standardDirectories: [workingDirectory.path, brokenDirectory.path])
        let inventory = provider.discover()

        XCTAssertEqual(inventory.installations.map(\.toolDirectory), ["/fake/tools"])
        XCTAssertEqual(inventory.installations.first?.tools.map(\.name), ["widget"])
        XCTAssertEqual(inventory.installations.first?.outdatedTools, [])
        XCTAssertEqual(inventory.warnings.count, 1)
    }

    func testRefreshCoordinatorRetainsCachedUVDataWhenListAndOutdatedDisagree() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)

        let root = FileManager.default.temporaryDirectory.appending(path: "sift-refresh-uv-mismatch-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let workingDirectory = root.appending(path: "working", directoryHint: .isDirectory)
        let uvURL = workingDirectory.appending(path: "uv")
        try writeExecutable(at: uvURL, contents: """
            #!/bin/sh
            if [ "$1 $2" = "tool dir" ]; then
                echo "/fake/tools"
            elif [ "$1 $2" = "tool list" ]; then
                case "$*" in
                    *--outdated*) printf 'widget v1.0.0 [CPython 3.12.0] [latest: 1.1.0] (/fake/tools/widget)\\n- widget (/fake/bin/widget)\\n' ;;
                    *) printf 'widget v1.0.0 [CPython 3.12.0] (/fake/tools/widget)\\n- widget (/fake/bin/widget)\\n' ;;
                esac
            else
                exit 1
            fi
            """)
        let coordinator = RefreshCoordinator(
            database: database,
            nativeProvider: NativeApplicationProvider(roots: [], includeSpotlight: false),
            homebrewProvider: HomebrewProvider(environment: [:], standardDirectories: []),
            npmGlobalProvider: NPMGlobalProvider(environment: [:], standardDirectories: []),
            uvToolProvider: UVToolProvider(environment: [:], standardDirectories: [workingDirectory.path]), steamProvider: .absent, macPortsProvider: .absent, cargoProvider: .absent
        )

        let firstSummary = try coordinator.refresh(now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(firstSummary.status, .success)
        XCTAssertEqual(try database.updates(now: Date(timeIntervalSince1970: 1_000)).map(\.availableVersion), ["1.1.0"])

        // Same "list" vs "outdated" consistency guard as the npm test above: `tool list --outdated`
        // now reports a different installed version (0.9.0) than plain `tool list` just reported
        // (1.0.0), which must not overwrite the cached 1.1.0 with the mismatched candidate's 2.0.0.
        try writeExecutable(at: uvURL, contents: """
            #!/bin/sh
            if [ "$1 $2" = "tool dir" ]; then
                echo "/fake/tools"
            elif [ "$1 $2" = "tool list" ]; then
                case "$*" in
                    *--outdated*) printf 'widget v0.9.0 [CPython 3.12.0] [latest: 2.0.0] (/fake/tools/widget)\\n- widget (/fake/bin/widget)\\n' ;;
                    *) printf 'widget v1.0.0 [CPython 3.12.0] (/fake/tools/widget)\\n- widget (/fake/bin/widget)\\n' ;;
                esac
            else
                exit 1
            fi
            """)
        _ = try coordinator.refresh(now: Date(timeIntervalSince1970: 200_000))
        let updates = try database.updates(now: Date(timeIntervalSince1970: 200_000))
        XCTAssertEqual(updates.map(\.availableVersion), ["1.1.0"])
    }

    func testUVToolProviderParsesDocumentedToolListOutput() throws {
        let output = "ruff v0.12.0 [required: ruff>=0.11] [CPython 3.13.3] (/Users/example/.local/share/uv/tools/ruff)\n- ruff (/Users/example/.local/bin/ruff)\nblack v25.1.0 [CPython 3.12.9] (/Users/example/.local/share/uv/tools/black)\n- black (/Users/example/.local/bin/black)\n- blackd (/Users/example/.local/bin/blackd)\n"

        let tools = try UVToolProvider.parseToolList(Data(output.utf8), outdated: false)
        XCTAssertEqual(tools.map(\.name), ["black", "ruff"])
        XCTAssertEqual(tools.last?.versionSpecifier, "ruff>=0.11")
        XCTAssertEqual(tools.first?.entrypoints.map(\.name), ["black", "blackd"])
    }

    func testUVToolProviderRejectsMalformedToolListOutput() {
        let malformed = "ruff v0.12.0 [CPython 3.13.3] (/Users/example/tools/ruff)\n- ruff relative/path\n"
        XCTAssertThrowsError(try UVToolProvider.parseToolList(Data(malformed.utf8), outdated: false))
    }

    func testUVToolProviderParsesOutdatedToolOutput() throws {
        let output = "ruff v0.12.0 [required: ruff] [CPython 3.13.3] [latest: 0.13.0] (/Users/example/tools/ruff)\n- ruff (/Users/example/bin/ruff)\n"
        let tools = try UVToolProvider.parseToolList(Data(output.utf8), outdated: true)
        XCTAssertEqual(tools.first?.latestVersion, "0.13.0")
    }
}
