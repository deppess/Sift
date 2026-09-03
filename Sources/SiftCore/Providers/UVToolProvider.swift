import Foundation

public struct UVToolEntrypoint: Codable, Equatable, Sendable {
    public let name: String
    public let installPath: String

    public init(name: String, installPath: String) {
        self.name = name
        self.installPath = installPath
    }
}

public struct UVTool: Codable, Equatable, Sendable {
    public let name: String
    public let installedVersion: String
    public let versionSpecifier: String?
    public let python: String
    public let environmentPath: String
    public let entrypoints: [UVToolEntrypoint]
    public let latestVersion: String?

    public init(name: String, installedVersion: String, versionSpecifier: String?, python: String, environmentPath: String, entrypoints: [UVToolEntrypoint], latestVersion: String? = nil) {
        self.name = name
        self.installedVersion = installedVersion
        self.versionSpecifier = versionSpecifier
        self.python = python
        self.environmentPath = environmentPath
        self.entrypoints = entrypoints
        self.latestVersion = latestVersion
    }
}

public struct UVToolInstallation: Codable, Equatable, Sendable {
    public let executablePath: String
    public let toolDirectory: String
    public let tools: [UVTool]
    public let outdatedTools: [UVTool]

    public init(executablePath: String, toolDirectory: String, tools: [UVTool], outdatedTools: [UVTool]) {
        self.executablePath = executablePath
        self.toolDirectory = toolDirectory
        self.tools = tools
        self.outdatedTools = outdatedTools
    }
}

public struct UVToolInventory: Codable, Equatable, Sendable {
    public let installations: [UVToolInstallation]

    public init(installations: [UVToolInstallation]) {
        self.installations = installations
    }
}

public enum UVToolProviderError: LocalizedError {
    case commandFailed(executable: URL, command: String, status: Int32)
    case invalidToolDirectory
    case invalidInventory
    case invalidOutdated

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(executable, command, status):
            "uv command failed (\(status)): \(executable.path) \(command)"
        case .invalidToolDirectory:
            "uv returned an invalid tool directory."
        case .invalidInventory:
            "uv returned a malformed tool inventory."
        case .invalidOutdated:
            "uv returned a malformed outdated-tool snapshot."
        }
    }
}

public struct UVToolProvider {
    private let runner: CommandRunner
    private let environment: [String: String]

