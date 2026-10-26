import Foundation

/// Blackmagic Design's public downloads feed, which its applications use to offer updates.
/// Only products whose application versions follow the product's own numbering are mapped;
/// utilities bundled in an installer carry their own versions and are left unmatched.
struct BlackmagicDownloads: Sendable {
    static let url = URL(string: "https://www.blackmagicdesign.com/api/support/us/downloads.json")!

    private static let products: [String: String] = [
        "com.blackmagic-design.davinciresolve": "davinci-resolve",
        "com.blackmagic-design.davinciresolvestudio": "davinci-resolve-studio",
        "com.blackmagic-design.blackmagicrawplayer": "braw-sdk",
        "com.blackmagic-design.blackmagicrawspeedtest": "braw-sdk",
    ]

    static func product(forBundleIdentifier identifier: String) -> String? {
        products[identifier.lowercased()]
    }

    private let latest: [String: (Int, Int, Int)]

    init(data: Data) throws {
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any], let downloads = document["downloads"] as? [[String: Any]] else {
            throw MetadataHTTPError.invalidResponse
        }
        var latest: [String: (Int, Int, Int)] = [:]
        for download in downloads {
            // Public betas are listed alongside releases.
            guard let name = download["name"] as? String, !name.localizedCaseInsensitiveContains("beta"),
                  let urls = download["urls"] as? [String: Any], let mac = urls["Mac OS X"] as? [[String: Any]] else { continue }
            for release in mac {
                guard let product = release["product"] as? String, let major = release["major"] as? Int, let minor = release["minor"] as? Int else { continue }
                let version = (major, minor, release["releaseNum"] as? Int ?? 0)
                if let current = latest[product], current >= version { continue }
                latest[product] = version
            }
        }
        self.latest = latest
    }

    /// "21.1.1", or "21.1" when the release number is zero.
    func latestVersion(product: String) -> String? {
        guard let (major, minor, release) = latest[product] else { return nil }
        return release == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(release)"
    }
}
