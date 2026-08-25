import Foundation

public struct NativeApplicationProvider {
    public static let identifier = "native-apps"
    public let roots: [NativeSearchRoot]
    public let maximumDepth: Int

    public init(roots: [NativeSearchRoot] = defaultRoots(), maximumDepth: Int = 2) {
        self.roots = roots
        self.maximumDepth = maximumDepth
    }

    public func discover() -> NativeInventoryResult {
        guard maximumDepth >= 0, roots.allSatisfy(\.url.isFileURL) else {
            return NativeInventoryResult(applications: [], warnings: ["Invalid native application search-root configuration."], complete: false)
        }
        var applications: [NativeApplication] = []
        var warnings: [String] = []
        var scannedRoots: [String] = []
        var candidatePaths = Set<String>()
        var seenApplications = Set<String>()
        var complete = true

        for root in roots {
            let normalizedRoot = root.url.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: normalizedRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                if root.required {
                    warnings.append("Required application root is unavailable: \(normalizedRoot.path)")
                    complete = false
                }
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: normalizedRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, error in
                    warnings.append("Unable to enumerate \(normalizedRoot.path): \(error.localizedDescription)")
                    complete = false
                    return true
                }
            ) else {
                warnings.append("Unable to enumerate \(normalizedRoot.path).")
                complete = false
                continue
            }
            scannedRoots.append(normalizedRoot.path)
            for case let candidate as URL in enumerator {
                // A bundle directly inside a root is depth zero; only containing directories consume depth.
                let depth = max(0, candidate.pathComponents.count - normalizedRoot.pathComponents.count - 1)
                if depth > maximumDepth { enumerator.skipDescendants(); continue }
                guard candidate.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                let normalized = candidate.standardizedFileURL.resolvingSymlinksInPath()
                guard normalized.path.hasPrefix(normalizedRoot.path + "/") else { continue }
                candidatePaths.insert(normalized.path)
                guard seenApplications.insert(normalized.path).inserted else { continue }
                do {
                    if let application = try application(at: normalized, root: normalizedRoot, classification: root.classification) {
                        applications.append(application)
                    }
                } catch {
                    warnings.append("Unable to read \(normalized.lastPathComponent): \(error.localizedDescription)")
                    complete = false
                }
            }
        }
        return NativeInventoryResult(applications: applications.sorted { $0.path < $1.path }, warnings: warnings, complete: complete, scannedRoots: scannedRoots, candidatePaths: candidatePaths)
    }

    private func application(at url: URL, root: URL, classification: ApplicationClassification) throws -> NativeApplication? {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
        let plistURL = url.appending(path: "Contents/Info.plist")
        let plistValues = try plistURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard plistValues.isRegularFile == true, plistValues.isSymbolicLink != true else { throw NativeInventoryError.invalidMetadata }
        guard (plistValues.fileSize ?? 0) <= 1_048_576 else { throw NativeInventoryError.metadataTooLarge }
        let data = try Data(contentsOf: plistURL, options: [.mappedIfSafe])
        let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let metadata = propertyList as? [String: Any] else { throw NativeInventoryError.invalidMetadata }
        if let packageType = metadata["CFBundlePackageType"] as? String, packageType != "APPL" { return nil }
        let displayName = (metadata["CFBundleDisplayName"] as? String)?.nonEmpty ?? (metadata["CFBundleName"] as? String)?.nonEmpty ?? url.deletingPathExtension().lastPathComponent
        return NativeApplication(path: url.path, bundleIdentifier: (metadata["CFBundleIdentifier"] as? String)?.nonEmpty, displayName: displayName, shortVersion: (metadata["CFBundleShortVersionString"] as? String)?.nonEmpty, buildVersion: (metadata["CFBundleVersion"] as? String)?.nonEmpty, classification: classification, discoveryRoot: root.path)
    }

    public static func defaultRoots(fileManager: FileManager = .default) -> [NativeSearchRoot] {
        [
            NativeSearchRoot(url: URL(filePath: "/Applications", directoryHint: .isDirectory), classification: .user, required: true),
            NativeSearchRoot(url: fileManager.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory), classification: .user, required: false),
            NativeSearchRoot(url: URL(filePath: "/System/Applications", directoryHint: .isDirectory), classification: .system, required: true),
            NativeSearchRoot(url: URL(filePath: "/System/Library/CoreServices", directoryHint: .isDirectory), classification: .coreService, required: true),
            NativeSearchRoot(url: URL(filePath: "/Library/CoreServices", directoryHint: .isDirectory), classification: .coreService, required: false),
        ]
    }
}

public enum NativeInventoryError: LocalizedError { case metadataTooLarge, invalidMetadata
    public var errorDescription: String? { switch self { case .metadataTooLarge: "Bundle metadata exceeds the 1 MiB limit."; case .invalidMetadata: "Bundle metadata is not a property-list dictionary." } }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
