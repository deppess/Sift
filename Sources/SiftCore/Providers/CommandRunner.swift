import Darwin
import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
}

public enum CommandRunnerError: LocalizedError {
    case notExecutable(URL)
    case timedOut(URL)
    case outputTooLarge(URL)

    public var errorDescription: String? {
        switch self {
        case let .notExecutable(url): "Executable is unavailable: \(url.path)"
        case let .timedOut(url): "Command timed out: \(url.path)"
        case let .outputTooLarge(url): "Command output exceeded the configured limit: \(url.path)"
        }
    }
}

/// Validates an absolute filesystem path (a PATH entry, a reported prefix, a tool directory) before it's
/// used to build an executable URL or stored. Shared by HomebrewProvider, NPMGlobalProvider, and
/// UVToolProvider, whose PATH-derived directories all need the same hardening: rooted, no `..` traversal,
/// no control characters that could confuse a terminal or a downstream shell.
func isSafeAbsolutePath(_ value: String) -> Bool {
    value.hasPrefix("/") && !value.split(separator: "/").contains("..") && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
}

/// Finds candidate executables named `name` in `standardDirectories` and every PATH-derived directory,
/// resolves symlinks, and deduplicates by resolved path. Shared by HomebrewProvider, NPMGlobalProvider,
/// and UVToolProvider, whose provider-discovery scan is otherwise identical (only the executable name
/// and default `standardDirectories` differ).
func discoverExecutables(named name: String, standardDirectories: [String], environment: [String: String]) -> [URL] {
    var candidates = standardDirectories.map { URL(filePath: $0, directoryHint: .isDirectory).appending(path: name) }
    if let path = environment["PATH"] {
        candidates += path.split(separator: ":").compactMap { entry in
            let directory = String(entry)
            guard isSafeAbsolutePath(directory) else { return nil }
            return URL(filePath: directory, directoryHint: .isDirectory).appending(path: name)
        }
    }
    var seen = Set<String>()
    return candidates.compactMap { candidate in
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard isRegularExecutable(resolved), seen.insert(resolved.path).inserted else { return nil }
        return resolved
    }
}

func isRegularExecutable(_ url: URL) -> Bool {
    FileManager.default.isExecutableFile(atPath: url.path) && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
}

public struct CommandRunner: Sendable {
    public init() {}

