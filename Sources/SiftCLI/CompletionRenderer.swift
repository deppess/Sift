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
            complete -c sift -n '__fish_use_subcommand' -a updates -d 'Show cached updates'
            complete -c sift -n '__fish_use_subcommand' -a log -d 'Show the log of observed updates'
            complete -c sift -n '__fish_use_subcommand' -a changelog -d 'Show the changelog of an app, game, or package'
            complete -c sift -n '__fish_use_subcommand' -a show -d 'Show cached software details'
            complete -c sift -n '__fish_use_subcommand' -a completions -d 'Generate shell completions'
            complete -c sift -s h -l help -d 'Show usage'
            complete -c sift -l version -d 'Show version'
            complete -c sift -l json -d 'Render JSON'
            complete -c sift -l all -d 'Include CoreServices and inactive applications'
            complete -c sift -l full -d 'Show the full changelog'
            complete -c sift -l since -r -d 'Only log changes since a duration or date'
            complete -c sift -l fetch -d 'Fetch the changelog again instead of using the cached copy'
            complete -c sift -l no-color -d 'Disable color output'
            complete -c sift -l update-homebrew -d 'Update Homebrew metadata before refreshing'
            complete -c sift -l no-update-homebrew -d 'Skip updating Homebrew metadata before refreshing'
            complete -c sift -l database -r -F -d 'Use a database path'
            complete -c sift -n '__fish_seen_subcommand_from apps show log changelog' -a '(sift __complete (commandline -opc | string match -r -- "^apps\\$|^show\\$|^log\\$|^changelog\\$" | string replace -r "^(log|changelog)\\$" show) (commandline -ct))'
            """
        case .bash:
            """
            _sift() {
                local current previous words subcommand i
                COMPREPLY=()
                current="${COMP_WORDS[COMP_CWORD]}"
                previous="${COMP_WORDS[COMP_CWORD-1]}"
                words="refresh apps updates log changelog show completions --help -h --version --json --all --full --fetch --since --no-color --update-homebrew --no-update-homebrew --database"
                subcommand=""
                for ((i = 1; i < COMP_CWORD; i++)); do
                    case "${COMP_WORDS[i]}" in
                        apps|show) subcommand="${COMP_WORDS[i]}"; break ;;
                        log|changelog) subcommand=show; break ;;
                    esac
                done
                if [[ -n "$subcommand" ]]; then
                    while IFS=$'\t' read -r value description; do
                        COMPREPLY[${#COMPREPLY[@]}]="$value"
                    done < <(sift __complete "$subcommand" "$current")
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
                    'updates:Show cached updates'
                    'log:Show the log of observed updates'
                    'changelog:Show the changelog of an app, game, or package'
                    'show:Show cached software details'
                    'completions:Generate shell completions'
                )
                _arguments -C \
                    '--version[Show version]' \
                    '--json[Render JSON]' \
                    '--all[Include CoreServices and inactive applications]' \
                    '--full[Show the full changelog]' \
                    '--since=[Only log changes since a duration or date]:since:' \
                    '--fetch[Fetch the changelog again instead of using the cached copy]' \
                    '--no-color[Disable color output]' \
                    '--update-homebrew[Update Homebrew metadata before refreshing]' \
                    '--no-update-homebrew[Skip updating Homebrew metadata before refreshing]' \
                    '--database=[Use a database path]:database path:_files' \
                    '(-h --help)'{-h,--help}'[Show usage]' \
                    '1:command:->command' \
                    '2:argument:->argument'
                case $state in
                    command) _describe -t commands command "$commands" ;;
                    argument)
                        local subcommand w
                        for w in $words[1,-2]; do
                            case $w in
                                apps|show) subcommand=$w; break ;;
                                log|changelog) subcommand=show; break ;;
                            esac
                        done
                        case $subcommand in
                            apps|show)
                                local -a candidates
                                local value description
                                while IFS=$'\t' read -r value description; do
                                    candidates+=("$value")
                                done < <(sift __complete "$subcommand" "$words[CURRENT]")
                                compadd -Q -- $candidates
                                ;;
                        esac ;;
                esac
            }
            """
        }
    }
}
