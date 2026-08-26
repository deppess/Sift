import Darwin
import Foundation

final class RefreshDatabaseLock {
    let lockURL: URL
    private let fileDescriptor: Int32

    init(databaseURL: URL) throws {
        lockURL = databaseURL.appendingPathExtension("refresh.lock")
        try validateDatabaseParentDirectory(lockURL.deletingLastPathComponent())
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw RefreshDatabaseLock.error(for: lockURL, errno: errno) }
        fileDescriptor = descriptor
        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else { throw RefreshDatabaseLock.error(for: lockURL, errno: errno) }
            guard (status.st_mode & S_IFMT) == S_IFREG, status.st_uid == getuid(), status.st_nlink == 1 else {
                throw DatabaseError.refreshLockUnavailable(lockURL, message: "Lock path is not a private regular file.")
            }
            guard fchmod(descriptor, 0o600) == 0 else { throw RefreshDatabaseLock.error(for: lockURL, errno: errno) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw RefreshDatabaseLock.error(for: lockURL, errno: errno) }
        } catch {
            close(descriptor)
            throw error
        }
    }

    deinit { close(fileDescriptor) }

    private static func error(for url: URL, errno: Int32) -> DatabaseError {
        if errno == EWOULDBLOCK || errno == EAGAIN { return .refreshInProgress(url) }
        return .refreshLockUnavailable(url, message: String(cString: strerror(errno)))
    }
}
