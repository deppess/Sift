import Foundation
import SiftCore

public enum SiftCLI {
    public static func run(arguments: [String]) -> Int32 {
        do {
            let invocation = try Invocation(arguments: arguments)
            if invocation.help {
                print(Invocation.usage)
                return EXIT_SUCCESS
            }
            if invocation.installCompletions {
                let destination = try CompletionInstaller.install()
                print("Installed \(destination.path)")
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
                let items = try database.catalogItems(includeAll: invocation.includeAll)
                let matches = items.filter { $0.selector.localizedCaseInsensitiveHasPrefix(prefix) || $0.aliases.contains { $0.localizedCaseInsensitiveHasPrefix(prefix) } }
                var aliasSelectors: [String: Set<String>] = [:]
                for item in items {
                    for alias in item.aliases { aliasSelectors[alias.lowercased(), default: []].insert(item.selector) }
                }
                for item in matches.prefix(200) {
                    let friendly = item.aliases.first { $0.localizedCaseInsensitiveHasPrefix(prefix) && aliasSelectors[$0.lowercased()]?.count == 1 }
                    let value = friendly ?? item.selector
                    print("\(value.completionSafe)\t\(item.name.completionSafe) · \(item.kind.rawValue) · \(item.installedVersion?.completionSafe ?? "unknown")")
                }
                return EXIT_SUCCESS
            }
            if case .refresh = invocation.command {
                let databaseURL = try invocation.databaseURL ?? SiftApplication.defaultDatabaseURL()
                let database = try Database(url: databaseURL)
                let summary = try RefreshCoordinator(database: database).refresh()
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
                let items = try database.catalogItems(includeAll: invocation.includeAll)
                if let selector {
                    switch try database.resolveCatalogItem(selector, includeAll: invocation.includeAll) {
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
                let updates = try database.homebrewUpdates()
                print(invocation.json ? try HomebrewRenderer.json(updates) : HomebrewRenderer.humanReadable(updates))
                return EXIT_SUCCESS
            case let .show(name):
                switch try database.resolveCatalogItem(name, includeAll: invocation.includeAll) {
                case let .item(item):
                    let notes = try releaseNotes(for: item, database: database)
                    if let notes {
                        print(invocation.json ? try CatalogRenderer.json(notes) : HomebrewRenderer.show(notes))
                    } else {
                        print(invocation.json ? try CatalogRenderer.json(item) : CatalogRenderer.detail(item, notes: nil))
                    }
                case .missing: throw InvocationError.missingCatalogItem(name)
                case let .ambiguous(matches): throw InvocationError.ambiguousSelector(name, matches.map(\.selector))
                }
                return EXIT_SUCCESS
            case .refresh:
                fatalError("Refresh commands return before opening a read-only database.")
            case .completions:
                fatalError("Completion commands return before opening a database.")
            case .complete:
                fatalError("Completion commands return before opening a database.")
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
            let updates: [HomebrewUpdate] = []
            print(invocation.json ? try HomebrewRenderer.json(updates) : HomebrewRenderer.humanReadable(updates))
            return EXIT_SUCCESS
        case let .apps(.some(selector)), let .show(selector):
            throw InvocationError.missingCatalogItem(selector)
        case .refresh, .completions, .complete:
            fatalError("Only cache-reading commands may have a missing cache.")
        }
    }

    private static func releaseNotes(for item: CatalogItem, database: Database) throws -> HomebrewReleaseNotes? {
        guard let prefix = item.prefix,
              let fullName = item.fullName,
              let installedVersion = item.installedVersion,
              let availableVersion = item.availableVersion else { return nil }
        let kind: HomebrewPackageKind = item.kind == .homebrewFormula ? .formula : item.kind == .homebrewCask ? .cask : .formula
        guard item.kind != .nativeApp else { return nil }
        return try database.homebrewReleaseNotes(prefix: prefix, kind: kind, fullName: fullName, installedVersion: installedVersion, availableVersion: availableVersion)
    }

    private static func writeError(_ message: String, usage: Bool = false) {
        let suffix = usage ? "\n\(Invocation.usage)" : ""
        FileHandle.standardError.write(Data("sift: \(message)\(suffix)\n".utf8))
    }
}

private extension JSONEncoder {
    static var sift: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension String {
    func localizedCaseInsensitiveHasPrefix(_ prefix: String) -> Bool {
        prefix.isEmpty || range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
    }

    var completionSafe: String {
        unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F && $0 != "\t" && $0 != "\n" && $0 != "\r" }.map(String.init).joined()
    }
}

private struct Invocation {
    enum Command { case dashboard, refresh, apps(String?), updates, show(String), completions(CompletionShell), complete(String, String) }

    static let usage = "Usage: sift [refresh|apps [name]|updates|show <package>] [--completions] [--json] [--all] [--no-color] [--database <path>]"

    let command: Command
    let json: Bool
    let databaseURL: URL?
    let help: Bool
    let includeAll: Bool
    let installCompletions: Bool

    init(arguments: [String]) throws {
        var command: Command = .dashboard
        var hasCommand = false
        var json = false
        var databaseURL: URL?
        var help = false
        var includeAll = false
        var installCompletions = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                help = true
            case "--json":
                guard !json else { throw InvocationError.duplicateOption("--json") }
                json = true
            case "--no-color":
                break
            case "--all":
                guard !includeAll else { throw InvocationError.duplicateOption("--all") }
                includeAll = true
            case "--completions":
                guard !installCompletions else { throw InvocationError.duplicateOption("--completions") }
                installCompletions = true
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
        self.command = command
        self.json = json
        self.databaseURL = databaseURL
        self.help = help
        self.includeAll = includeAll
        self.installCompletions = installCompletions
    }
}

private enum InvocationError: LocalizedError {
    case missingDatabasePath
    case duplicateOption(String)
    case duplicateCommand
    case unrecognizedArgument(String)
    case invalidCompletionShell
    case missingShowPackage
    case noCachedReleaseNotes(String)
    case missingCatalogItem(String)
    case ambiguousSelector(String, [String])
    case invalidCompletionRequest

    var errorDescription: String? {
        switch self {
        case .missingDatabasePath: "--database requires a path."
        case let .duplicateOption(option): "\(option) may only be specified once."
        case .duplicateCommand: "Only one command may be specified."
        case let .unrecognizedArgument(argument): "Unrecognized argument: \(argument)."
        case .invalidCompletionShell: "completions requires one of: fish, bash, zsh."
        case .missingShowPackage: "show requires a package name."
        case let .noCachedReleaseNotes(name): "No cached release notes for \(name). Run 'sift refresh' after an update becomes available."
        case let .missingCatalogItem(selector): "No cached software matches \(selector). Run 'sift refresh' to update the catalog."
        case let .ambiguousSelector(selector, matches): "\(selector) matches multiple records: \(matches.joined(separator: ", "))."
        case .invalidCompletionRequest: "__complete requires a target command."
        }
    }
}
