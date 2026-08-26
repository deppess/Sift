import Darwin
import Foundation

public enum SiftApplication {
    public static func existingDefaultDatabaseURL(fileManager: FileManager = .default) -> URL? {
        guard let directory = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).appending(path: "Sift", directoryHint: .isDirectory) else { return nil }
        let url = directory.appending(path: "sift.sqlite3", directoryHint: .notDirectory)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    public static func defaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        let directory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "Sift", directoryHint: .isDirectory)

        var status = stat()
        if lstat(directory.path, &status) != 0 {
            guard errno == ENOENT else {
                throw DatabaseError.unsafeFilesystemPath(directory, message: String(cString: strerror(errno)))
            }
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        try validateDatabaseParentDirectory(directory)
        return directory.appending(path: "sift.sqlite3", directoryHint: .notDirectory)
    }
}
