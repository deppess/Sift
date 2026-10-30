import Foundation
import XCTest
@testable import SiftCore

final class HistoryTests: XCTestCase {
    private var url: URL!

    override func setUp() { url = temporaryDatabaseURL() }
    override func tearDown() { removeDatabase(at: url) }

    func testHomebrewVersionChangesAreLoggedAndDependenciesHiddenByDefault() throws {
        let database = try Database(url: url)
        func formula(_ name: String, _ version: String, ownership: HomebrewOwnership = .explicitlyRequested) -> HomebrewPackage {
            HomebrewPackage(prefix: "/opt/homebrew", kind: .formula, name: name, fullName: name, tap: "homebrew/core", ownership: ownership, installedVersion: version, sourceURL: nil, artifactPaths: [], autoUpdates: false)
        }
        func inventory(_ packages: [HomebrewPackage]) -> HomebrewInventory {
            HomebrewInventory(prefixes: [HomebrewPrefixInventory(prefix: "/opt/homebrew", packages: packages, complete: true, warnings: [])])
        }
        func refresh(at seconds: TimeInterval, _ packages: [HomebrewPackage]) throws {
            let targets = Dictionary(uniqueKeysWithValues: packages.map { (HomebrewPackageKey($0), HomebrewTargetResolution.unsupported("none")) })
            _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: seconds), homebrewInventory: inventory(packages), targetResults: targets))
        }
        try refresh(at: 1_000, [formula("gh", "2.101.0"), formula("readline", "8.2", ownership: .dependency)])
        try refresh(at: 2_000, [formula("gh", "2.101.0"), formula("readline", "8.2", ownership: .dependency)])
        try refresh(at: 3_000, [formula("gh", "2.102.0"), formula("readline", "8.3", ownership: .dependency)])

        let log = try database.updateLog()
        XCTAssertEqual(log.map { "\($0.selector) \($0.fromVersion)->\($0.toVersion)" }, ["formula:gh 2.101.0->2.102.0"])
        XCTAssertEqual(log.first?.observedAt, Date(timeIntervalSince1970: 3_000))
        XCTAssertEqual(try database.updateLog(includeAll: true).map(\.name), ["gh", "readline"])
        XCTAssertEqual(try database.updateLog(since: Date(timeIntervalSince1970: 3_500)), [])
    }

    func testManagedPackageChangesAreLoggedWithTheirSelectors() throws {
        let database = try Database(url: url)
        func refresh(at seconds: TimeInterval, npm: String, build: String) throws {
            let date = Date(timeIntervalSince1970: seconds)
            let inventories = [
                ManagedPackageInventory(provider: .npmGlobal, scopes: [ManagedPackageScope(scope: "/opt/homebrew/lib", packages: [ManagedPackage(name: "typescript", installedVersion: npm)])]),
                ManagedPackageInventory(provider: .steamGames, scopes: [ManagedPackageScope(scope: "/Steam", packages: [ManagedPackage(name: "Balatro", installedVersion: build, selfUpdating: true, identifier: "2379780")])]),
            ]
            _ = try database.applyRefresh(RefreshPersistenceInput(startedAt: date, finishedAt: date, nativeInventory: NativeInventoryResult(applications: []), homebrewInventory: HomebrewInventory(prefixes: []), targetResults: [:], releaseNoteResults: [:], managedPackageInventories: inventories, providerResults: refreshInput(at: date).providerResults))
        }
        try refresh(at: 1_000, npm: "5.8.2", build: "100")
        try refresh(at: 2_000, npm: "5.9.0", build: "100")
        try refresh(at: 3_000, npm: "5.9.0", build: "101")

        XCTAssertEqual(try database.updateLog().map { "\($0.selector) \($0.fromVersion)->\($0.toVersion) \($0.source)" }, ["steam:Balatro 100->101 steam-games", "npm:typescript 5.8.2->5.9.0 npm-global"])
        let balatro = try XCTUnwrap(database.catalogItems().first { $0.name == "Balatro" })
        XCTAssertEqual(balatro.identifier, "2379780")
        XCTAssertEqual(balatro.kind, .package)
        guard case .item = try database.resolveCatalogItem("2379780") else { return XCTFail("Steam app ID should resolve") }
    }

    func testA100CacheIsUpgradedInPlaceAndKeepsItsHistory() throws {
        let app = NativeApplication(path: "/Applications/Example.app", bundleIdentifier: "com.example", displayName: "Example", shortVersion: "1.0", buildVersion: nil, classification: .user, discoveryRoot: "/Applications")
        let updated = NativeApplication(path: app.path, bundleIdentifier: app.bundleIdentifier, displayName: app.displayName, shortVersion: "1.1", buildVersion: nil, classification: .user, discoveryRoot: "/Applications")
        do {
            let database = try Database(url: url)
            _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 1_000), nativeInventory: NativeInventoryResult(applications: [app], scannedRoots: ["/Applications"])))
            _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 2_000), nativeInventory: NativeInventoryResult(applications: [updated], scannedRoots: ["/Applications"])))
            // Back to exactly what 1.0.0 wrote.
            try database.execute("""
                DROP TABLE package_transitions; DROP TABLE changelog_history; DROP TABLE changelog_state;
                ALTER TABLE managed_packages DROP COLUMN identifier;
                DELETE FROM schema_migrations WHERE version > 15;
                """)
        }
        let database = try Database.readOnly(url: url)
        XCTAssertEqual(try database.scalarInt("SELECT MAX(version) FROM schema_migrations;"), Database.schemaVersion)
        XCTAssertEqual(try database.updateLog().map { "\($0.name) \($0.fromVersion)->\($0.toVersion)" }, ["Example 1.0->1.1"])
    }
}
