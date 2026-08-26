import Darwin
import Foundation

enum CompletionShell: String {
    case fish
    case bash
    case zsh
}

enum CompletionRenderer {
    static func script(for shell: CompletionShell) -> String {
        switch shell {
        case .fish:
            """
            complete -c sift -f
            complete -c sift -n '__fish_use_subcommand' -a refresh -d 'Refresh native application inventory'
            complete -c sift -n '__fish_use_subcommand' -a apps -d 'Show cached applications'
            complete -c sift -n '__fish_use_subcommand' -a updates -d 'Show cached Homebrew updates'
            complete -c sift -n '__fish_use_subcommand' -a show -d 'Show cached release notes'
            complete -c sift -s h -l help -d 'Show usage'
            complete -c sift -l json -d 'Render JSON'
            complete -c sift -l all -d 'Include CoreServices and inactive applications'
            complete -c sift -l no-color -d 'Disable color output'
            complete -c sift -l database -r -F -d 'Use a database path'
            complete -c sift -l completions -d 'Install shell completions'
            complete -c sift -n '__fish_seen_subcommand_from apps show' -a '(sift __complete apps (commandline -ct))'
            """
        case .bash:
            """
            _sift() {
                local current previous words
                COMPREPLY=()
                current="${COMP_WORDS[COMP_CWORD]}"
                previous="${COMP_WORDS[COMP_CWORD-1]}"
                words="refresh apps updates show --help -h --completions --json --all --no-color --database"
                if [[ "${COMP_WORDS[1]}" == "apps" || "${COMP_WORDS[1]}" == "show" ]]; then
                    while IFS=$'\t' read -r value description; do
                        COMPREPLY[${#COMPREPLY[@]}]="$value"
                    done < <(sift __complete apps "$current")
                elif [[ "$previous" == "--database" ]]; then
                    while IFS= read -r value; do
                        COMPREPLY[${#COMPREPLY[@]}]="$value"
                    done < <(compgen -f -- "$current")
                else
                    while IFS= read -r value; do
                        COMPREPLY[${#COMPREPLY[@]}]="$value"
                    done < <(compgen -W "$words" -- "$current")
                fi
            }
            complete -F _sift sift
            """
        case .zsh:
            """
            #compdef sift

            _sift() {
                local -a commands
                commands=(
                    'refresh:Refresh native application inventory'
                    'apps:Show cached applications'
                    'updates:Show cached Homebrew updates'
                    'show:Show cached release notes'
                )
                _arguments -C \
                    '--json[Render JSON]' \
                    '--all[Include CoreServices and inactive applications]' \
                    '--no-color[Disable color output]' \
                    '--database=[Use a database path]:database path:_files' \
                    '--completions[Install shell completions]' \
                    '(-h --help)'{-h,--help}'[Show usage]' \
                    '1:command:->command' \
                    '2:argument:->argument'
                case $state in
                    command) _describe -t commands command "$commands" ;;
                    argument) case $words[2] in
                        apps|show)
                            local -a candidates
                            local value description
                            while IFS=$'\t' read -r value description; do
                                candidates+=("$value")
                            done < <(sift __complete apps "$words[CURRENT]")
                            compadd -Q -- $candidates
                            ;;
                    esac ;;
                esac
            }
            """
        }
    }
}

