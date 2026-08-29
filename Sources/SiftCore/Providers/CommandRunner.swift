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

public struct CommandRunner {
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
            _ = waitpid(processIdentifier, &value, 0)
            status.set(value)
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
        let flags = Int16(POSIX_SPAWN_SETPGROUP)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, stdout.fileHandleForReading.fileDescriptor) == 0,
              posix_spawn_file_actions_addclose(&actions, stderr.fileHandleForReading.fileDescriptor) == 0 else {
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

    var value: Int32 { lock.withLock { storage } }
    func set(_ value: Int32) { lock.withLock { storage = value } }
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
