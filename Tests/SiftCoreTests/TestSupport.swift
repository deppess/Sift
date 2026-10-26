import Darwin
import Foundation
import XCTest
@testable import SiftCore

/// Fixtures shared by the core test suites.
extension XCTestCase {
    func writeExecutable(at url: URL, contents: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        XCTAssertEqual(chmod(url.path, 0o755), 0)
    }

    func homebrewPackage(kind: HomebrewPackageKind, name: String, artifacts: [String] = [], autoUpdates: Bool = false) -> HomebrewPackage {
        HomebrewPackage(prefix: "/opt/homebrew", kind: kind, name: name, fullName: name, tap: kind == .formula ? "homebrew/core" : "homebrew/cask", ownership: kind == .formula ? .explicitlyRequested : .installedCask, installedVersion: "1.0", sourceURL: nil, artifactPaths: artifacts, autoUpdates: autoUpdates)
    }

    func refreshInput(at date: Date, nativeInventory: NativeInventoryResult = NativeInventoryResult(applications: []), homebrewInventory: HomebrewInventory = HomebrewInventory(prefixes: []), targetResults: [HomebrewPackageKey: HomebrewTargetResolution] = [:], releaseNoteResults: [HomebrewPackageKey: HomebrewReleaseNotesResolution] = [:], providerStatuses: [RefreshProvider: ProviderRefreshStatus] = [:]) -> RefreshPersistenceInput {
        let providerResults = RefreshProvider.allCases.map { provider in
            let status = providerStatuses[provider] ?? .success
            return ProviderRefreshResult(provider: provider, status: status, startedAt: date, finishedAt: date, dataAsOf: status == .success ? date : nil)
        }
        return RefreshPersistenceInput(startedAt: date, finishedAt: date, nativeInventory: nativeInventory, homebrewInventory: homebrewInventory, targetResults: targetResults, releaseNoteResults: releaseNoteResults, providerResults: providerResults)
    }

    func makeApplication(at url: URL, metadata: [String: String]) throws {
        let plistURL = url.appending(path: "Contents/Info.plist")
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try data.write(to: plistURL)
    }

    func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "sift-test-\(UUID().uuidString).sqlite3")
    }

    func temporaryDatabaseDirectory(mode: mode_t) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sift-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(directory.path, mode), 0)
        return directory
    }

    func removeDatabase(at url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal", ".refresh.lock"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }
}

final class MetadataURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data?, [String: String]))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: MetadataHTTPError.invalidResponse)
            return
        }
        let result = handler(request)
        guard let response = HTTPURLResponse(url: url, statusCode: result.0, httpVersion: "HTTP/1.1", headerFields: result.2) else {
            client?.urlProtocol(self, didFailWithError: MetadataHTTPError.invalidResponse)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = result.1 { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
