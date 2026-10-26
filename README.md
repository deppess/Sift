# Sift

Sift is a macOS-native command-line observer for installed software, available updates, observed version changes, and cached release notes. Version 1.0.0 supports macOS 15 and later.

`sift refresh` collects everything; every other command reads the cache instantly and never touches the network.

## What it tracks

| Source | How Sift reads it | Updates from |
| --- | --- | --- |
| Applications | `/Applications`, `~/Applications`, Spotlight, symlinked bundles | the app's own authority (below) |
| Homebrew formulae and casks | every detected `brew` | `brew outdated --greedy-auto-updates`, verified against self-updated bundles |
| npm globals, uv tools | detected `npm`, `uv` | their outdated commands |
| cargo crates | `$CARGO_HOME/.crates2.json` | crates.io sparse index |
| MacPorts | registry database and synced port index, without running `port` | the local port index |
| Steam games | library folders and app manifests | builds Steam has queued |

For applications Sift asks the app's own updater first: its Sparkle feed (from Info.plist or its saved preferences), its Mac App Store listing, its Electron update manifest, or Blackmagic's downloads feed. When that can't be queried it falls back to Homebrew's public cask catalog matched by exact bundle identifier, then to the GitHub release check the app's executable makes, then to a cask with the same app name whose vendor domain the app references. Utilities installed alongside another app (same installer package or product folder) are reported as updated with it. Apps installed by a package manager, including those linked into a Homebrew Caskroom, are reported by that package manager. `sift show` explains every answer, and apps Sift can't check are listed with the reason.

## Build and run

```sh
swift build
swift run sift refresh
swift run sift               # dashboard
swift run sift updates       # everything with an update; --all adds dependencies
swift run sift apps          # applications and where their updates come from
swift run sift show <name>   # details and release notes; --full for complete notes
swift run sift changes       # observed version changes
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

## Behavior

`sift --help` writes usage to standard output and exits successfully. Argument errors exit with status 2. Data is always standard output; diagnostics are always standard error. A custom database parent directory must already exist, be a real directory, and either be private to the current user or sticky; database files must be user-owned regular single-link files.

`refresh` runs its providers concurrently, reads bundle metadata without launching applications, and never runs other tools' scripts. `sift refresh` exits nonzero when any provider is incomplete, while retaining successful provider data; the dashboard names the incomplete providers and why. Cached output is marked stale after 24 hours. A failed or partial refresh preserves prior cached data.

`sift apps --all` adds system, CoreServices, inactive, auxiliary (helpers and build products), and launcher (Steam shortcut) records. Selectors match a bundle identifier, a name, or a unique name prefix (`sift show safari`). `sift refresh` runs `brew update` first only when that prefix's metadata is more than an hour old (or older than `HOMEBREW_AUTO_UPDATE_SECS` when set), judged from the timestamps Homebrew leaves on disk; `--update-homebrew` always updates and `--no-update-homebrew` never does. A failed update is a warning, and the refresh continues with the metadata already on disk. `--no-color` (or `NO_COLOR`) disables styled output.

Set `GITHUB_TOKEN` or `GH_TOKEN` to raise GitHub's release-note rate limit from 60 to 5,000 requests an hour. Update feeds, store listings, and catalogs are asked again after an hour, release notes after six, each revalidated with its ETag. Homebrew's `info` and `outdated` output is reused while nothing it reads has changed (installed kegs and casks, linked and pinned state, the repository and tap checkouts, the API snapshots, and `HOMEBREW_*` settings), and for at most a day; the cask catalog's index and installer-receipt lookups are likewise kept until their source changes. The cache keeps only the latest observation of each app, so it doesn't grow with every refresh.

Pre-1.0.0 development databases, including development builds of schema 15, are intentionally unsupported. Remove the old cache and run `sift refresh`.

## Naming conflict

An unrelated `sift` formula exists in Homebrew Core and provides a binary of the same name. This project intentionally retains the name. Do not expect `brew install sift` to install this project. A future Homebrew distribution would use a custom tap, but both binaries cannot coexist in the same Homebrew prefix.

## License

Sift is licensed under GPL-3.0-or-later. See [PROJECT.md](PROJECT.md) for architecture, scope, security, and attribution requirements.
