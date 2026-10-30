import Foundation
import SiftCore
import Darwin
import Synchronization

public enum SiftCLI {
    public static func run(arguments: [String]) -> Int32 {
        // The page renderer's child process; see PageRenderer.
        if arguments.count == 2, arguments[0] == "__render", let url = URL(string: arguments[1]), url.scheme?.lowercased() == "https" {
            return PageRenderer.main(url: url, timeout: 25)
        }
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
            if case let .sweep(filter) = invocation.command {
                // Changelog coverage report: every catalog item, its source, and how many entries.
                let databaseURL = invocation.databaseURL ?? SiftApplication.existingDefaultDatabaseURL()
                guard let databaseURL else { return EXIT_FAILURE }
                let database = try Database.writer(url: databaseURL)
                let service = ChangelogService(database: database, renderer: renderPage)
                let items = try database.catalogItems(includeAll: invocation.includeAll).filter { filter == nil || $0.updateSource == filter || $0.kind.rawValue == filter }
                let results = Mutex([(Int, String)]())
                DispatchQueue.concurrentPerform(iterations: items.count) { index in
                    let item = items[index]
                    let started = Date()
                    let line: String
                    switch Result(catching: { try service.changelog(for: item, refetch: invocation.fetch) }) {
                    case let .success(.changelog(changelog)):
                        line = ["ok", item.selector, item.updateSource ?? item.kind.rawValue, changelog.source, "\(changelog.entries.count)", "\(changelog.newEntries.count)", changelog.installedEntry == nil ? "no-installed-entry" : "", String(format: "%.1fs", Date().timeIntervalSince(started))].joined(separator: "\t")
                    case let .success(.unavailable(_, tried)):
                        line = ["MISS", item.selector, item.updateSource ?? item.kind.rawValue, "", "0", "0", tried.joined(separator: " | "), String(format: "%.1fs", Date().timeIntervalSince(started))].joined(separator: "\t")
                    case let .failure(error):
                        line = ["ERROR", item.selector, item.updateSource ?? item.kind.rawValue, "", "0", "0", error.localizedDescription, ""].joined(separator: "\t")
                    }
                    results.withLock { $0.append((index, line)) }
                    FileHandle.standardError.write(Data("\r\u{1B}[2K\(results.withLock { $0.count })/\(items.count) \(item.name.terminalInline)".utf8))
                }
                FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
                let lines = results.withLock { $0.sorted { $0.0 < $1.0 }.map(\.1) }
                print("status\tselector\tprovider\tsource\tentries\tnew\tdetail\ttime")
                lines.forEach { print($0.terminalInline) }
                let found = lines.filter { $0.hasPrefix("ok\t") }.count
                FileHandle.standardError.write(Data("changelogs found: \(found)/\(lines.count)\n".utf8))
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
                // Changelogs for what's new are fetched now, so `sift changelog` and `sift show`
                // answer from the cache; a failure here never fails the refresh.
                progress?("Fetching changelogs…")
                _ = try? ChangelogService(database: database, renderer: renderPage).prefetch { done, total in progress?("Fetching changelogs \(done)/\(total)…") }
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
            case let .log(selector):
                var entries = try database.updateLog(since: invocation.since, includeAll: invocation.includeAll || selector != nil)
                if let selector {
                    let item: CatalogItem? = switch try database.resolveCatalogItem(selector, includeAll: true) {
                    case let .item(item): item
                    case .missing: nil
                    case let .ambiguous(matches): throw InvocationError.ambiguousSelector(selector, matches.map(\.selector))
                    }
                    // A removed item has no catalog record left, so its log entries match by name.
                    let base = item.map { String($0.selector.prefix { $0 != "@" }) }
                    entries = entries.filter { entry in
                        if let base { return entry.selector == base }
                        return entry.selector.caseInsensitiveCompare(selector) == .orderedSame || entry.name.caseInsensitiveCompare(selector) == .orderedSame
                    }
                }
                print(invocation.json ? try LogRenderer.json(entries) : LogRenderer.humanReadable(entries, style: TerminalStyle(enabled: colorEnabled(invocation))))
                return EXIT_SUCCESS
            case let .changelog(name):
                let item: CatalogItem
                switch try database.resolveCatalogItem(name, includeAll: true) {
                case let .item(resolved): item = resolved
                case .missing: throw InvocationError.missingCatalogItem(name)
                case let .ambiguous(matches): throw InvocationError.ambiguousSelector(name, matches.map(\.selector))
                }
                let style = TerminalStyle(enabled: colorEnabled(invocation))
                let progress = refreshProgress(invocation)
                progress?("Fetching the changelog for \(item.name.terminalInline)…")
                let outcome = try ChangelogService(database: Database.writer(url: databaseURL), renderer: renderPage).changelog(for: item, refetch: invocation.fetch)
                progress?("")
                switch outcome {
                case let .changelog(changelog):
                    print(invocation.json ? try ChangelogRenderer.json(changelog) : ChangelogRenderer.humanReadable(changelog, all: invocation.includeAll, full: invocation.full, style: style))
                    return EXIT_SUCCESS
                case let .unavailable(itemName, tried):
                    print(invocation.json ? try JSONOutput.encode(["name": itemName, "changelog": nil as String?, "tried": tried.joined(separator: "\n")]) : ChangelogRenderer.unavailable(name: itemName, tried: tried, style: style))
                    return EXIT_FAILURE
                }
            case let .show(name):
                switch try database.resolveCatalogItem(name, includeAll: invocation.includeAll) {
                case let .item(item):
                    let notes = try releaseNotes(for: item, database: database)
                    if !invocation.json, let changelog = try ChangelogService.cached(for: item, database: database) {
                        print(CatalogRenderer.detail(item, changelog: changelog, style: TerminalStyle(enabled: colorEnabled(invocation))))
                    } else if let notes {
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
            case .complete, .sweep:
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
        case .log:
            let entries: [UpdateLogEntry] = []
            print(invocation.json ? try LogRenderer.json(entries) : LogRenderer.humanReadable(entries))
            return EXIT_SUCCESS
        case let .apps(.some(selector)), let .show(selector), let .changelog(selector):
            throw InvocationError.missingCatalogItem(selector)
        case .refresh, .completions, .complete, .sweep:
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
        case .nativeApp, .package: return nil
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

struct Invocation {
    enum Command { case dashboard, refresh, apps(String?), updates, log(String?), show(String), changelog(String), sweep(String?), completions(CompletionShell), complete(String, String) }

    static let usage = "Usage: sift [refresh|apps [name]|updates|log [name]|changelog <name>|show <name>|completions <fish|bash|zsh>] [--version] [--json] [--all] [--full] [--fetch] [--since <30d|2w|12h|YYYY-MM-DD>] [--no-color] [--update-homebrew|--no-update-homebrew] [--database <path>]"

    let command: Command
    let json: Bool
    let databaseURL: URL?
    let help: Bool
    let version: Bool
    let includeAll: Bool
    let full: Bool
    let noColor: Bool
    let updateHomebrew: Bool?
    let since: Date?
    let fetch: Bool

    init(arguments: [String], now: Date = .now) throws {
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
        var since: Date?
        var fetch = false
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
            case "--fetch":
                guard !fetch else { throw InvocationError.duplicateOption("--fetch") }
                fetch = true
            case "--since":
                guard since == nil else { throw InvocationError.duplicateOption("--since") }
                index += 1
                guard index < arguments.count, let date = Self.parseSince(arguments[index], now: now) else { throw InvocationError.invalidSince }
                since = date
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
            case "log", "changes":
                guard !hasCommand else { throw InvocationError.duplicateCommand }
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") {
                    index += 1
                    command = .log(arguments[index])
                } else {
                    command = .log(nil)
                }
                hasCommand = true
            case "changelog":
                guard !hasCommand else { throw InvocationError.duplicateCommand }
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("-") else { throw InvocationError.missingChangelogName }
                command = .changelog(arguments[index])
                hasCommand = true
            case "show":
                guard !hasCommand else { throw InvocationError.duplicateCommand }
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("-") else { throw InvocationError.missingShowPackage }
                command = .show(arguments[index])
                hasCommand = true
            case "__sweep":
                guard !hasCommand else { throw InvocationError.duplicateCommand }
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") {
                    index += 1
                    command = .sweep(arguments[index])
                } else {
                    command = .sweep(nil)
                }
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
        if fetch, !command.supportsFetch { throw InvocationError.optionNotSupported("--fetch", command: command) }
        if since != nil, !command.supportsSince { throw InvocationError.optionNotSupported("--since", command: command) }
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
        self.since = since
        self.fetch = fetch
    }

    /// `30d`, `2w`, `12h`, or a calendar date (`2026-10-01`, local midnight).
    static func parseSince(_ value: String, now: Date) -> Date? {
        if let unit = value.last, let amount = Int(value.dropLast()), amount >= 0 {
            let hours: Int? = switch unit {
            case "h": amount
            case "d": amount * 24
            case "w": amount * 24 * 7
            default: nil
            }
            if let hours { return now.addingTimeInterval(-TimeInterval(hours) * 60 * 60) }
        }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, value.split(separator: "-").count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

enum InvocationError: LocalizedError {
    case missingDatabasePath
    case duplicateOption(String)
    case duplicateCommand
    case unrecognizedArgument(String)
    case invalidCompletionShell
    case missingShowPackage
    case invalidSince
    case missingChangelogName
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
        case .missingChangelogName: "changelog requires the name of an app, game, or package."
        case .invalidSince: "--since requires a duration (30d, 2w, 12h) or a date (YYYY-MM-DD)."
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
        case .log: "log"
        case .show: "show"
        case .changelog: "changelog"
        case .completions: "completions"
        case .complete: "completion lookup"
        case .sweep: "changelog sweep"
        }
    }

    var supportsIncludeAll: Bool {
        switch self {
        case .apps, .log, .show, .changelog, .complete, .updates, .sweep: true
        case .dashboard, .refresh, .completions: false
        }
    }

    var supportsFull: Bool {
        switch self {
        case .show, .changelog, .sweep: true
        case .dashboard, .refresh, .apps, .updates, .log, .completions, .complete: false
        }
    }

    var supportsFetch: Bool {
        switch self {
        case .changelog, .sweep: true
        default: false
        }
    }

    var supportsSince: Bool {
        if case .log = self { return true }
        return false
    }

    var supportsUpdateHomebrew: Bool {
        switch self {
        case .refresh: true
        case .dashboard, .apps, .updates, .log, .show, .changelog, .sweep, .completions, .complete: false
        }
    }
}
