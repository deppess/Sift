# Changelog

## 1.0.0 - 2026-10-26

First public release of the macOS software inventory observer.

### Inventory

- Native applications from the standard application folders, Spotlight, and symlinked bundles such as Safari, deduplicated by file identity.
- Helpers, cached updaters, build products, and Steam desktop shortcuts are recorded but hidden by default (`--all` shows them).
- Every Homebrew prefix, formulae and casks, with dependency-only formulae hidden by default.
- npm global packages, uv tools, cargo crates, MacPorts ports (read directly, so it works while `port` needs migrating), and Steam games across every library.
- Version observations and transition history via `sift changes`.

### Updates

- Homebrew updates from `brew outdated --greedy-auto-updates`; self-updating casks are verified against the installed bundle and counted separately.
- `brew update` runs automatically when Homebrew's metadata is over an hour old, with no prompt; `--update-homebrew` and `--no-update-homebrew` override it.
- Native application updates from the app's own authority: its declared Sparkle feed, its App Store listing, or Blackmagic's downloads feed, falling back to Homebrew's public cask catalog matched by exact bundle identifier.
- Fallbacks for apps whose updater can't be read directly: Sparkle feeds saved in preferences, Electron update manifests, the app's own GitHub release check, a same-name cask that shares the app's vendor domain, and same-vendor apps installed by the same package or in the same product folder.
- `sift apps` shows where each app's updates come from; `sift show` explains every answer and every app that can't be checked.
- An update is shown only while the version it was checked against is still installed; a failed check keeps the previous answer.

### Release notes

- Exact Homebrew GitHub release and changelog evidence, Sparkle item notes as plain text, and App Store notes.

### Reliability and speed

- Providers run concurrently, and Homebrew's output, the cask catalog index, and installer receipts are reused until what they depend on changes: a repeat refresh takes about a quarter second, a first one a few seconds, and cache commands are instant.
- The cache keeps the latest observation and update check per app, provider runs for 20 refreshes, and drops metadata unused for a month.
- Commands Sift runs get no standard input and inherit no open files.
- Cache-only commands use SQLite WAL, so they work during a refresh, and recover when another SQLite client removes the WAL files.
- Partial provider failures are isolated per package, per prefix, and per provider, and the dashboard says which provider was incomplete and why.
- Human-readable tables align by terminal display width, including CJK and emoji.
- JSON uses RFC 3339 timestamps throughout; `sift --version --json` prints `{"version": "1.0.0"}`.

## Compatibility

Development databases created before 1.0.0, including development builds of schema 15, are not supported. Remove the old cache and run `sift refresh` after installing 1.0.0.
