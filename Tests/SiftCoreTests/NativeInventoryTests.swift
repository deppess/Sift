import Darwin
import Foundation
import XCTest
@testable import SiftCore

final class NativeInventoryTests: XCTestCase {
    func testNativeInventoryIsIdempotentAndRecordsBuildTransitions() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let first = NativeApplication(
            path: "/Applications/Example.app", bundleIdentifier: "com.example.app", displayName: "Example", shortVersion: "1.0", buildVersion: "100",
            classification: .user, discoveryRoot: "/Applications")
        let firstSummary = try database.applyRefresh(
            refreshInput(at: Date(timeIntervalSince1970: 1_001), nativeInventory: NativeInventoryResult(applications: [first])))
        XCTAssertEqual(firstSummary.addedCount, 1)
        XCTAssertEqual(firstSummary.changedCount, 0)

        let repeated = try database.applyRefresh(
            refreshInput(at: Date(timeIntervalSince1970: 2_001), nativeInventory: NativeInventoryResult(applications: [first])))
        XCTAssertEqual(repeated.addedCount, 0)
        XCTAssertEqual(repeated.changedCount, 0)

        let updated = NativeApplication(
            path: first.path, bundleIdentifier: first.bundleIdentifier, displayName: first.displayName, shortVersion: "1.0", buildVersion: "101")
        let changed = try database.applyRefresh(
            refreshInput(at: Date(timeIntervalSince1970: 3_001), nativeInventory: NativeInventoryResult(applications: [updated])))
        XCTAssertEqual(changed.changedCount, 1)
    }

    func testNativeVersionTransitionsHideDeactivatedInstallationsByDefault() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let first = NativeApplication(
            path: "/Applications/Example.app", bundleIdentifier: "com.example.app", displayName: "Example", shortVersion: "1.0", buildVersion: nil,
            classification: .user, discoveryRoot: "/Applications")
        _ = try database.applyRefresh(
            refreshInput(
                at: Date(timeIntervalSince1970: 1_000),
                nativeInventory: NativeInventoryResult(applications: [first], scannedRoots: ["/Applications"], candidatePaths: [first.path])))
        let updated = NativeApplication(
            path: first.path, bundleIdentifier: first.bundleIdentifier, displayName: first.displayName, shortVersion: "2.0", buildVersion: nil,
            classification: .user, discoveryRoot: "/Applications")
        _ = try database.applyRefresh(
            refreshInput(
                at: Date(timeIntervalSince1970: 2_000),
                nativeInventory: NativeInventoryResult(applications: [updated], scannedRoots: ["/Applications"], candidatePaths: [updated.path])))
        XCTAssertEqual(try database.nativeVersionTransitions().count, 1)

        // The app is uninstalled; its transition history should no longer surface by default,
        // matching how catalogItems/nativeApplicationItems already hide inactive installations.
        _ = try database.applyRefresh(
            refreshInput(at: Date(timeIntervalSince1970: 3_000), nativeInventory: NativeInventoryResult(applications: [], scannedRoots: ["/Applications"])))
        XCTAssertEqual(try database.nativeVersionTransitions().count, 0)
        XCTAssertEqual(try database.nativeVersionTransitions(includeAll: true).count, 1)
    }

    func testCompleteNativeInventoryMarksMissingApplicationInactive() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let application = NativeApplication(
            path: "/Applications/Example.app", bundleIdentifier: nil, displayName: "Example", shortVersion: nil, buildVersion: nil, classification: .user,
            discoveryRoot: "/Applications")
        _ = try database.applyRefresh(
            refreshInput(
                at: Date(timeIntervalSince1970: 1_000),
                nativeInventory: NativeInventoryResult(applications: [application], scannedRoots: ["/Applications"], candidatePaths: [application.path])))
        let summary = try database.applyRefresh(
            refreshInput(at: Date(timeIntervalSince1970: 2_000), nativeInventory: NativeInventoryResult(applications: [], scannedRoots: ["/Applications"])))
        XCTAssertEqual(summary.inactiveCount, 1)
        XCTAssertEqual(try database.catalogItems(includeAll: true).first?.active, false)
    }

    func testSpotlightOnlyInstallationIsReapedWhenNoLongerOnDisk() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let path = "/nonexistent-sift-test-\(UUID().uuidString).app"
        let application = NativeApplication(
            path: path, bundleIdentifier: "com.example.ghost", displayName: "Ghost", shortVersion: "1.0", buildVersion: nil, classification: .user,
            discoveryRoot: "/")
        _ = try database.applyRefresh(
            refreshInput(
                at: Date(timeIntervalSince1970: 1_000),
                nativeInventory: NativeInventoryResult(applications: [application], scannedRoots: ["/"], candidatePaths: [path])))
        XCTAssertEqual(try database.catalogItems(includeAll: true).first?.active, true)

        // discovery_root "/" is deliberately never in scannedRoots (Spotlight's coverage can't be
        // proven complete), so only a direct on-disk existence check can reap this once it's gone.
        let summary = try database.applyRefresh(
            refreshInput(at: Date(timeIntervalSince1970: 2_000), nativeInventory: NativeInventoryResult(applications: [], scannedRoots: ["/Applications"])))
        XCTAssertEqual(summary.inactiveCount, 1)
        XCTAssertEqual(try database.catalogItems(includeAll: true).first?.active, false)
    }

    func testSpotlightOnlyInstallationIsReapedWhenNoLongerAPlausibleBundleEvenIfStillOnDisk() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let root = FileManager.default.temporaryDirectory.appending(path: "sift-nested-reap-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        // A bundle nested inside another bundle (a framework helper, an XPC service, etc.) genuinely
        // exists on disk, so the plain on-disk-existence check the discovery_root "/" reaping path
        // uses is not enough on its own — it must also re-check the same plausibility policy
        // discovery itself applies, or a path discovery would now refuse to track stays a permanent
        // ghost simply because its file never goes away.
        let nestedPath = root.appending(path: "Helper.framework/Versions/A/Nested.app").path
        try makeApplication(
            at: URL(filePath: nestedPath),
            metadata: [
                "CFBundleIdentifier": "com.example.nested", "CFBundleDisplayName": "Nested", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "100"
            ])
        let application = NativeApplication(
            path: nestedPath, bundleIdentifier: "com.example.nested", displayName: "Nested", shortVersion: "1.0", buildVersion: nil, classification: .user,
            discoveryRoot: "/")
        _ = try database.applyRefresh(
            refreshInput(
                at: Date(timeIntervalSince1970: 1_000),
                nativeInventory: NativeInventoryResult(applications: [application], scannedRoots: ["/"], candidatePaths: [nestedPath])))
        XCTAssertEqual(try database.catalogItems(includeAll: true).first?.active, true)

        let summary = try database.applyRefresh(
            refreshInput(at: Date(timeIntervalSince1970: 2_000), nativeInventory: NativeInventoryResult(applications: [], scannedRoots: ["/Applications"])))
        XCTAssertEqual(summary.inactiveCount, 1)
        XCTAssertEqual(try database.catalogItems(includeAll: true).first?.active, false)
    }

    func testNativeProviderRecursesRootsDeduplicatesCandidatesAndAcceptsNonAPPLBundles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sift-bundles-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApplication(
            at: root.appending(path: "Example.app"),
            metadata: [
                "CFBundleIdentifier": "com.example.app", "CFBundleDisplayName": "Example", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "100",
                "CFBundlePackageType": "APPL"
            ])
        try makeApplication(
            at: root.appending(path: "Nested/Second.app"),
            metadata: ["CFBundleIdentifier": "com.example.second", "CFBundleName": "Second", "CFBundlePackageType": "FNDR"])
        try makeApplication(
            at: root.appending(path: "TooDeep/One/Two/Third.app"),
            metadata: ["CFBundleIdentifier": "com.example.third", "CFBundleName": "Third", "CFBundlePackageType": "APPL"])

        let searchRoot = NativeSearchRoot(url: root, classification: .user, required: true)
        let inventory = NativeApplicationProvider(roots: [searchRoot, searchRoot]).discover()
        XCTAssertTrue(inventory.complete)
        XCTAssertEqual(inventory.applications.map(\.displayName), ["Example", "Second", "Third"])
        XCTAssertEqual(inventory.applications.first?.classification, .user)
        XCTAssertEqual(inventory.candidatePaths.count, 3)
    }

    func testNativeProviderMarksUnreadableBundleAsPartialWithoutDiscardingOthers() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sift-bundles-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApplication(
            at: root.appending(path: "Example.app"),
            metadata: ["CFBundleIdentifier": "com.example.app", "CFBundleDisplayName": "Example", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "100"]
        )
        // A bundle with a Contents directory but no Info.plist inside it fails to read, but must not
        // be reported as a clean success, and must not prevent the successfully-read bundle's data
        // from being returned. (A directory with no Contents directory at all isn't a real bundle in
        // the first place — see testNativeProviderSkipsAppSuffixedDirectoryWithoutContentsDirectory.)
        try FileManager.default.createDirectory(at: root.appending(path: "Broken.app/Contents"), withIntermediateDirectories: true)

        let searchRoot = NativeSearchRoot(url: root, classification: .user, required: true)
        let inventory = NativeApplicationProvider(roots: [searchRoot]).discover()
        XCTAssertFalse(inventory.complete)
        XCTAssertEqual(inventory.applications.map(\.displayName), ["Example"])
        XCTAssertEqual(inventory.warnings.count, 1)
    }

    func testNativeProviderSkipsAppSuffixedDirectoryWithoutContentsDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sift-bundles-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApplication(
            at: root.appending(path: "Example.app"),
            metadata: ["CFBundleIdentifier": "com.example.app", "CFBundleDisplayName": "Example", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "100"]
        )
        // Not every "*.app"-suffixed directory is a real bundle: macOS's App Sandbox creates empty
        // "<extension-bundle-id>.app"-named script containers under ~/Library/Application Scripts,
        // and an ordinary folder can coincidentally be named "*.app". Both lack a Contents directory
        // entirely and must be silently skipped rather than treated as a read failure that marks the
        // whole refresh partial.
        try FileManager.default.createDirectory(at: root.appending(path: "NotReally.app"), withIntermediateDirectories: true)

        let searchRoot = NativeSearchRoot(url: root, classification: .user, required: true)
        let inventory = NativeApplicationProvider(roots: [searchRoot]).discover()
        XCTAssertTrue(inventory.complete)
        XCTAssertEqual(inventory.applications.map(\.displayName), ["Example"])
        XCTAssertEqual(inventory.warnings.count, 0)
    }

    func testNativeProviderSkipsAppBundleNestedInsideAnotherBundle() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sift-bundles-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApplication(
            at: root.appending(path: "Example.app"),
            metadata: ["CFBundleIdentifier": "com.example.app", "CFBundleDisplayName": "Example", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "100"]
        )
        // A real, fully-formed bundle living inside a .framework's internals (as many system helper
        // daemons and XPC services do) is not a top-level installed application in its own right —
        // it has no independent update lifecycle. Must be excluded even though it would otherwise
        // pass every other check (it has a Contents directory and a valid Info.plist).
        try makeApplication(
            at: root.appending(path: "Helper.framework/Versions/A/Helpers/NestedHelper.app"),
            metadata: [
                "CFBundleIdentifier": "com.example.helper", "CFBundleDisplayName": "NestedHelper", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "100"
            ]
        )

        let searchRoot = NativeSearchRoot(url: root, classification: .user, required: true)
        let inventory = NativeApplicationProvider(roots: [searchRoot]).discover()
        XCTAssertTrue(inventory.complete)
        XCTAssertEqual(inventory.applications.map(\.displayName), ["Example"])
        XCTAssertEqual(inventory.warnings.count, 0)
    }

    func testNativeProviderMarksMissingRequiredRootPartial() {
        let root = URL(fileURLWithPath: "/tmp/sift-missing-\(UUID().uuidString)")
        let inventory = NativeApplicationProvider(roots: [NativeSearchRoot(url: root, classification: .user, required: true)]).discover()
        XCTAssertFalse(inventory.complete)
        XCTAssertEqual(inventory.applications.count, 0)
        XCTAssertEqual(inventory.warnings.count, 1)
    }

    func testNativeApplicationHandlesUnicodeNameAndPath() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let application = NativeApplication(
            path: "/Users/example/Applications/Café Éditeur.app", bundleIdentifier: "com.example.café", displayName: "Café Éditeur 日本語", shortVersion: "2.0",
            buildVersion: nil, classification: .user, discoveryRoot: "/Users/example/Applications")
        _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 1_000), nativeInventory: NativeInventoryResult(applications: [application])))

        let items = try database.catalogItems()
        XCTAssertEqual(items.map(\.name), ["Café Éditeur 日本語"])
        XCTAssertEqual(items.first?.path, application.path)
    }

    func testCatalogItemsDisambiguatesCollidingNativeAppSelectorsByPath() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let first = NativeApplication(
            path: "/Applications/Example.app", bundleIdentifier: "com.example.app", displayName: "Example", shortVersion: "1.0", buildVersion: nil,
            classification: .user, discoveryRoot: "/Applications")
        let second = NativeApplication(
            path: "/Volumes/External/Example.app", bundleIdentifier: "com.example.app", displayName: "Example", shortVersion: "1.0", buildVersion: nil,
            classification: .user, discoveryRoot: "/Volumes/External")
        _ = try database.applyRefresh(
            refreshInput(at: Date(timeIntervalSince1970: 1_000), nativeInventory: NativeInventoryResult(applications: [first, second])))

        let selectors = try database.catalogItems().map(\.selector).sorted()
        XCTAssertEqual(selectors, ["app:com.example.app@/Applications/Example.app", "app:com.example.app@/Volumes/External/Example.app"])
    }

    func testNativeApplicationItemsHidesSystemAppsUnlessIncludeAll() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let userApp = NativeApplication(
            path: "/Applications/Example.app", bundleIdentifier: "com.example.app", displayName: "Example", shortVersion: "1.0", buildVersion: nil,
            classification: .user, discoveryRoot: "/Applications")
        let systemApp = NativeApplication(
            path: "/System/Applications/Calculator.app", bundleIdentifier: "com.apple.calculator", displayName: "Calculator", shortVersion: "1.0",
            buildVersion: nil, classification: .system, discoveryRoot: "/System/Applications")
        _ = try database.applyRefresh(
            refreshInput(at: Date(timeIntervalSince1970: 1_000), nativeInventory: NativeInventoryResult(applications: [userApp, systemApp])))

        XCTAssertEqual(try database.nativeApplicationItems().map(\.name), ["Example"])
        XCTAssertEqual(try database.nativeApplicationItems(includeAll: true).map(\.name).sorted(), ["Calculator", "Example"])
    }

    func testCatalogItemsKeepDistinctNamesForConcurrentAppsSharingABundleIdentifier() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        // Xcode.app and Xcode-beta.app commonly share the same CFBundleIdentifier. They must not
        // be conflated into a single shared name just because they're grouped under one bundle
        // identifier for selector purposes.
        let stable = NativeApplication(
            path: "/Applications/Xcode.app", bundleIdentifier: "com.apple.dt.Xcode", displayName: "Xcode", shortVersion: "15.0", buildVersion: nil,
            classification: .user, discoveryRoot: "/Applications")
        let beta = NativeApplication(
            path: "/Applications/Xcode-beta.app", bundleIdentifier: "com.apple.dt.Xcode", displayName: "Xcode-beta", shortVersion: "16.0", buildVersion: nil,
            classification: .user, discoveryRoot: "/Applications")
        _ = try database.applyRefresh(
            refreshInput(at: Date(timeIntervalSince1970: 1_000), nativeInventory: NativeInventoryResult(applications: [stable, beta])))

        let items = try database.catalogItems()
        let names = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0.name) })
        XCTAssertEqual(names["/Applications/Xcode.app"], "Xcode")
        XCTAssertEqual(names["/Applications/Xcode-beta.app"], "Xcode-beta")
    }

    func testNativeApplicationDisplayNameUpdatesOnRename() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let database = try Database(url: url)
        let original = NativeApplication(
            path: "/Applications/Example.app", bundleIdentifier: "com.example.app", displayName: "Example", shortVersion: "1.0", buildVersion: nil,
            classification: .user, discoveryRoot: "/Applications")
        _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 1_000), nativeInventory: NativeInventoryResult(applications: [original])))
        XCTAssertEqual(try database.catalogItems().first?.name, "Example")

        let renamed = NativeApplication(
            path: original.path, bundleIdentifier: original.bundleIdentifier, displayName: "Example Pro", shortVersion: "1.0", buildVersion: nil,
            classification: .user, discoveryRoot: "/Applications")
        _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 2_000), nativeInventory: NativeInventoryResult(applications: [renamed])))
        XCTAssertEqual(try database.catalogItems().first?.name, "Example Pro")
    }
}
