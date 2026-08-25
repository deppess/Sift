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
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let completed = DispatchSemaphore(value: 0)
        let outputGroup = DispatchGroup()
        let stdoutBox = DataBox(limit: outputLimit)
        let stderrBox = DataBox(limit: outputLimit)
        let stopper = ProcessStopper(process: process)
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
        process.terminationHandler = { _ in completed.signal() }
        do {
            try process.run()
        } catch {
            Self.closeReaders(stdout, stderr)
            _ = outputGroup.wait(timeout: .now() + 1)
            throw error
        }
        if completed.wait(timeout: .now() + timeout) == .timedOut {
            stopper.terminate()
            if completed.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 2)
            }
            Self.closeReaders(stdout, stderr)
            _ = outputGroup.wait(timeout: .now() + 1)
            throw CommandRunnerError.timedOut(executable)
        }
        if outputGroup.wait(timeout: .now() + 2) == .timedOut {
            Self.closeReaders(stdout, stderr)
            _ = outputGroup.wait(timeout: .now() + 1)
            throw CommandRunnerError.timedOut(executable)
        }
        let output = stdoutBox.value
        let errors = stderrBox.value
        guard !stdoutBox.exceededLimit, !stderrBox.exceededLimit else { throw CommandRunnerError.outputTooLarge(executable) }
        return CommandResult(status: process.terminationStatus, stdout: output, stderr: errors)
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
}

private final class ProcessStopper: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var requested = false

    init(process: Process) { self.process = process }

    func terminate() {
        lock.withLock {
            guard !requested else { return }
            requested = true
            if process.isRunning { process.terminate() }
        }
    }
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
