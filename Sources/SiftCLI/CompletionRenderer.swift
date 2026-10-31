enum CompletionShell: String {
    case fish
    case bash
    case zsh
}

/// Shell completion scripts. Each offers the subcommands, then only the flags the chosen
/// subcommand accepts, the shell names after `completions`, and cached names (from
/// `sift __complete`) after `apps`, `show`, `log`, and `changelog`.
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
            complete -c sift -n '__fish_use_subcommand' -s h -l help -d 'Show usage'
            complete -c sift -n '__fish_use_subcommand' -l version -d 'Show version'
            complete -c sift -l json -d 'Render JSON'
            complete -c sift -l no-color -d 'Disable color output'
            complete -c sift -l database -r -F -d 'Use a database path'
            complete -c sift -n '__fish_seen_subcommand_from apps updates log show changelog' -l all -d 'Include CoreServices and inactive applications'
            complete -c sift -n '__fish_seen_subcommand_from show changelog' -l full -d 'Show the full changelog'
            complete -c sift -n '__fish_seen_subcommand_from changelog' -l fetch -d 'Fetch the changelog again instead of using the cached copy'
            complete -c sift -n '__fish_seen_subcommand_from log' -l since -x -a '12h 7d 30d 2w' -d 'Only log changes since a duration or date'
            complete -c sift -n '__fish_seen_subcommand_from refresh' -l update-homebrew -d 'Update Homebrew metadata before refreshing'
            complete -c sift -n '__fish_seen_subcommand_from refresh' -l no-update-homebrew -d 'Skip updating Homebrew metadata before refreshing'
            complete -c sift -n '__fish_seen_subcommand_from completions' -a 'fish bash zsh'
            complete -c sift -n '__fish_seen_subcommand_from apps show log changelog' -a '(sift __complete (commandline -opc | string match -r -- "^apps\\$|^show\\$|^log\\$|^changelog\\$")[1] (commandline -ct))'
            """
        case .bash:
            """
            _sift() {
                local current previous words subcommand i
                COMPREPLY=()
                current="${COMP_WORDS[COMP_CWORD]}"
                previous="${COMP_WORDS[COMP_CWORD-1]}"
                subcommand=""
                for ((i = 1; i < COMP_CWORD; i++)); do
                    case "${COMP_WORDS[i]}" in
                        refresh|apps|updates|log|changelog|show|completions) subcommand="${COMP_WORDS[i]}"; break ;;
                    esac
                done
                case "$subcommand" in
                    refresh) words="--update-homebrew --no-update-homebrew" ;;
                    apps|updates) words="--all" ;;
                    log) words="--all --since" ;;
                    show) words="--all --full" ;;
                    changelog) words="--all --full --fetch" ;;
                    completions) words="fish bash zsh" ;;
                    *) words="refresh apps updates log changelog show completions --help -h --version" ;;
                esac
                [[ "$subcommand" != completions ]] && words="$words --json --no-color --database"
                if [[ "$previous" == "--database" ]]; then
                    while IFS= read -r value; do
                        COMPREPLY[${#COMPREPLY[@]}]="$value"
                    done < <(compgen -f -- "$current")
                elif [[ "$previous" == "--since" ]]; then
                    while IFS= read -r value; do
                        COMPREPLY[${#COMPREPLY[@]}]="$value"
                    done < <(compgen -W "12h 7d 30d 2w" -- "$current")
                elif [[ "$current" != -* && " apps show log changelog " == *" $subcommand "* && -n "$subcommand" ]]; then
                    while IFS=$'\\t' read -r value description; do
                        COMPREPLY[${#COMPREPLY[@]}]="$value"
                    done < <(sift __complete "$subcommand" "$current")
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

            _sift_names() {
                local -a candidates
                local value description
                while IFS=$'\\t' read -r value description; do
                    candidates+=("${value//:/\\\\:}:$description")
                done < <(sift __complete "$1" "$PREFIX")
                _describe -t names name candidates
            }

            _sift() {
                local -a commands common
                commands=(
                    'refresh:Refresh native application inventory'
                    'apps:Show cached applications'
                    'updates:Show cached updates'
                    'log:Show the log of observed updates'
                    'changelog:Show the changelog of an app, game, or package'
                    'show:Show cached software details'
                    'completions:Generate shell completions'
                )
                common=(
                    '--json[Render JSON]'
                    '--no-color[Disable color output]'
                    '--database=[Use a database path]:database path:_files'
                )
                local all='--all[Include CoreServices and inactive applications]'
                local full='--full[Show the full changelog]'
                local subcommand w
                for w in $words[2,CURRENT-1]; do
                    case $w in
                        refresh|apps|updates|log|changelog|show|completions) subcommand=$w; break ;;
                    esac
                done
                case $subcommand in
                    refresh) _arguments $common '--update-homebrew[Update Homebrew metadata before refreshing]' '--no-update-homebrew[Skip updating Homebrew metadata before refreshing]' ;;
                    apps) _arguments $common $all '*:application:{_sift_names apps}' ;;
                    updates) _arguments $common $all ;;
                    log) _arguments $common $all '--since=[Only log changes since a duration or date]:since:(12h 7d 30d 2w)' '*:name:{_sift_names log}' ;;
                    show) _arguments $common $all $full '*:name:{_sift_names show}' ;;
                    changelog) _arguments $common $all $full '--fetch[Fetch the changelog again instead of using the cached copy]' '*:name:{_sift_names changelog}' ;;
                    completions) _values shell fish bash zsh ;;
                    *)
                        _arguments -C $common \\
                            '--version[Show version]' \\
                            '(-h --help)'{-h,--help}'[Show usage]' \\
                            '*::command:->command'
                        [[ $state == command ]] && _describe -t commands command commands ;;
                esac
            }

            if [[ $zsh_eval_context[-1] == loadautofunc ]]; then
                _sift "$@"
            else
                compdef _sift sift
            fi
            """
        }
    }
}
