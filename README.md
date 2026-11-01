# Sift

Sift is a macOS-native command-line observer for installed software: what has an update, a log of every version change it has seen, and the changelog of any app, game, or package, read right in the terminal. It supports macOS 15 and later.

`sift refresh` collects everything. `sift changelog` fetches the one changelog you ask for when its cached copy is missing or old; every other command reads the cache instantly and never touches the network.

Source: [Codeberg](https://codeberg.org/deppes/Sift) (primary) · [GitHub](https://github.com/deppess/Sift) (mirror)

## Install

Requires macOS 15 or later and Swift 6 (Xcode 16 or the Swift toolchain).

```sh
git clone https://codeberg.org/deppes/Sift.git
cd Sift
swift build -c release
install "$(swift build -c release --show-bin-path)/sift" /usr/local/bin/sift
sift refresh
```

## What it tracks

| Source | How Sift reads it | Updates from |
| --- | --- | --- |
| Applications | `/Applications`, `~/Applications`, Spotlight, symlinked bundles | the app's own authority (below) |
| Homebrew formulae and casks | every detected `brew` | `brew outdated --greedy-auto-updates`, verified against self-updated bundles |
| npm globals, uv tools | detected `npm`, `uv` | their outdated commands |
| cargo crates | `$CARGO_HOME/.crates2.json` | crates.io sparse index |
| MacPorts | registry database and synced port index, without running `port` | the local port index, or ports.macports.org when it's over a week old |
| Steam games | library folders and app manifests | builds Steam has queued |

For applications Sift asks the app's own updater first: its Sparkle feed (from Info.plist or its saved preferences), its Mac App Store listing, its Electron update manifest, or Blackmagic's downloads feed. When that can't be queried it falls back to Homebrew's public cask catalog matched by exact bundle identifier, then to the GitHub release check the app's executable makes, then to a cask with the same app name whose vendor domain the app references. Utilities installed alongside another app (same installer package or product folder) are reported as updated with it. Apps installed by a package manager, including those linked into a Homebrew Caskroom, are reported by that package manager. `sift show` explains every answer, and apps Sift can't check are listed with the reason.

## Build and test

```sh
swift build
swift run sift refresh
swift run sift               # dashboard
swift run sift updates       # everything with an update; --all adds dependencies
swift run sift apps          # applications and where their updates come from
swift run sift show <name>   # details and what's new
swift run sift log           # every observed version change; log <name>, --since 30d
swift run sift changelog <name>  # the changelog, newest first; --all for the whole history, --full for links and downloads
swift test
./Scripts/test-integration
./Scripts/test-security
./Scripts/benchmark
```

`swift test` runs the unit suites without touching the host's package managers or the network. `./Scripts/test-integration` runs the opt-in process, SQLite, permission, schema, and concurrency checks in unique temporary directories, including a real refresh of the host. `./Scripts/test-security` deterministically repeats the security regression and integration tests; it is not a fuzz harness. `./Scripts/benchmark` builds release configuration and reports repeated core-test timings. Set `SIFT_SECURITY_ITERATIONS` or `SIFT_BENCHMARK_ITERATIONS` to adjust runs; `SIFT_SECURITY_SEED` labels a security run.

Use an isolated database while developing:

```sh
swift run sift --database /tmp/sift.sqlite3
```

## Changelogs

`sift changelog <name>` takes any app, game, or package `sift show` knows: `sift changelog gh`, `sift changelog UTM`, `sift changelog steam:Balatro`, `sift changelog cargo:graf-rs`. It shows the versions newer than the one installed, then the installed version's own entry; `--all` shows everything the source has. The changelog always appears in the terminal; Sift never sends you to a browser.

Sift looks, in order, for a changelog file the package or app bundle installed (CHANGELOG.md, NEWS, a Tor Browser-style ChangeLog.txt), the app's update feed (following its release-notes links), the App Store's version history, Steam's patch notes, Blackmagic's downloads feed, the project's GitHub releases merged with its repository changelog (or, for a repository with neither, its tags and commits), and finally the changelog on the project's website, found from the homepage its package metadata names. A website is read as HTML first, then through the RSS or Atom feed it advertises, then through the release data it embeds for its scripts, and last by rendering it in WebKit when its content is built by JavaScript; nothing on it runs outside WebKit's own sandbox. Helpers installed with another app (DaVinci Resolve's utilities) show that app's changelog. Text that only points somewhere else ("see our website", "please update your browser") doesn't count. Release notes organized by date rather than version (Claude's, Figma's, Zoom's) are shown as a dated log, and the entries after your copy was installed count as new. Sources that only cover part of the history are combined, and a page listing another product's versions is refused rather than shown. When nothing is found it lists where it looked. Sift identifies itself honestly and doesn't work around a site's bot checks, so a site that refuses anything but a mainstream browser (Affinity's help centre) can't be read.

Every changelog Sift reads is kept: entries are stored per version and never removed when a source stops listing them, so a feed that only shows its latest release, or Steam's last hundred posts, builds into a complete history over time. Changelogs are fetched again after six hours (`--fetch` asks now), and `sift refresh` prefetches them for everything with a pending update or a change in the last week, so `sift show` can display what's new without the network.

GitHub allows 60 anonymous API requests an hour, which a first look at many packages can use up (Sift then falls back to each project's releases feed, which has only the latest ten). With `GITHUB_TOKEN` or `GH_TOKEN` set, or the GitHub CLI logged in (`gh auth login`; set `SIFT_NO_GH_TOKEN=1` to stop Sift using it), the limit is 5,000. `SIFT_DEBUG=1` traces every request and source decision to standard error.

## Update log

Every refresh records what changed since the previous one, for apps, Homebrew, npm, uv, cargo, MacPorts, and Steam alike. `sift log` lists them by day, newest first; `sift log gh` shows one item's history and `--since 2w` (or `30d`, `12h`, `2026-10-01`) narrows the range. The log starts from Sift's first refresh; versions before that aren't known.

## Behavior

`sift --help` writes usage to standard output and exits successfully. Argument errors exit with status 2. Data is always standard output; diagnostics are always standard error. A custom database parent directory must already exist, be a real directory, and either be private to the current user or sticky; database files must be user-owned regular single-link files.

`refresh` runs its providers concurrently, reads bundle metadata without launching applications, and never runs other tools' scripts. `sift refresh` exits nonzero when any provider is incomplete, while retaining successful provider data; the dashboard names the incomplete providers and why. Cached output is marked stale after 24 hours. A failed or partial refresh preserves prior cached data.

`sift apps --all` adds system, CoreServices, inactive, auxiliary (helpers and build products), and launcher (Steam shortcut) records. Selectors match a bundle identifier, a name, or a unique name prefix (`sift show safari`). `sift refresh` runs `brew update` first only when that prefix's metadata is more than an hour old (or older than `HOMEBREW_AUTO_UPDATE_SECS` when set), judged from the timestamps Homebrew leaves on disk; `--update-homebrew` always updates and `--no-update-homebrew` never does. A failed update is a warning, and the refresh continues with the metadata already on disk. `--no-color` (or `NO_COLOR`) disables styled output.

Set `GITHUB_TOKEN` or `GH_TOKEN` to raise GitHub's rate limit from 60 to 5,000 requests an hour (and let `sift changelog` read up to 1,000 releases instead of 300). Update feeds, store listings, and catalogs are asked again after an hour, changelogs after six, each revalidated with its ETag. Homebrew's `info` and `outdated` output is reused while nothing it reads has changed (installed kegs and casks, linked and pinned state, the repository and tap checkouts, the API snapshots, and `HOMEBREW_*` settings), and for at most a day; the cask catalog's index and installer-receipt lookups are likewise kept until their source changes. The cache keeps only the latest observation of each app, so it doesn't grow with every refresh.

A cache from an earlier 1.x release is upgraded in place the first time a newer Sift opens it, keeping its history. Pre-1.0.0 development databases, including development builds of schema 15, are intentionally unsupported. Remove the old cache and run `sift refresh`.

## Naming conflict

An unrelated `sift` formula exists in Homebrew Core and provides a binary of the same name. This project intentionally retains the name. Do not expect `brew install sift` to install this project. A future Homebrew distribution would use a custom tap, but both binaries cannot coexist in the same Homebrew prefix.

## License

AGPL-3.0-or-later. See [LICENSE](LICENSE).

I ask that this code not be used to train AI models. This is a request, not a license term.
