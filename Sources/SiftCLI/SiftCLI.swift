import Foundation
import SiftCore
import Darwin

public enum SiftCLI {
    public static func run(arguments: [String]) -> Int32 {
        do {
            let invocation = try Invocation(arguments: arguments)
            if invocation.help {
                print(Invocation.usage)
                return EXIT_SUCCESS
            }
            if invocation.version {
                print(invocation.json ? try JSONOutput.encode(["version": SiftVersion.current]) : "sift \(SiftVersion.current)")
                return EXIT_SUCCESS
            }
            if case let .completions(shell) = invocation.command {
                print(CompletionRenderer.script(for: shell), terminator: "\n")
                return EXIT_SUCCESS
            }
            if case let .complete(target, prefix) = invocation.command {
                guard target == "apps" || target == "show" else { return EXIT_SUCCESS }
                let databaseURL = invocation.databaseURL ?? SiftApplication.existingDefaultDatabaseURL()
                guard let databaseURL, FileManager.default.fileExists(atPath: databaseURL.path) else { return EXIT_SUCCESS }
                let database = try Database.readOnly(url: databaseURL)
                let items = try target == "show" ? database.catalogItems(includeAll: invocation.includeAll) : database.nativeApplicationItems(includeAll: invocation.includeAll)
                let matches = items.filter { $0.selector.localizedCaseInsensitiveHasPrefix(prefix) || $0.aliases.contains { $0.localizedCaseInsensitiveHasPrefix(prefix) } }
                var aliasSelectors: [String: Set<String>] = [:]
                for item in items {
                    for alias in item.aliases { aliasSelectors[alias.lowercased(), default: []].insert(item.selector) }
                }
                for item in matches.prefix(200) {
                    let friendly = item.aliases.first { $0.localizedCaseInsensitiveHasPrefix(prefix) && aliasSelectors[$0.lowercased()]?.count == 1 }
                    let value = friendly ?? item.selector
                    print("\(value.terminalInline)\t\(item.name.terminalInline) · \(item.kind.rawValue) · \(item.installedVersion?.terminalInline ?? "unknown")")
                }
                return EXIT_SUCCESS
            }
            if case .refresh = invocation.command {
                let databaseURL = try invocation.databaseURL ?? SiftApplication.defaultDatabaseURL()
                let database = try Database(url: databaseURL)
                let homebrewUpdate: HomebrewUpdatePolicy = switch invocation.updateHomebrew {
                case true?: .always
                case false?: .never
                case nil: .automatic()
                }
                let progress = refreshProgress(invocation)
                progress?("Refreshing…")
                let summary = try RefreshCoordinator(database: database).refresh(homebrewUpdate: homebrewUpdate, progress: progress)
                progress?("")
                print(invocation.json ? try RefreshRenderer.json(summary) : RefreshRenderer.humanReadable(summary))
                return summary.status == .success ? EXIT_SUCCESS : EXIT_FAILURE
            }
            let databaseURL = invocation.databaseURL ?? SiftApplication.existingDefaultDatabaseURL()
            guard let databaseURL, FileManager.default.fileExists(atPath: databaseURL.path) else {
                return try renderMissingCache(invocation)
            }
            let database = try Database.readOnly(url: databaseURL)
            switch invocation.command {
            case .dashboard:
                let dashboard = try database.dashboard()
                print(invocation.json ? try DashboardRenderer.json(dashboard) : DashboardRenderer.humanReadable(dashboard))
                return EXIT_SUCCESS
            case let .apps(selector):
                let items = try database.nativeApplicationItems(includeAll: invocation.includeAll)
                if let selector {
                    switch items.resolveCatalogItem(selector) {
                    case let .item(item):
                        let notes = try releaseNotes(for: item, database: database)
                        print(invocation.json ? try CatalogRenderer.json(item) : CatalogRenderer.detail(item, notes: notes))
                    case .missing: throw InvocationError.missingCatalogItem(selector)
                    case let .ambiguous(matches): throw InvocationError.ambiguousSelector(selector, matches.map(\.selector))
                    }
                } else {
                    print(invocation.json ? try CatalogRenderer.json(items) : CatalogRenderer.list(items))
                }
                return EXIT_SUCCESS
            case .updates:
                let updates = try database.updates(includeAll: invocation.includeAll)
                print(invocation.json ? try UpdatesRenderer.json(updates) : UpdatesRenderer.humanReadable(updates))
                return EXIT_SUCCESS
            case .changes:
                let changes = try database.nativeVersionTransitions(includeAll: invocation.includeAll)
                print(invocation.json ? try ChangesRenderer.json(changes) : ChangesRenderer.humanReadable(changes))
                return EXIT_SUCCESS
            case let .show(name):
                switch try database.resolveCatalogItem(name, includeAll: invocation.includeAll) {
                case let .item(item):
                    let notes = try releaseNotes(for: item, database: database)
                    if let notes {
                        print(invocation.json ? try CatalogRenderer.json(notes) : HomebrewRenderer.show(notes, full: invocation.full, style: TerminalStyle(enabled: colorEnabled(invocation))))
                    } else {
                        let nativeNotes = try item.kind == .nativeApp && item.updateAvailable ? item.path.flatMap { try database.nativeReleaseNotes(path: $0, targetVersion: item.availableVersion!) } : nil
                        print(invocation.json ? try CatalogRenderer.json(item) : CatalogRenderer.detail(item, notes: nil, nativeNotes: nativeNotes, full: invocation.full))
                    }
                case .missing: throw InvocationError.missingCatalogItem(name)
                case let .ambiguous(matches): throw InvocationError.ambiguousSelector(name, matches.map(\.selector))
                }
                return EXIT_SUCCESS
            case .refresh:
                return EXIT_FAILURE
            case .completions:
                return EXIT_FAILURE
            case .complete:
                return EXIT_FAILURE
            }
        } catch let error as InvocationError {
            writeError(error.localizedDescription, usage: true)
            return 2
        } catch {
            writeError(error.localizedDescription)
            return EXIT_FAILURE
        }
    }

