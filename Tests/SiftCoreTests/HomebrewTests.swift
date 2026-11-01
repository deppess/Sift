import Darwin
import Foundation
import Synchronization
import XCTest
@testable import SiftCore

final class HomebrewTests: XCTestCase {
    func testHomebrewReleaseNotesAreCachedByTargetVersion() throws {
        let url = temporaryDatabaseURL()
        do {
            let database = try Database(url: url)
            let notes = HomebrewReleaseNotes(
                name: "yazi", installedVersion: "25.5.31", availableVersion: "26.8.15", content: "## [v26.8.15]\n- Drag and drop",
                sourceURL: "https://example.test/changelog", coverage: "complete")
            let package = homebrewPackage(kind: .formula, name: "yazi")
            let key = HomebrewPackageKey(package)
            _ = try database.applyRefresh(
                refreshInput(
                    at: Date(timeIntervalSince1970: 1_000),
                    homebrewInventory: HomebrewInventory(prefixes: [
                        HomebrewPrefixInventory(prefix: package.prefix, packages: [package], complete: true, warnings: [])
                    ]), targetResults: [key: .resolved(HomebrewTarget(version: notes.availableVersion, sourceURL: notes.sourceURL))],
                    releaseNoteResults: [key: .resolved(notes)]))
            XCTAssertEqual(
                try database.homebrewReleaseNotes(
                    prefix: package.prefix, kind: package.kind, fullName: package.fullName, installedVersion: notes.installedVersion,
                    availableVersion: notes.availableVersion), notes)
        }
        removeDatabase(at: url)
    }

    func testHomebrewReleaseNotesKeepDistinctInstalledRangesForSameTarget() throws {
        let url = temporaryDatabaseURL()
        do {
            let database = try Database(url: url)
            let package = homebrewPackage(kind: .formula, name: "example")
            let first = HomebrewReleaseNotes(
                name: package.fullName, installedVersion: "1.0", availableVersion: "2.0", content: "from 1.0", sourceURL: "https://example.test/one",
                coverage: "repositoryCommits")
            let second = HomebrewReleaseNotes(
                name: package.fullName, installedVersion: "1.5", availableVersion: "2.0", content: "from 1.5", sourceURL: "https://example.test/two",
                coverage: "repositoryCommits")
            try database.storeReleaseNotes(first, prefix: package.prefix, kind: package.kind)
            try database.storeReleaseNotes(second, prefix: package.prefix, kind: package.kind)
            XCTAssertEqual(
                try database.homebrewReleaseNotes(
                    prefix: package.prefix, kind: package.kind, fullName: package.fullName, installedVersion: "1.0", availableVersion: "2.0"), first)
            XCTAssertEqual(
                try database.homebrewReleaseNotes(
                    prefix: package.prefix, kind: package.kind, fullName: package.fullName, installedVersion: "1.5", availableVersion: "2.0"), second)
        }
        removeDatabase(at: url)
    }

