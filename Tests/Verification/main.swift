import Foundation
import SiftCLI
import SiftCore

@main
enum SiftVerification {
    static func main() {
        do {
            try verifyEmptyDatabase()
            try verifyRefreshOutcomes()
            try verifyStalenessBoundary()
            try verifyJSON()
            try verifyNativeInventory()
            print("Sift verification passed.")
        } catch {
            FileHandle.standardError.write(Data("Sift verification failed: \(error.localizedDescription)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func verifyEmptyDatabase() throws {
        let database = try Database(url: temporaryDatabaseURL())
        let dashboard = try database.dashboard(now: Date(timeIntervalSince1970: 1_000))
        try require(dashboard.schemaVersion == 0, "Dashboard schema version must remain pre-v1.")
        try require(dashboard.freshness == .unknown, "A new database must have unknown freshness.")
        try require(dashboard.latestRefreshStatus == .never, "A new database must not have a refresh outcome.")
    }

    private static func verifyRefreshOutcomes() throws {
        let database = try Database(url: temporaryDatabaseURL())
        let successfulDate = Date(timeIntervalSince1970: 1_000)
        _ = try database.applyRefresh(refreshInput(at: successfulDate))
        _ = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 2_000), providerStatuses: Dictionary(uniqueKeysWithValues: RefreshProvider.allCases.map { ($0, .failure) })))
        let dashboard = try database.dashboard(now: Date(timeIntervalSince1970: 2_100), staleAfter: 1_500)
        try require(dashboard.lastAttemptAt == Date(timeIntervalSince1970: 2_000), "The latest attempt timestamp must advance after failure.")
        try require(dashboard.dataAsOf == successfulDate, "Failed providers must preserve the last successful data timestamp.")
        try require(dashboard.latestRefreshStatus == .failure, "A fully failed run must be visible.")
    }

    private static func verifyStalenessBoundary() throws {
        let database = try Database(url: temporaryDatabaseURL())
        let date = Date(timeIntervalSince1970: 1_000)
        _ = try database.applyRefresh(refreshInput(at: date))
        try require(try database.dashboard(now: date.addingTimeInterval(120), staleAfter: 120).freshness == .stale, "Aggregate freshness must become stale at the configured boundary.")
    }

    private static func verifyJSON() throws {
        let dashboard = Dashboard(generatedAt: Date(timeIntervalSince1970: 1_000), lastAttemptAt: nil, dataAsOf: nil, freshness: .unknown, latestRefreshStatus: .never, data: DashboardData(availableUpdateCount: 0, recentTransitionCount: 0, failedProviderCount: 0))
        let output = try DashboardRenderer.json(dashboard)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try require(try decoder.decode(Dashboard.self, from: Data(output.utf8)) == dashboard, "JSON must decode to the original dashboard.")
        try require(output.contains("\"lastAttemptAt\" : null") && output.contains("\"dataAsOf\" : null"), "Unavailable timestamps must be explicit JSON null values.")
    }

    private static func verifyNativeInventory() throws {
        let database = try Database(url: temporaryDatabaseURL())
        let application = NativeApplication(path: "/Applications/Example.app", bundleIdentifier: "com.example.example", displayName: "Example", shortVersion: "1.0", buildVersion: "1")
        let first = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 1_000), nativeInventory: NativeInventoryResult(applications: [application])))
        let second = try database.applyRefresh(refreshInput(at: Date(timeIntervalSince1970: 2_000), nativeInventory: NativeInventoryResult(applications: [application])))
        try require(first.addedCount == 1 && second.changedCount == 0, "Repeated native inventory must not create a false transition.")
    }

    private static func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "sift-verification-\(UUID().uuidString).sqlite3")
    }

    private static func refreshInput(at date: Date, nativeInventory: NativeInventoryResult = NativeInventoryResult(applications: []), providerStatuses: [RefreshProvider: ProviderRefreshStatus] = [:]) -> RefreshPersistenceInput {
        let providerResults = RefreshProvider.allCases.map { provider in
            let status = providerStatuses[provider] ?? .success
            return ProviderRefreshResult(provider: provider, status: status, startedAt: date, finishedAt: date, dataAsOf: status == .success ? date : nil)
        }
        return RefreshPersistenceInput(startedAt: date, finishedAt: date, nativeInventory: nativeInventory, homebrewInventory: HomebrewInventory(prefixes: []), targetResults: [:], releaseNoteResults: [:], providerResults: providerResults)
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VerificationError(message: message) }
    }
}

private struct VerificationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