    private static func renderMissingCache(_ invocation: Invocation) throws -> Int32 {
        switch invocation.command {
        case .dashboard:
            let dashboard = Dashboard(
                generatedAt: .now,
                lastAttemptAt: nil,
                dataAsOf: nil,
                freshness: .unknown,
                latestRefreshStatus: .never,
                data: DashboardData(availableUpdateCount: 0, recentTransitionCount: 0, failedProviderCount: 0)
            )
            print(invocation.json ? try DashboardRenderer.json(dashboard) : DashboardRenderer.humanReadable(dashboard))
            return EXIT_SUCCESS
        case .apps(nil):
            let items: [CatalogItem] = []
            print(invocation.json ? try CatalogRenderer.json(items) : CatalogRenderer.list(items))
            return EXIT_SUCCESS
        case .updates:
            let updates: [UnifiedUpdate] = []
            print(invocation.json ? try UpdatesRenderer.json(updates) : UpdatesRenderer.humanReadable(updates))
            return EXIT_SUCCESS
        case .changes:
            let changes: [NativeVersionTransition] = []
            print(invocation.json ? try ChangesRenderer.json(changes) : ChangesRenderer.humanReadable(changes))
            return EXIT_SUCCESS
        case let .apps(.some(selector)), let .show(selector):
            throw InvocationError.missingCatalogItem(selector)
        case .refresh, .completions, .complete:
            return EXIT_FAILURE
        }
    }

    /// A status line on a terminal while the refresh runs; each message replaces the last, and an
    /// empty one clears it.
    private static func refreshProgress(_ invocation: Invocation) -> (@Sendable (String) -> Void)? {
        guard !invocation.json, isatty(STDERR_FILENO) == 1 else { return nil }
        return { message in FileHandle.standardError.write(Data("\r\u{1B}[2K\(message)".utf8)) }
    }

    private static func colorEnabled(_ invocation: Invocation) -> Bool {
        !invocation.noColor && isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    }

    private static func releaseNotes(for item: CatalogItem, database: Database) throws -> HomebrewReleaseNotes? {
        let kind: HomebrewPackageKind
        switch item.kind {
        case .homebrewFormula: kind = .formula
        case .homebrewCask: kind = .cask
        case .nativeApp: return nil
        }
        guard let prefix = item.prefix, let fullName = item.fullName, let installedVersion = item.installedVersion, let availableVersion = item.availableVersion else { return nil }
        return try database.homebrewReleaseNotes(prefix: prefix, kind: kind, fullName: fullName, installedVersion: installedVersion, availableVersion: availableVersion)
    }

    private static func writeError(_ message: String, usage: Bool = false) {
        let suffix = usage ? "\n\(Invocation.usage)" : ""
        FileHandle.standardError.write(Data("sift: \(message.terminalInline)\(suffix)\n".utf8))
    }
}

extension String {
    func localizedCaseInsensitiveHasPrefix(_ prefix: String) -> Bool {
        prefix.isEmpty || range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
    }
}

private struct Invocation {
    enum Command { case dashboard, refresh, apps(String?), updates, changes, show(String), completions(CompletionShell), complete(String, String) }

    static let usage = "Usage: sift [refresh|apps [name]|updates|changes|show <package>|completions <fish|bash|zsh>] [--version] [--json] [--all] [--full] [--no-color] [--update-homebrew|--no-update-homebrew] [--database <path>]"

    let command: Command
    let json: Bool
    let databaseURL: URL?
    let help: Bool
    let version: Bool
    let includeAll: Bool
    let full: Bool
    let noColor: Bool
    let updateHomebrew: Bool?