    public init(runner: CommandRunner = CommandRunner(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.runner = runner
        // CommandRunner cannot select a working directory; prevent cwd and user config discovery.
        self.environment = environment.merging(["LC_ALL": "C", "NO_COLOR": "1", "UV_NO_CONFIG": "1", "UV_NO_PROGRESS": "1"]) { _, replacement in replacement }
    }

    public func discover() throws -> UVToolInventory {
        try UVToolInventory(installations: executables().map { executable in
            let directoryResult = try run(executable, command: "tool dir", arguments: ["tool", "dir"])
            let toolDirectory = try parseToolDirectory(directoryResult.stdout)
            let listResult = try run(executable, command: "tool list", arguments: listArguments)
            let tools = try Self.parseToolList(listResult.stdout, outdated: false)
            let outdatedResult = try run(executable, command: "tool list --outdated", arguments: listArguments + ["--outdated"])
            let outdatedTools = try Self.parseToolList(outdatedResult.stdout, outdated: true)
            guard Set(outdatedTools.map(\.name)).isSubset(of: Set(tools.map(\.name))) else { throw UVToolProviderError.invalidOutdated }
            return UVToolInstallation(executablePath: executable.path, toolDirectory: toolDirectory, tools: tools, outdatedTools: outdatedTools)
        }.sorted { $0.toolDirectory < $1.toolDirectory })
    }

    private var listArguments: [String] {
        ["tool", "list", "--show-paths", "--show-version-specifiers", "--show-python", "--color", "never", "--no-config"]
    }

    private func run(_ executable: URL, command: String, arguments: [String]) throws -> CommandResult {
        let result = try runner.run(executable: executable, arguments: arguments, environment: environment)
        guard result.status == 0 else { throw UVToolProviderError.commandFailed(executable: executable, command: command, status: result.status) }
        return result
    }

    private func executables() -> [URL] {
        var candidates = [URL(filePath: "/opt/homebrew/bin/uv"), URL(filePath: "/usr/local/bin/uv"), URL(filePath: "/usr/bin/uv")]
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").compactMap { entry in
                let directory = String(entry)
                guard Self.isSafeAbsolutePath(directory) else { return nil }
                return URL(filePath: directory, directoryHint: .isDirectory).appending(path: "uv")
            }
        }
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard isRegularExecutable(resolved), seen.insert(resolved.path).inserted else { return nil }
            return resolved
        }
    }

    private func isRegularExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path) && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func parseToolDirectory(_ data: Data) throws -> String {
        let output = String(decoding: data, as: UTF8.self)
        guard output.last == "\n", output.dropLast().contains("\n") == false else { throw UVToolProviderError.invalidToolDirectory }
        return try Self.normalizedPath(String(output.dropLast()), allowTilde: false, error: .invalidToolDirectory)
    }

    static func parseToolList(_ data: Data, outdated: Bool) throws -> [UVTool] {
        let output = String(decoding: data, as: UTF8.self)
        guard !output.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" || $0.value == 0x7F }) else { throw outdated ? UVToolProviderError.invalidOutdated : UVToolProviderError.invalidInventory }
        if output == "No tools installed\n" { return [] }
        if output.isEmpty { return [] }
        guard output.last == "\n" else { throw outdated ? UVToolProviderError.invalidOutdated : UVToolProviderError.invalidInventory }
        let lines = output.dropLast().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var tools: [UVTool] = []
        var index = 0
        while index < lines.count {
            let header = lines[index]
            guard !header.isEmpty else { throw outdated ? UVToolProviderError.invalidOutdated : UVToolProviderError.invalidInventory }
            var tool = try parseHeader(header, outdated: outdated)
            index += 1
            var entrypoints: [UVToolEntrypoint] = []
            while index < lines.count, lines[index].hasPrefix("- ") {
                entrypoints.append(try parseEntrypoint(lines[index], outdated: outdated))
                index += 1
            }
            guard !entrypoints.isEmpty, Set(entrypoints.map(\.name)).count == entrypoints.count else { throw outdated ? UVToolProviderError.invalidOutdated : UVToolProviderError.invalidInventory }
            tool = UVTool(name: tool.name, installedVersion: tool.installedVersion, versionSpecifier: tool.versionSpecifier, python: tool.python, environmentPath: tool.environmentPath, entrypoints: entrypoints, latestVersion: tool.latestVersion)
            tools.append(tool)
        }
        guard Set(tools.map(\.name)).count == tools.count else { throw outdated ? UVToolProviderError.invalidOutdated : UVToolProviderError.invalidInventory }
        return tools.sorted { $0.name < $1.name }
    }

    private static func parseHeader(_ line: String, outdated: Bool) throws -> UVTool {
        let error: UVToolProviderError = outdated ? .invalidOutdated : .invalidInventory
        guard let versionMarker = line.range(of: " v"), isSafeName(String(line[..<versionMarker.lowerBound])) else { throw error }
        let name = String(line[..<versionMarker.lowerBound])
        var remainder = String(line[versionMarker.upperBound...])
        guard let firstSpace = remainder.firstIndex(of: " "), isSafeValue(String(remainder[..<firstSpace])) else { throw error }
        let installedVersion = String(remainder[..<firstSpace])
        remainder = String(remainder[firstSpace...])
        let required = try takeField("required: ", from: &remainder, error: error)
        guard let python = try takeField(nil, from: &remainder, error: error), isSafePython(python) else { throw error }
        let latest = try takeField("latest: ", from: &remainder, error: error)
        guard (outdated ? latest != nil : latest == nil), remainder.hasPrefix(" ("), remainder.hasSuffix(")") else { throw error }
        let environmentPath = try normalizedPath(String(remainder.dropFirst(2).dropLast()), allowTilde: true, error: error)
        return UVTool(name: name, installedVersion: installedVersion, versionSpecifier: required, python: python, environmentPath: environmentPath, entrypoints: [], latestVersion: latest)
    }

    private static func takeField(_ label: String?, from remainder: inout String, error: UVToolProviderError) throws -> String? {
        guard remainder.hasPrefix(" [") else { return nil }
        guard let end = remainder.range(of: "]") else { throw error }
        let value = String(remainder[remainder.index(remainder.startIndex, offsetBy: 2)..<end.lowerBound])
        guard !value.isEmpty, isSafeValue(value) else { throw error }
        if let label {
            guard value.hasPrefix(label), value.count > label.count else { return nil }
            let field = String(value.dropFirst(label.count))
            guard isSafeValue(field) else { throw error }
            remainder = String(remainder[end.upperBound...])
            return field
        }
        remainder = String(remainder[end.upperBound...])
        return value
    }

    private static func parseEntrypoint(_ line: String, outdated: Bool) throws -> UVToolEntrypoint {
        let error: UVToolProviderError = outdated ? .invalidOutdated : .invalidInventory
        guard line.hasPrefix("- "), let pathStart = line.range(of: " (", options: .backwards), line.hasSuffix(")") else { throw error }
        let name = String(line[line.index(line.startIndex, offsetBy: 2)..<pathStart.lowerBound])
        guard isSafeName(name) else { throw error }
        return UVToolEntrypoint(name: name, installPath: try normalizedPath(String(line[pathStart.upperBound...].dropLast()), allowTilde: true, error: error))
    }

    private static func isSafeName(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A) || $0 == "-" || $0 == "_" || $0 == "." }
    }

    private static func isSafeValue(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("[") && !value.contains("]") && !value.contains("(") && !value.contains(")") && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static func isSafePython(_ value: String) -> Bool {
        let components = value.split(separator: " ", omittingEmptySubsequences: false)
        return components.count == 2 && !components.contains("") && isSafeName(String(components[0])) && isSafeValue(String(components[1]))
    }

    private static func normalizedPath(_ value: String, allowTilde: Bool, error: UVToolProviderError) throws -> String {
        let path: String
        if allowTilde, value.hasPrefix("~/") { path = FileManager.default.homeDirectoryForCurrentUser.appending(path: String(value.dropFirst(2))).path }
        else { path = value }
        guard isSafeAbsolutePath(path) else { throw error }
        return URL(filePath: path).standardizedFileURL.path
    }

    private static func isSafeAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.split(separator: "/").contains("..") && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}
