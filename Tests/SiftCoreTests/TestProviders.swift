import Foundation
@testable import SiftCore

/// Providers that find nothing, so coordinator tests never read the machine they run on.
extension SteamProvider {
    static let absent = SteamProvider(steamDirectory: URL(filePath: "/nonexistent-sift-test/Steam", directoryHint: .isDirectory))
}

extension MacPortsProvider {
    static let absent = MacPortsProvider(prefix: URL(filePath: "/nonexistent-sift-test/opt-local", directoryHint: .isDirectory))
}

extension CargoProvider {
    static let absent = CargoProvider(cargoHome: URL(filePath: "/nonexistent-sift-test/cargo", directoryHint: .isDirectory))
}