    func testCompleteHomebrewPrefixMarksMissingPackageAndArtifactInactive() throws {
        let url = temporaryDatabaseURL()
        do {
            let database = try Database(url: url)
            let cask = homebrewPackage(kind: .cask, name: "example", artifacts: ["/Applications/Example.app"])
            let first = HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: cask.prefix, packages: [cask], complete: true, warnings: [])])
            _ = try database.applyRefresh(
                refreshInput(
                    at: Date(timeIntervalSince1970: 1_000), homebrewInventory: first, targetResults: [HomebrewPackageKey(cask): .unavailable("not checked")]))

            let empty = HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: cask.prefix, packages: [], complete: true, warnings: [])])
            _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 2_000), homebrewInventory: empty))

            XCTAssertTrue(try database.catalogItems().isEmpty)
            XCTAssertEqual(try database.catalogItems(includeAll: true).first?.active, false)
        }
        removeDatabase(at: url)
    }

    func testPartialHomebrewPrefixRetainsPreviouslyObservedPackages() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let formula = homebrewPackage(kind: .formula, name: "example")
        _ = try database.applyRefresh(
            refreshInput(
                at: Date(timeIntervalSince1970: 1_000),
                homebrewInventory: HomebrewInventory(prefixes: [
                    HomebrewPrefixInventory(prefix: formula.prefix, packages: [formula], complete: true, warnings: [])
                ]), targetResults: [HomebrewPackageKey(formula): .unavailable("not checked")]))

        _ = try database.applyRefresh(
            refreshInput(
                at: Date(timeIntervalSince1970: 2_000),
                homebrewInventory: HomebrewInventory(prefixes: [
                    HomebrewPrefixInventory(prefix: formula.prefix, packages: [], complete: false, warnings: ["offline"])
                ])))

        XCTAssertEqual(try database.catalogItems().map(\.name), ["example"])
    }

    func testChangedCaskArtifactsStopSuppressingOldNativeApplication() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let native = NativeApplication(
            path: "/Applications/Example.app", bundleIdentifier: "com.example.app", displayName: "Example", shortVersion: "1.0", buildVersion: nil,
            classification: .user, discoveryRoot: "/Applications")
        _ = try database.applyRefresh(
            refreshInput(
                at: Date(timeIntervalSince1970: 1_000),
                nativeInventory: NativeInventoryResult(applications: [native], scannedRoots: ["/Applications"], candidatePaths: [native.path])))

        let cask = homebrewPackage(kind: .cask, name: "example", artifacts: [native.path])
        _ = try database.applyRefresh(
            refreshInput(
                at: Date(timeIntervalSince1970: 2_000),
                homebrewInventory: HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: cask.prefix, packages: [cask], complete: true, warnings: [])]),
                targetResults: [HomebrewPackageKey(cask): .unavailable("not checked")]))
        XCTAssertFalse(try database.catalogItems().contains { $0.kind == .nativeApp })

        let movedCask = homebrewPackage(kind: .cask, name: "example", artifacts: ["/Applications/Renamed.app"])
        _ = try database.applyRefresh(
            refreshInput(
                at: Date(timeIntervalSince1970: 3_000),
                homebrewInventory: HomebrewInventory(prefixes: [
                    HomebrewPrefixInventory(prefix: movedCask.prefix, packages: [movedCask], complete: true, warnings: [])
                ]), targetResults: [HomebrewPackageKey(movedCask): .unavailable("not checked")]))
        XCTAssertTrue(try database.catalogItems().contains { $0.kind == .nativeApp })
    }

    func testAutoUpdatingCaskIsPersistedWithUpdate() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let cask = homebrewPackage(kind: .cask, name: "example", autoUpdates: true)
        let key = HomebrewPackageKey(cask)
        _ = try database.applyRefresh(
            refreshInput(
                at: Date(timeIntervalSince1970: 1_000),
                homebrewInventory: HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: cask.prefix, packages: [cask], complete: true, warnings: [])]),
                targetResults: [key: .resolved(HomebrewTarget(version: "2.0", sourceURL: nil))]))

        XCTAssertEqual(try database.homebrewUpdates().first?.autoUpdates, true)
        XCTAssertEqual(try database.catalogItems().first?.autoUpdates, true)
    }

    func testDashboardCountsAutoUpdatingCasksSeparatelyFromUpdatesThatNeedAttention() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let formula = homebrewPackage(kind: .formula, name: "formula")
        let cask = homebrewPackage(kind: .cask, name: "cask", autoUpdates: true)
        let packages = [formula, cask]
        let targets = Dictionary(
            uniqueKeysWithValues: packages.map { package in
                (HomebrewPackageKey(package), HomebrewTargetResolution.resolved(HomebrewTarget(version: "2.0", sourceURL: nil)))
            })
        _ = try database.applyRefresh(
            refreshInput(
                at: Date(timeIntervalSince1970: 1_000),
                homebrewInventory: HomebrewInventory(prefixes: [
                    HomebrewPrefixInventory(prefix: formula.prefix, packages: packages, complete: true, warnings: [])
                ]), targetResults: targets))

        // An auto-updating cask doesn't need the user's attention, so it must not inflate the
        // main count; DashboardRenderer already has working display code for informationalUpdateCount.
        let dashboard = try database.dashboard()
        XCTAssertEqual(dashboard.data.availableUpdateCount, 1)
        XCTAssertEqual(dashboard.data.informationalUpdateCount, 1)
    }

    func testDashboardExcludesDependencyOnlyFormulaUpdatesFromTheMainCount() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let requested = homebrewPackage(kind: .formula, name: "requested")
        // A dependency-only formula (e.g. `readline`, pulled in solely to satisfy another formula's
        // requirement) is never installed on request; PROJECT.md's scope explicitly "defaults
        // dashboard output to requested formulae," so its own pending update must not count as
        // something the user needs to act on.
        let dependency = HomebrewPackage(
            prefix: "/opt/homebrew", kind: .formula, name: "dependency", fullName: "dependency", tap: "homebrew/core", ownership: .dependency,
            installedVersion: "1.0", sourceURL: nil, artifactPaths: [], autoUpdates: false)
        let packages = [requested, dependency]
        let targets = Dictionary(
            uniqueKeysWithValues: packages.map { package in
                (HomebrewPackageKey(package), HomebrewTargetResolution.resolved(HomebrewTarget(version: "2.0", sourceURL: nil)))
            })
        _ = try database.applyRefresh(
            refreshInput(
                at: Date(timeIntervalSince1970: 1_000),
                homebrewInventory: HomebrewInventory(prefixes: [
                    HomebrewPrefixInventory(prefix: requested.prefix, packages: packages, complete: true, warnings: [])
                ]), targetResults: targets))

        let dashboard = try database.dashboard()
        XCTAssertEqual(dashboard.data.availableUpdateCount, 1)
        XCTAssertEqual(dashboard.data.informationalUpdateCount, 0)
    }

    func testUpdatesHidesDependencyOnlyFormulaUpdatesUnlessIncludeAll() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let requested = homebrewPackage(kind: .formula, name: "requested")
        let dependency = HomebrewPackage(
            prefix: "/opt/homebrew", kind: .formula, name: "dependency", fullName: "dependency", tap: "homebrew/core", ownership: .dependency,
            installedVersion: "1.0", sourceURL: nil, artifactPaths: [], autoUpdates: false)
        let packages = [requested, dependency]
        let targets = Dictionary(
            uniqueKeysWithValues: packages.map { package in
                (HomebrewPackageKey(package), HomebrewTargetResolution.resolved(HomebrewTarget(version: "2.0", sourceURL: nil)))
            })
        _ = try database.applyRefresh(
            refreshInput(
                at: Date(timeIntervalSince1970: 1_000),
                homebrewInventory: HomebrewInventory(prefixes: [
                    HomebrewPrefixInventory(prefix: requested.prefix, packages: packages, complete: true, warnings: [])
                ]), targetResults: targets))

        XCTAssertEqual(try database.homebrewUpdates().map(\.name), ["requested"])
        XCTAssertEqual(try database.homebrewUpdates(includeAll: true).map(\.name).sorted(), ["dependency", "requested"])
        XCTAssertEqual(try database.updates().map(\.name), ["requested"])
        XCTAssertEqual(try database.updates(includeAll: true).map(\.name).sorted(), ["dependency", "requested"])
    }

    func testHomebrewUpdateFreshnessMarksOldEvidenceStale() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let formula = homebrewPackage(kind: .formula, name: "example")
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let key = HomebrewPackageKey(formula)
        let results = RefreshProvider.allCases.map {
            ProviderRefreshResult(provider: $0, status: .success, startedAt: observedAt, finishedAt: observedAt, dataAsOf: observedAt)
        }
        let input = RefreshPersistenceInput(
            startedAt: observedAt, finishedAt: observedAt, nativeInventory: NativeInventoryResult(applications: []),
            homebrewInventory: HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: formula.prefix, packages: [formula], complete: true, warnings: [])]
            ), targetResults: [key: .resolved(HomebrewTarget(version: "2.0", sourceURL: nil))], releaseNoteResults: [:], providerResults: results)
        _ = try database.applyRefresh(input)

        let update = try XCTUnwrap(database.homebrewUpdates(now: observedAt.addingTimeInterval(120), staleAfter: 120).first)
        XCTAssertEqual(update.freshness, .stale)
        XCTAssertEqual(update.dataAsOf, observedAt)
    }

    func testHomebrewProviderIsolatesFailedInstallationWithoutDiscardingOthers() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sift-brew-fake-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let workingDirectory = root.appending(path: "working", directoryHint: .isDirectory)
        let brokenDirectory = root.appending(path: "broken", directoryHint: .isDirectory)
        try writeExecutable(
            at: workingDirectory.appending(path: "brew"),
            contents: """
                #!/bin/sh
                case "$1" in
                    --prefix) echo "/fake/brewA" ;;
                    info) printf '{"formulae":[{"name":"widget","full_name":"widget","tap":"homebrew/core","installed":[{"version":"1.0.0","installed_on_request":true}],"urls":{"stable":{"url":"https://example.test/widget"}}}],"casks":[]}' ;;
                    outdated) printf '{"formulae":[],"casks":[]}' ;;
                    *) exit 1 ;;
                esac
                """)
        try writeExecutable(
            at: brokenDirectory.appending(path: "brew"),
            contents: """
                #!/bin/sh
                exit 1
                """)

        let provider = HomebrewProvider(environment: [:], standardDirectories: [workingDirectory.path, brokenDirectory.path])
        let inventory = provider.discover()

        XCTAssertEqual(inventory.availability, .detected)
        XCTAssertEqual(inventory.prefixes.count, 2)
        let working = inventory.prefixes.first { $0.prefix == "/fake/brewA" }
        XCTAssertEqual(working?.complete, true)
        XCTAssertEqual(working?.packages.map(\.name), ["widget"])
        let broken = inventory.prefixes.first { $0.prefix != "/fake/brewA" }
        XCTAssertEqual(broken?.complete, false)
        XCTAssertEqual(broken?.packages.count, 0)
    }

    func testHomebrewProviderHandlesFormulaWithoutStableURL() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sift-brew-nostable-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeExecutable(
            at: directory.appending(path: "brew"),
            contents: """
                #!/bin/sh
                case "$1" in
                    --prefix) echo "/fake/brewA" ;;
                    info) printf '{"formulae":[{"name":"widget","full_name":"widget","tap":"homebrew/core","installed":[{"version":"1.0.0","installed_on_request":true}]}],"casks":[]}' ;;
                    outdated) printf '{"formulae":[{"name":"widget","installed_versions":["1.0.0"],"current_version":"1.1.0"}],"casks":[]}' ;;
                    *) exit 1 ;;
                esac
                """)

        let provider = HomebrewProvider(environment: [:], standardDirectories: [directory.path])
        let inventory = provider.discover()

        let package = inventory.prefixes.first?.packages.first
        XCTAssertEqual(package?.name, "widget")
        XCTAssertNil(package?.sourceURL)
        XCTAssertEqual(inventory.prefixes.first?.outdatedCandidates.map(\.availableVersion), ["1.1.0"])
    }

    func testHomebrewProviderPrefersLinkedKegVersionOverReceiptArrayOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sift-brew-kegonly-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Two versions of a keg-only formula installed side by side; the older one happens to sort
        // last in the "installed" array, but linked_keg names the actually-active version. Picking
        // the array's last entry instead of honoring linked_keg would report the wrong installed
        // version here.
        try writeExecutable(
            at: directory.appending(path: "brew"),
            contents: """
                #!/bin/sh
                case "$1" in
                    --prefix) echo "/fake/brewA" ;;
                    info) printf '{"formulae":[{"name":"node@20","full_name":"node@20","tap":"homebrew/core","linked_keg":"20.10.0","installed":[{"version":"20.10.0","installed_on_request":true,"time":200},{"version":"18.19.0","installed_on_request":false,"time":100}]}],"casks":[]}' ;;
                    outdated) printf '{"formulae":[],"casks":[]}' ;;
                    *) exit 1 ;;
                esac
                """)

        let provider = HomebrewProvider(environment: [:], standardDirectories: [directory.path])
        let inventory = provider.discover()

        XCTAssertEqual(inventory.packages.first?.installedVersion, "20.10.0")
    }

    func testHomebrewProviderFallsBackToMostRecentlyInstalledReceiptWhenNotLinked() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sift-brew-unlinked-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        // No linked_keg at all (common for keg-only formulae that are never linked): the most
        // recently installed receipt is used rather than whichever sorts last in the array.
        try writeExecutable(
            at: directory.appending(path: "brew"),
            contents: """
                #!/bin/sh
                case "$1" in
                    --prefix) echo "/fake/brewA" ;;
                    info) printf '{"formulae":[{"name":"openssl@3","full_name":"openssl@3","tap":"homebrew/core","installed":[{"version":"3.2.0","installed_on_request":true,"time":500},{"version":"3.1.0","installed_on_request":false,"time":100}]}],"casks":[]}' ;;
                    outdated) printf '{"formulae":[],"casks":[]}' ;;
                    *) exit 1 ;;
                esac
                """)

        let provider = HomebrewProvider(environment: [:], standardDirectories: [directory.path])
        let inventory = provider.discover()

        XCTAssertEqual(inventory.packages.first?.installedVersion, "3.2.0")
    }

    func testHomebrewProviderKeepsOutdatedEntryWithMultipleInstalledVersions() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sift-brew-outdated-multi-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A cask mid-upgrade (or a formula with an older keg still on disk) lists every installed
        // version; the update is still real and must not be dropped.
        try writeExecutable(
            at: directory.appending(path: "brew"),
            contents: """
                #!/bin/sh
                case "$1" in
                    --prefix) echo "/fake/brewA" ;;
                    info) printf '{"formulae":[],"casks":[{"token":"meshnet","full_token":"meshnet","installed":"1.104.1","artifacts":[]}]}' ;;
                    outdated) printf '{"formulae":[],"casks":[{"name":"meshnet","installed_versions":["1.102.2","1.104.1"],"current_version":"1.104.2"}]}' ;;
                    *) exit 1 ;;
                esac
                """)

        let inventory = HomebrewProvider(environment: [:], standardDirectories: [directory.path]).discover()
        let prefix = inventory.prefixes.first
        XCTAssertEqual(
            prefix?.outdatedCandidates,
            [HomebrewOutdatedCandidate(kind: .cask, name: "meshnet", installedVersions: ["1.102.2", "1.104.1"], availableVersion: "1.104.2")])
        XCTAssertEqual(prefix?.warnings, [])
    }

    func testHomebrewProviderSkipsMalformedOutdatedEntryWithoutDiscardingOtherPackages() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sift-brew-outdated-shape-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        // "widget" has no current_version alongside a well-formed "gadget" entry. The malformed
        // entry must not throw away gadget's real update.
        try writeExecutable(
            at: directory.appending(path: "brew"),
            contents: """
                #!/bin/sh
                case "$1" in
                    --prefix) echo "/fake/brewA" ;;
                    info) printf '{"formulae":[{"name":"widget","full_name":"widget","tap":"homebrew/core","installed":[{"version":"1.0.0","installed_on_request":true}]},{"name":"gadget","full_name":"gadget","tap":"homebrew/core","installed":[{"version":"2.0.0","installed_on_request":true}]}],"casks":[]}' ;;
                    outdated) printf '{"formulae":[{"name":"widget","installed_versions":["1.0.0"]},{"name":"gadget","installed_versions":["2.0.0"],"current_version":"2.1.0"}],"casks":[]}' ;;
                    *) exit 1 ;;
                esac
                """)

        let provider = HomebrewProvider(environment: [:], standardDirectories: [directory.path])
        let inventory = provider.discover()

        let prefix = inventory.prefixes.first
        XCTAssertEqual(prefix?.outdatedComplete, true)
        XCTAssertEqual(prefix?.outdatedCandidates.map(\.name), ["gadget"])
        XCTAssertEqual(prefix?.outdatedCandidates.first?.availableVersion, "2.1.0")
        XCTAssertTrue(prefix?.warnings.first?.contains("widget") ?? false)
    }

    func testHomebrewProviderSkipsMalformedInventoryEntryWithoutDiscardingOtherPackages() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sift-brew-inventory-shape-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        // "widget" has no "installed" receipts at all (an unexpected `info --installed` shape)
        // alongside a normal, well-formed "gadget" entry. The malformed entry must not discard
        // gadget from the whole prefix's inventory.
        try writeExecutable(
            at: directory.appending(path: "brew"),
            contents: """
                #!/bin/sh
                case "$1" in
                    --prefix) echo "/fake/brewA" ;;
                    info) printf '{"formulae":[{"name":"widget","full_name":"widget","tap":"homebrew/core","installed":[]},{"name":"gadget","full_name":"gadget","tap":"homebrew/core","installed":[{"version":"2.0.0","installed_on_request":true}]}],"casks":[]}' ;;
                    outdated) printf '{"formulae":[],"casks":[]}' ;;
                    *) exit 1 ;;
                esac
                """)

        let provider = HomebrewProvider(environment: [:], standardDirectories: [directory.path])
        let inventory = provider.discover()

        XCTAssertEqual(inventory.packages.map(\.name), ["gadget"])
        XCTAssertTrue(inventory.prefixes.first?.complete ?? false)
        XCTAssertTrue(inventory.prefixes.first?.warnings.first?.contains("widget") ?? false)
    }

    func testRefreshCoordinatorRetainsCachedHomebrewTargetWhenInfoAndOutdatedDisagree() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)

        let root = FileManager.default.temporaryDirectory.appending(path: "sift-refresh-brew-mismatch-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let workingDirectory = root.appending(path: "working", directoryHint: .isDirectory)
        let brewURL = workingDirectory.appending(path: "brew")
        try writeExecutable(
            at: brewURL,
            contents: """
                #!/bin/sh
                case "$1" in
                    --prefix) echo "/fake/brewA" ;;
                    info) printf '{"formulae":[{"name":"widget","full_name":"widget","tap":"homebrew/core","installed":[{"version":"1.0.0","installed_on_request":true}],"urls":{"stable":{"url":"https://example.test/widget"}}}],"casks":[]}' ;;
                    outdated) printf '{"formulae":[{"name":"widget","installed_versions":["1.0.0"],"current_version":"1.1.0"}],"casks":[]}' ;;
                    *) exit 1 ;;
                esac
                """)
        let coordinator = RefreshCoordinator(
            database: database,
            nativeProvider: NativeApplicationProvider(roots: [], includeSpotlight: false),
            homebrewProvider: HomebrewProvider(environment: [:], standardDirectories: [workingDirectory.path]),
            npmGlobalProvider: NPMGlobalProvider(environment: [:], standardDirectories: []),
            uvToolProvider: UVToolProvider(environment: [:], standardDirectories: []), steamProvider: .absent, macPortsProvider: .absent, cargoProvider: .absent
        )

        let firstSummary = try coordinator.refresh(now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(firstSummary.status, .success)
        XCTAssertEqual(try database.homebrewUpdates(now: Date(timeIntervalSince1970: 1_000)).map(\.availableVersion), ["1.1.0"])

        // `brew info --installed` and `brew outdated` are separate `brew` invocations; here
        // `outdated` reports a different installed version (0.9.0) than `info` just reported
        // (1.0.0) for the same formula, simulating another process upgrading it mid-refresh. That
        // mismatch must not be read as "confirmed no update" — the previously cached 1.1.0 target
        // must survive and remain visible in `sift updates`, not be cleared to nil
        // or replaced by the mismatched candidate's 2.0.0.
        try writeExecutable(
            at: brewURL,
            contents: """
                #!/bin/sh
                case "$1" in
                    --prefix) echo "/fake/brewA" ;;
                    info) printf '{"formulae":[{"name":"widget","full_name":"widget","tap":"homebrew/core","installed":[{"version":"1.0.0","installed_on_request":true}],"urls":{"stable":{"url":"https://example.test/widget"}}}],"casks":[]}' ;;
                    outdated) printf '{"formulae":[{"name":"widget","installed_versions":["0.9.0"],"current_version":"2.0.0"}],"casks":[]}' ;;
                    *) exit 1 ;;
                esac
                """)
        let secondSummary = try coordinator.refresh(now: Date(timeIntervalSince1970: 200_000))
        XCTAssertEqual(secondSummary.status, .partial)
        let updates = try database.homebrewUpdates(now: Date(timeIntervalSince1970: 200_000))
        XCTAssertEqual(updates.map(\.availableVersion), ["1.1.0"])
    }

    func testHomebrewUpdateHiddenWhenPreservedTargetNoLongerMatchesCurrentInstalledVersion() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)

        let root = FileManager.default.temporaryDirectory.appending(path: "sift-refresh-brew-stale-target-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let workingDirectory = root.appending(path: "working", directoryHint: .isDirectory)
        let brewURL = workingDirectory.appending(path: "brew")
        try writeExecutable(
            at: brewURL,
            contents: """
                #!/bin/sh
                case "$1" in
                    --prefix) echo "/fake/brewA" ;;
                    info) printf '{"formulae":[{"name":"widget","full_name":"widget","tap":"homebrew/core","installed":[{"version":"1.0.0","installed_on_request":true}],"urls":{"stable":{"url":"https://example.test/widget"}}}],"casks":[]}' ;;
                    outdated) printf '{"formulae":[{"name":"widget","installed_versions":["1.0.0"],"current_version":"1.1.0"}],"casks":[]}' ;;
                    *) exit 1 ;;
                esac
                """)
        let coordinator = RefreshCoordinator(
            database: database,
            nativeProvider: NativeApplicationProvider(roots: [], includeSpotlight: false),
            homebrewProvider: HomebrewProvider(environment: [:], standardDirectories: [workingDirectory.path]),
            npmGlobalProvider: NPMGlobalProvider(environment: [:], standardDirectories: []),
            uvToolProvider: UVToolProvider(environment: [:], standardDirectories: []), steamProvider: .absent, macPortsProvider: .absent, cargoProvider: .absent
        )

        // Round 1: widget resolves cleanly, installed 1.0.0 -> available 1.1.0.
        _ = try coordinator.refresh(now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(try database.homebrewUpdates(now: Date(timeIntervalSince1970: 1_000)).map(\.availableVersion), ["1.1.0"])

        // Round 2: `info` now reports widget genuinely upgraded to 1.5.0 (e.g. a manual `brew
        // upgrade` outside sift), but `outdated` mismatches in the same round (transientFailure),
        // which preserves the *previous* round's target_status/target_for_installed_version/
        // available_version — all still pinned to installed_version 1.0.0. The 1.1.0 target was
        // never actually resolved against 1.5.0, so it must not be shown as widget's current
        // update: that would pair today's installed_version with an available_version that was
        // computed against a completely different, superseded installed_version.
        try writeExecutable(
            at: brewURL,
            contents: """
                #!/bin/sh
                case "$1" in
                    --prefix) echo "/fake/brewA" ;;
                    info) printf '{"formulae":[{"name":"widget","full_name":"widget","tap":"homebrew/core","installed":[{"version":"1.5.0","installed_on_request":true}],"urls":{"stable":{"url":"https://example.test/widget"}}}],"casks":[]}' ;;
                    outdated) printf '{"formulae":[{"name":"widget","installed_versions":["0.9.0"],"current_version":"2.0.0"}],"casks":[]}' ;;
                    *) exit 1 ;;
                esac
                """)
        _ = try coordinator.refresh(now: Date(timeIntervalSince1970: 200_000))
        XCTAssertEqual(try database.homebrewUpdates(now: Date(timeIntervalSince1970: 200_000)).map(\.availableVersion), [])
        XCTAssertEqual(try database.dashboard(now: Date(timeIntervalSince1970: 200_000)).data.availableUpdateCount, 0)
    }

    func testRefreshCoordinatorFetchesReleaseNotesForMultiplePackagesConcurrentlyWithoutCrossContamination() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)

        let root = FileManager.default.temporaryDirectory.appending(
            path: "sift-refresh-brew-concurrent-notes-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let workingDirectory = root.appending(path: "working", directoryHint: .isDirectory)
        try writeExecutable(
            at: workingDirectory.appending(path: "brew"),
            contents: """
                #!/bin/sh
                case "$1" in
                    --prefix) echo "/fake/brewA" ;;
                    info) printf '{"formulae":[{"name":"widget","full_name":"widget","tap":"homebrew/core","installed":[{"version":"1.0","installed_on_request":true}],"urls":{"stable":{"url":"https://github.com/ownerA/repoA"}}},{"name":"gadget","full_name":"gadget","tap":"homebrew/core","installed":[{"version":"1.0","installed_on_request":true}],"urls":{"stable":{"url":"https://github.com/ownerB/repoB"}}}],"casks":[]}' ;;
                    outdated) printf '{"formulae":[{"name":"widget","installed_versions":["1.0"],"current_version":"2.0"},{"name":"gadget","installed_versions":["1.0"],"current_version":"3.0"}],"casks":[]}' ;;
                    *) exit 1 ;;
                esac
                """)

        let commitA = String(repeating: "a", count: 40)
        let commitB = String(repeating: "b", count: 40)
        // Each package's fetch is now dispatched concurrently (see RefreshCoordinator's notesStartedAt
        // block); this handler is invoked from multiple threads at once, so it must route purely on
        // the request path with no shared mutable state, to catch any cross-package data mixing.
        MetadataURLProtocol.handler = { request in
            switch request.url?.path {
            case "/repos/ownerA/repoA/git/ref/tags/2.0":
                return (404, nil, [:])
            case "/repos/ownerA/repoA/git/ref/tags/v2.0":
                return (200, Data("{\"object\":{\"type\":\"commit\",\"sha\":\"\(commitA)\"}}".utf8), [:])
            case "/repos/ownerA/repoA/releases/tags/v2.0":
                return (200, Data("{\"id\":1,\"body\":\"Notes for widget.\",\"draft\":false}".utf8), [:])
            case "/repos/ownerB/repoB/git/ref/tags/3.0":
                return (404, nil, [:])
            case "/repos/ownerB/repoB/git/ref/tags/v3.0":
                return (200, Data("{\"object\":{\"type\":\"commit\",\"sha\":\"\(commitB)\"}}".utf8), [:])
            case "/repos/ownerB/repoB/releases/tags/v3.0":
                return (200, Data("{\"id\":2,\"body\":\"Notes for gadget.\",\"draft\":false}".utf8), [:])
            default:
                return (404, nil, [:])
            }
        }
        defer { MetadataURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataURLProtocol.self]
        let releaseNotes = ReleaseNotesResolver(metadataClient: MetadataHTTPClient(database: database, configuration: configuration))

        let coordinator = RefreshCoordinator(
            database: database,
            nativeProvider: NativeApplicationProvider(roots: [], includeSpotlight: false),
            homebrewProvider: HomebrewProvider(environment: [:], standardDirectories: [workingDirectory.path]),
            npmGlobalProvider: NPMGlobalProvider(environment: [:], standardDirectories: []),
            uvToolProvider: UVToolProvider(environment: [:], standardDirectories: []), steamProvider: .absent, macPortsProvider: .absent,
            cargoProvider: .absent,
            releaseNotes: releaseNotes
        )
        let summary = try coordinator.refresh(now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(summary.status, .success)
        XCTAssertEqual(summary.releaseNotesFetchedCount, 2)

        let widgetNotes = try database.homebrewReleaseNotes(
            prefix: "/fake/brewA", kind: .formula, fullName: "widget", installedVersion: "1.0", availableVersion: "2.0")
        let gadgetNotes = try database.homebrewReleaseNotes(
            prefix: "/fake/brewA", kind: .formula, fullName: "gadget", installedVersion: "1.0", availableVersion: "3.0")
        XCTAssertEqual(widgetNotes?.content, "Notes for widget.")
        XCTAssertEqual(gadgetNotes?.content, "Notes for gadget.")
    }

    // MARK: - Automatic brew update

    private func updateFixture(updateExit: Int32 = 0, environment: [String: String] = [:]) throws -> (
        root: URL, provider: (HomebrewUpdatePolicy, Date) -> (HomebrewInventory, [String], [String])
    ) {
        let root = FileManager.default.temporaryDirectory.appending(path: "sift-brew-update-\(UUID().uuidString)", directoryHint: .isDirectory)
        let prefix = root.appending(path: "prefix", directoryHint: .isDirectory)
        let log = root.appending(path: "calls.log")
        try FileManager.default.createDirectory(at: prefix.appending(path: ".git"), withIntermediateDirectories: true)
        try writeExecutable(
            at: root.appending(path: "bin/brew"),
            contents: """
                #!/bin/sh
                echo "$1" >> '\(log.path)'
                case "$1" in
                    update) exit \(updateExit) ;;
                    --prefix) echo '\(prefix.path)' ;;
                    info) printf '{"formulae":[{"name":"widget","full_name":"widget","tap":"homebrew/core","installed":[{"version":"1.0.0","installed_on_request":true}]}],"casks":[]}' ;;
                    outdated) printf '{"formulae":[],"casks":[]}' ;;
                    *) exit 1 ;;
                esac
                """)
        let provider = HomebrewProvider(environment: environment.merging(["HOME": root.path]) { $1 }, standardDirectories: [root.appending(path: "bin").path])
        return (
            root,
            { policy, now in
                try? FileManager.default.removeItem(at: log)
                let messages = Mutex<[String]>([])
                let inventory = provider.discover(update: policy, now: now) { message in messages.withLock { $0.append(message) } }
                let calls = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
                return (inventory, calls, messages.withLock { $0 })
            }
        )
    }

    private func touchFetchHead(in root: URL, at date: Date) throws {
        let file = root.appending(path: "prefix/.git/FETCH_HEAD")
        try Data().write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    func testAutomaticHomebrewUpdateSkipsFreshMetadata() throws {
        let (root, discover) = try updateFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try touchFetchHead(in: root, at: now.addingTimeInterval(-600))

        let (inventory, calls, messages) = discover(.automatic(), now)
        XCTAssertFalse(calls.contains("update"))
        XCTAssertEqual(messages, [])
        XCTAssertEqual(inventory.prefixes.first?.packages.map(\.name), ["widget"])
    }

    func testAutomaticHomebrewUpdateRunsWhenMetadataIsStaleOrMissing() throws {
        let (root, discover) = try updateFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()

        let (_, missingCalls, _) = discover(.automatic(), now)
        XCTAssertEqual(Array(missingCalls.prefix(2)), ["--prefix", "update"], "no metadata on disk counts as stale")

        try touchFetchHead(in: root, at: now.addingTimeInterval(-7_200))
        let (inventory, calls, messages) = discover(.automatic(), now)
        XCTAssertEqual(Array(calls.prefix(2)), ["--prefix", "update"], "the update runs before the snapshots are read")
        XCTAssertEqual(messages, ["Updating Homebrew metadata (last updated 2 hours ago)…"])
        XCTAssertEqual(inventory.prefixes.first?.warnings, [])
    }

    func testHomebrewUpdateHonorsAutoUpdateSecondsAndExplicitPolicies() throws {
        let (root, discover) = try updateFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try touchFetchHead(in: root, at: now.addingTimeInterval(-600))

        XCTAssertTrue(discover(.always, now).1.contains("update"))
        XCTAssertFalse(discover(.never, now.addingTimeInterval(86_400)).1.contains("update"))
        XCTAssertTrue(discover(.automatic(maximumAge: 300), now).1.contains("update"))

        let (dailyRoot, daily) = try updateFixture(environment: ["HOMEBREW_AUTO_UPDATE_SECS": "86400"])
        defer { try? FileManager.default.removeItem(at: dailyRoot) }
        try touchFetchHead(in: dailyRoot, at: now.addingTimeInterval(-7_200))
        XCTAssertFalse(daily(.automatic(), now).1.contains("update"), "Homebrew's own interval wins over the default hour")
    }

    func testHomebrewUpdateReadsAPISnapshotTimes() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sift-brew-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = root.appending(path: "cache/api/internal", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let snapshot = snapshots.appending(path: "packages.arm64_tahoe.jws.json")
        try Data("{}".utf8).write(to: snapshot)
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: snapshot.path)

        let provider = HomebrewProvider(environment: ["HOMEBREW_CACHE": root.appending(path: "cache").path], standardDirectories: [])
        XCTAssertEqual(provider.metadataUpdatedAt(prefix: root.appending(path: "none").path), stamp)
    }

    func testFailedHomebrewUpdateIsAWarningAndTheInventoryStillLoads() throws {
        let (root, discover) = try updateFixture(updateExit: 1)
        defer { try? FileManager.default.removeItem(at: root) }

        let (inventory, calls, _) = discover(.always, Date())
        XCTAssertEqual(Array(calls.prefix(2)), ["--prefix", "update"])
        XCTAssertEqual(inventory.prefixes.first?.packages.map(\.name), ["widget"])
        XCTAssertEqual(inventory.prefixes.first?.complete, true)
        XCTAssertEqual(inventory.prefixes.first?.warnings.count, 1)
        XCTAssertTrue(inventory.prefixes.first?.warnings.first?.hasPrefix("Homebrew update at ") == true)
    }

    // MARK: - Snapshots

    func testHomebrewSnapshotIsReusedUntilSomethingHomebrewReadsChanges() throws {
        let (root, _) = try updateFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try Database(url: root.appending(path: "sift.sqlite3"))
        let log = root.appending(path: "calls.log")
        let keg = root.appending(path: "prefix/Cellar/widget/1.0.0")
        try FileManager.default.createDirectory(at: keg, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: keg.appending(path: "INSTALL_RECEIPT.json"))
        let provider = HomebrewProvider(environment: ["HOME": root.path], standardDirectories: [root.appending(path: "bin").path])
        func discover(at now: Date) -> (names: [String], calls: [String]) {
            try? FileManager.default.removeItem(at: log)
            let inventory = provider.discover(now: now, snapshots: database)
            let calls = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            return (inventory.prefixes.first?.packages.map(\.name) ?? [], calls)
        }
        let now = Date()

        XCTAssertEqual(discover(at: now).calls.sorted(), ["--prefix", "info", "outdated"])
        let reused = discover(at: now.addingTimeInterval(60))
        XCTAssertEqual(reused.calls, ["--prefix"], "an unchanged prefix is answered from the snapshot")
        XCTAssertEqual(reused.names, ["widget"])

        // An upgrade rewrites the keg's receipt.
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(5)], ofItemAtPath: keg.appending(path: "INSTALL_RECEIPT.json").path)
        XCTAssertEqual(discover(at: now.addingTimeInterval(120)).calls.sorted(), ["--prefix", "info", "outdated"])
        XCTAssertEqual(discover(at: now.addingTimeInterval(180)).calls, ["--prefix"])

        // A new keg, and separately the age limit, each force a real run.
        try FileManager.default.createDirectory(at: root.appending(path: "prefix/Cellar/gadget/2.0"), withIntermediateDirectories: true)
        XCTAssertEqual(discover(at: now.addingTimeInterval(240)).calls.sorted(), ["--prefix", "info", "outdated"])
        XCTAssertEqual(discover(at: now.addingTimeInterval(240 + HomebrewProvider.snapshotMaximumAge + 1)).calls.sorted(), ["--prefix", "info", "outdated"])
    }

    func testHomebrewSnapshotFingerprintCoversMetadataAndSettings() throws {
        let (root, _) = try updateFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "bin/brew")
        let prefix = root.appending(path: "prefix").path
        let plain = HomebrewProvider(environment: ["HOME": root.path], standardDirectories: [])
        let base = plain.snapshotFingerprint(executable: executable, prefix: prefix)

        XCTAssertEqual(plain.snapshotFingerprint(executable: executable, prefix: prefix), base)
        XCTAssertNotEqual(
            HomebrewProvider(environment: ["HOME": root.path, "HOMEBREW_NO_INSTALL_FROM_API": "1"], standardDirectories: []).snapshotFingerprint(
                executable: executable, prefix: prefix), base)
        try Data().write(to: root.appending(path: "prefix/.git/FETCH_HEAD"))
        let fetched = plain.snapshotFingerprint(executable: executable, prefix: prefix)
        XCTAssertNotEqual(fetched, base, "brew update rewrites FETCH_HEAD")
        let api = root.appending(path: "Library/Caches/Homebrew/api/internal")
        try FileManager.default.createDirectory(at: api, withIntermediateDirectories: true)
        try Data().write(to: api.appending(path: "packages.arm64.jws.json"))
        XCTAssertNotEqual(plain.snapshotFingerprint(executable: executable, prefix: prefix), fetched, "and the API snapshots")
    }
}