    init(arguments: [String]) throws {
        var command: Command = .dashboard
        var hasCommand = false
        var json = false
        var databaseURL: URL?
        var help = false
        var version = false
        var includeAll = false
        var full = false
        var noColor = false
        var updateHomebrew: Bool?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                help = true
            case "--version":
                guard !version else { throw InvocationError.duplicateOption("--version") }
                version = true
            case "--json":
                guard !json else { throw InvocationError.duplicateOption("--json") }
                json = true
            case "--no-color":
                guard !noColor else { throw InvocationError.duplicateOption("--no-color") }
                noColor = true
            case "--full":
                guard !full else { throw InvocationError.duplicateOption("--full") }
                full = true
            case "--all":
                guard !includeAll else { throw InvocationError.duplicateOption("--all") }
                includeAll = true
            case "--update-homebrew":
                guard updateHomebrew == nil else { throw InvocationError.duplicateOption(argument) }
                updateHomebrew = true
            case "--no-update-homebrew":
                guard updateHomebrew == nil else { throw InvocationError.duplicateOption(argument) }
                updateHomebrew = false
            case "--database":
                guard databaseURL == nil else { throw InvocationError.duplicateOption("--database") }
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("-") else { throw InvocationError.missingDatabasePath }
                databaseURL = URL(filePath: arguments[index])
            case "refresh":
                guard !hasCommand else { throw InvocationError.duplicateCommand }
                command = .refresh
                hasCommand = true
            case "apps":
                guard !hasCommand else { throw InvocationError.duplicateCommand }
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") {
                    index += 1
                    command = .apps(arguments[index])
                } else {
                    command = .apps(nil)
                }
                hasCommand = true
            case "updates":
                guard !hasCommand else { throw InvocationError.duplicateCommand }
                command = .updates
                hasCommand = true
            case "changes":
                guard !hasCommand else { throw InvocationError.duplicateCommand }
                command = .changes
                hasCommand = true
            case "show":
                guard !hasCommand else { throw InvocationError.duplicateCommand }
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("-") else { throw InvocationError.missingShowPackage }
                command = .show(arguments[index])
                hasCommand = true
            case "__complete":
                guard !hasCommand else { throw InvocationError.duplicateCommand }
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("-") else { throw InvocationError.invalidCompletionRequest }
                let target = arguments[index]
                index += 1
                let prefix = index < arguments.count && !arguments[index].hasPrefix("-") ? arguments[index] : ""
                command = .complete(target, prefix)
                hasCommand = true
            case "completions":
                guard !hasCommand else { throw InvocationError.duplicateCommand }
                index += 1
                guard index < arguments.count, let shell = CompletionShell(rawValue: arguments[index]) else { throw InvocationError.invalidCompletionShell }
                command = .completions(shell)
                hasCommand = true
            default:
                throw InvocationError.unrecognizedArgument(argument)
            }
            index += 1
        }
        if includeAll, !command.supportsIncludeAll { throw InvocationError.optionNotSupported("--all", command: command) }
        if full, !command.supportsFull { throw InvocationError.optionNotSupported("--full", command: command) }
        if let updateHomebrew, !command.supportsUpdateHomebrew { throw InvocationError.optionNotSupported(updateHomebrew ? "--update-homebrew" : "--no-update-homebrew", command: command) }
        self.command = command
        self.json = json
        self.databaseURL = databaseURL
        self.help = help
        self.version = version
        self.includeAll = includeAll
        self.full = full
        self.noColor = noColor
        self.updateHomebrew = updateHomebrew
    }
}

private enum InvocationError: LocalizedError {
    case missingDatabasePath
    case duplicateOption(String)
    case duplicateCommand
    case unrecognizedArgument(String)
    case invalidCompletionShell
    case missingShowPackage
    case missingCatalogItem(String)
    case ambiguousSelector(String, [String])
    case invalidCompletionRequest
    case optionNotSupported(String, command: Invocation.Command)

    var errorDescription: String? {
        switch self {
        case .missingDatabasePath: "--database requires a path."
        case let .duplicateOption(option): "\(option) may only be specified once."
        case .duplicateCommand: "Only one command may be specified."
        case let .unrecognizedArgument(argument): "Unrecognized argument: \(argument)."
        case .invalidCompletionShell: "completions requires one of: fish, bash, zsh."
        case .missingShowPackage: "show requires a package name."
        case let .missingCatalogItem(selector): "No cached software matches \(selector). Run 'sift refresh' to update the catalog."
        case let .ambiguousSelector(selector, matches): "\(selector) matches multiple records: \(matches.joined(separator: ", "))."
        case .invalidCompletionRequest: "__complete requires a target command."
        case let .optionNotSupported(option, command): "\(option) is not supported with \(command.description)."
        }
    }
}

private extension Invocation.Command {
    var description: String {
        switch self {
        case .dashboard: "the dashboard"
        case .refresh: "refresh"
        case .apps: "apps"
        case .updates: "updates"
        case .changes: "changes"
        case .show: "show"
        case .completions: "completions"
        case .complete: "completion lookup"
        }
    }

    var supportsIncludeAll: Bool {
        switch self {
        case .apps, .changes, .show, .complete, .updates: true
        case .dashboard, .refresh, .completions: false
        }
    }

    var supportsFull: Bool {
        switch self {
        case .show: true
        case .dashboard, .refresh, .apps, .updates, .changes, .completions, .complete: false
        }
    }

    var supportsUpdateHomebrew: Bool {
        switch self {
        case .refresh: true
        case .dashboard, .apps, .updates, .changes, .show, .completions, .complete: false
        }
    }
}