    public func run(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval = 30, outputLimit: Int = 16 * 1_024 * 1_024) throws -> CommandResult {
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else { throw CommandRunnerError.notExecutable(executable) }
        guard timeout > 0, outputLimit > 0 else { throw CommandRunnerError.outputTooLarge(executable) }
        let stdout = Pipe()
        let stderr = Pipe()
        let completed = DispatchSemaphore(value: 0)
        let outputGroup = DispatchGroup()
        let stdoutBox = DataBox(limit: outputLimit)
        let stderrBox = DataBox(limit: outputLimit)
        let stopper = ProcessStopper()
        outputGroup.enter()
        DispatchQueue.global().async {
            Self.read(pipe: stdout.fileHandleForReading, into: stdoutBox, stopper: stopper)
            outputGroup.leave()
        }
        outputGroup.enter()
        DispatchQueue.global().async {
            Self.read(pipe: stderr.fileHandleForReading, into: stderrBox, stopper: stopper)
            outputGroup.leave()
        }
        let processIdentifier: pid_t
        do {
            processIdentifier = try Self.spawn(executable: executable, arguments: arguments, environment: environment, stdout: stdout, stderr: stderr)
        } catch {
            Self.closeReaders(stdout, stderr)
            _ = outputGroup.wait(timeout: .now() + 0.5)
            throw error
        }
        stopper.setProcessGroup(processIdentifier)
        Self.closeWriters(stdout, stderr)
        let status = StatusBox()
        DispatchQueue.global().async {
            var value: Int32 = 0
            var result: pid_t
            repeat {
                result = waitpid(processIdentifier, &value, 0)
            } while result == -1 && errno == EINTR
            if result == -1 {
                status.setWaitError(errno)
            } else {
                status.set(value)
            }
            completed.signal()
        }
        if completed.wait(timeout: .now() + timeout) == .timedOut {
            stopper.terminate()
            _ = completed.wait(timeout: .now() + 0.5)
            stopper.kill()
            _ = completed.wait(timeout: .now() + 0.5)
            Self.finishPipes(stdout, stderr, outputGroup: outputGroup)
            throw CommandRunnerError.timedOut(executable)
        }
        if stdoutBox.exceededLimit || stderrBox.exceededLimit {
            stopper.terminate()
            _ = completed.wait(timeout: .now() + 0.5)
            stopper.kill()
            Self.finishPipes(stdout, stderr, outputGroup: outputGroup)
            throw CommandRunnerError.outputTooLarge(executable)
        }
        if outputGroup.wait(timeout: .now() + 2) == .timedOut {
            stopper.terminate()
            _ = completed.wait(timeout: .now() + 0.5)
            stopper.kill()
            Self.finishPipes(stdout, stderr, outputGroup: outputGroup)
            throw CommandRunnerError.timedOut(executable)
        }
        let output = stdoutBox.value
        let errors = stderrBox.value
        guard !stdoutBox.exceededLimit, !stderrBox.exceededLimit else { throw CommandRunnerError.outputTooLarge(executable) }
        if let error = status.waitError { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
        return CommandResult(status: Self.terminationStatus(status.value), stdout: output, stderr: errors)
    }

    private static func read(pipe: FileHandle, into box: DataBox, stopper: ProcessStopper) {
        defer { try? pipe.close() }
        while true {
            guard let data = try? pipe.read(upToCount: 64 * 1_024), !data.isEmpty else { return }
            if !box.append(data) {
                stopper.terminate()
                return
            }
        }
    }

    private static func closeReaders(_ stdout: Pipe, _ stderr: Pipe) {
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
    }

    private static func closeWriters(_ stdout: Pipe, _ stderr: Pipe) {
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
    }

    private static func finishPipes(_ stdout: Pipe, _ stderr: Pipe, outputGroup: DispatchGroup) {
        closeReaders(stdout, stderr)
        _ = outputGroup.wait(timeout: .now() + 0.5)
    }

    private static func spawn(executable: URL, arguments: [String], environment: [String: String], stdout: Pipe, stderr: Pipe) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard posix_spawnattr_init(&attributes) == 0 else {
            posix_spawn_file_actions_destroy(&actions)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        // CLOEXEC_DEFAULT closes every descriptor not set up below in the child, so it never holds
        // the database, another command's pipe (which would delay that command's end of output), or
        // the terminal. Standard input is /dev/null: nothing Sift runs may wait on a prompt.
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        let command = [executable.path] + arguments
        let variables = environment.map { "\($0.key)=\($0.value)" }
        let argv = command.map { $0.withCString { strdup($0) } } + [nil]
        let envp = variables.map { $0.withCString { strdup($0) } } + [nil]
        defer {
            argv.dropLast().forEach { free($0) }
            envp.dropLast().forEach { free($0) }
        }
        var processIdentifier: pid_t = 0
        let result = posix_spawn(&processIdentifier, executable.path, &actions, &attributes, argv, envp)
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
        return processIdentifier
    }

    private static func terminationStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        if signal != 0x7f { return 128 + signal }
        return status
    }
}

private final class ProcessStopper: @unchecked Sendable {
    private let lock = NSLock()
    private var processGroup: pid_t?
    private var requested = false

    func setProcessGroup(_ processGroup: pid_t) {
        lock.withLock { self.processGroup = processGroup }
    }

    func terminate() {
        lock.withLock {
            guard !requested else { return }
            requested = true
            if let processGroup { _ = Darwin.kill(-processGroup, SIGTERM) }
        }
    }

    func kill() {
        lock.withLock {
            if let processGroup { _ = Darwin.kill(-processGroup, SIGKILL) }
        }
    }
}

private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int32 = 0
    private var waitFailure: Int32?

    var value: Int32 { lock.withLock { storage } }
    var waitError: Int32? { lock.withLock { waitFailure } }
    func set(_ value: Int32) { lock.withLock { storage = value } }
    func setWaitError(_ value: Int32) { lock.withLock { waitFailure = value } }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var exceeded = false

    init(limit: Int) { self.limit = limit }

    var value: Data { lock.withLock { storage } }
    var exceededLimit: Bool { lock.withLock { exceeded } }

    func append(_ data: Data) -> Bool {
        lock.withLock {
            guard !exceeded, data.count <= limit, storage.count <= limit - data.count else {
                exceeded = true
                return false
            }
            storage.append(data)
            return true
        }
    }
}