enum CompletionInstaller {
    static func install(environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default) throws -> URL {
        guard let shell = detectedShell(environment: environment) else { throw CompletionInstallError.unsupportedShell(environment["SHELL"]) }
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        let destination: URL
        switch shell {
        case .fish:
            let config = try configuredDirectory(environment["XDG_CONFIG_HOME"], default: home.appending(path: ".config", directoryHint: .isDirectory), name: "XDG_CONFIG_HOME", fileManager: fileManager)
            destination = config.appending(path: "fish/completions/sift.fish", directoryHint: .notDirectory)
        case .bash:
            let data: URL
            if let path = environment["BASH_COMPLETION_USER_DIR"] {
                data = try configuredDirectory(path, name: "BASH_COMPLETION_USER_DIR", fileManager: fileManager)
            } else if let path = environment["XDG_DATA_HOME"] {
                data = try configuredDirectory(path, name: "XDG_DATA_HOME", fileManager: fileManager).appending(path: "bash-completion", directoryHint: .isDirectory)
            } else {
                data = home.appending(path: ".local/share/bash-completion", directoryHint: .isDirectory)
            }
            destination = data.appending(path: "completions/sift", directoryHint: .notDirectory)
        case .zsh:
            let zdotdir = try configuredDirectory(environment["ZDOTDIR"], default: home, name: "ZDOTDIR", fileManager: fileManager)
            let directory = zdotdir.appending(path: ".zfunc", directoryHint: .isDirectory)
            destination = directory.appending(path: "_sift", directoryHint: .notDirectory)
        }
        try createPrivateDirectory(at: destination.deletingLastPathComponent(), fileManager: fileManager)
        try validateDestination(destination, fileManager: fileManager)
        try CompletionRenderer.script(for: shell).write(to: destination, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        if shell == .zsh {
            let zdotdir = try configuredDirectory(environment["ZDOTDIR"], default: home, name: "ZDOTDIR", fileManager: fileManager)
            try installZshLoadPath(directory: destination.deletingLastPathComponent(), zdotdir: zdotdir, fileManager: fileManager)
        }
        return destination
    }

    private static func detectedShell(environment: [String: String]) -> CompletionShell? {
        guard let shellPath = environment["SHELL"] else { return nil }
        return CompletionShell(rawValue: URL(filePath: shellPath).lastPathComponent)
    }

    private static func installZshLoadPath(directory: URL, zdotdir: URL, fileManager: FileManager) throws {
        let zshrc = zdotdir.appending(path: ".zshrc", directoryHint: .notDirectory)
        let marker = "# >>> sift completions >>>"
        let snippet = """

        # >>> sift completions >>>
        fpath=(\(shellQuote(directory.path)) $fpath)
        autoload -Uz compinit
        compinit
        # <<< sift completions <<<
        """
        try createPrivateDirectory(at: zdotdir, fileManager: fileManager)
        try validateDestination(zshrc, fileManager: fileManager)
        let existing = fileManager.fileExists(atPath: zshrc.path) ? (try String(contentsOf: zshrc, encoding: .utf8)) : ""
        guard !existing.contains(marker) else { return }
        try (existing + snippet).write(to: zshrc, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: zshrc.path)
    }

    private static func configuredDirectory(_ path: String?, default fallback: URL, name: String, fileManager: FileManager) throws -> URL {
        guard let path else { return fallback }
        return try configuredDirectory(path, name: name, fileManager: fileManager)
    }

    private static func configuredDirectory(_ path: String, name: String, fileManager: FileManager) throws -> URL {
        guard !path.isEmpty, path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw CompletionInstallError.unsafePath(name) }
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        try validateExistingPathComponents(directory, fileManager: fileManager)
        if let attributes = try? fileManager.attributesOfItem(atPath: directory.path) {
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            guard let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue,
                  mode & 0o022 == 0, owner == Int(getuid()) else { throw CompletionInstallError.unsafePath(name) }
        }
        return directory
    }

    private static func createPrivateDirectory(at directory: URL, fileManager: FileManager) throws {
        try validateExistingPathComponents(directory, fileManager: fileManager)
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in directory.standardizedFileURL.pathComponents.dropFirst() {
            current.append(path: component, directoryHint: .isDirectory)
            if (try? fileManager.attributesOfItem(atPath: current.path)) == nil {
                try fileManager.createDirectory(at: current, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.path)
            }
        }
        try validateExistingPathComponents(directory, fileManager: fileManager)
    }

    private static func validateExistingPathComponents(_ path: URL, fileManager: FileManager) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in path.standardizedFileURL.pathComponents.dropFirst() {
            current.append(path: component, directoryHint: .isDirectory)
            guard let attributes = try? fileManager.attributesOfItem(atPath: current.path) else { break }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CompletionInstallError.unsafePath(current.path) }
        }
    }

    private static func validateDestination(_ destination: URL, fileManager: FileManager) throws {
        guard let attributes = try? fileManager.attributesOfItem(atPath: destination.path) else { return }
        let links = (attributes[.referenceCount] as? NSNumber)?.intValue ?? 0
        guard attributes[.type] as? FileAttributeType == .typeRegular, links == 1 else { throw CompletionInstallError.unsafePath(destination.path) }
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\\''"))'"
    }
}

enum CompletionInstallError: LocalizedError {
    case unsupportedShell(String?)
    case unsafePath(String)
    var errorDescription: String? {
        switch self {
        case let .unsupportedShell(shell): return "Cannot install completions for \(shell ?? "an unknown shell"). Set SHELL to bash, zsh, or fish."
        case let .unsafePath(path): return "Refusing unsafe completion path: \(path)."
        }
    }
}
