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
                    COMPREPLY=( $(compgen -f -- "$current") )
                else
                    COMPREPLY=( $(compgen -W "$words" -- "$current") )
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
                    argument) case $words[2] in apps|show) compadd -Q -- "${(@f)$(sift __complete apps "$words[CURRENT]" | cut -f1)}" ;; esac ;;
                esac
            }
            """
        }
    }
}

enum CompletionInstaller {
    static func install(environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default) throws -> URL {
        guard let shell = detectedShell(environment: environment) else { throw CompletionInstallError.unsupportedShell(environment["SHELL"]) }
        let home = fileManager.homeDirectoryForCurrentUser
        let destination: URL
        switch shell {
        case .fish:
            let config = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home.appending(path: ".config", directoryHint: .isDirectory)
            destination = config.appending(path: "fish/completions/sift.fish", directoryHint: .notDirectory)
        case .bash:
            let data = environment["BASH_COMPLETION_USER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true).appending(path: "bash-completion", directoryHint: .isDirectory) } ?? home.appending(path: ".local/share/bash-completion", directoryHint: .isDirectory)
            destination = data.appending(path: "completions/sift", directoryHint: .notDirectory)
        case .zsh:
            let zdotdir = environment["ZDOTDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home
            let directory = zdotdir.appending(path: ".zfunc", directoryHint: .isDirectory)
            destination = directory.appending(path: "_sift", directoryHint: .notDirectory)
            try installZshLoadPath(directory: directory, zdotdir: zdotdir, fileManager: fileManager)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try CompletionRenderer.script(for: shell).write(to: destination, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
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
        fpath=(\"\(directory.path)\" $fpath)
        autoload -Uz compinit
        compinit
        # <<< sift completions <<<
        """
        let existing = fileManager.fileExists(atPath: zshrc.path) ? (try String(contentsOf: zshrc, encoding: .utf8)) : ""
        guard !existing.contains(marker) else { return }
        try fileManager.createDirectory(at: zdotdir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try (existing + snippet).write(to: zshrc, atomically: true, encoding: .utf8)
    }
}

enum CompletionInstallError: LocalizedError {
    case unsupportedShell(String?)
    var errorDescription: String? {
        switch self { case let .unsupportedShell(shell): return "Cannot install completions for \(shell ?? "an unknown shell"). Set SHELL to bash, zsh, or fish." }
    }
}
