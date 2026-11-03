# Changelog

## Unreleased

### Changelogs

- Long changelogs are read up to 20 times faster: version and date patterns are compiled once instead of on every line, and merging two sources no longer re-reads each version for every pair (fish's 68-version file: 2.5 s to 0.2 s; Bash's NEWS: 10.5 s to 0.5 s).
- Repository changelog files on GitHub, GitLab, and Codeberg are probed several spellings at a time instead of one after another (a repository without one: about 4 s to under 1 s). Tag comparisons, version pages, Adoptium notes, and a site's robots files are fetched together too.
- A site that answers every address with its homepage has that page read once, not rendered in WebKit under each guessed changelog address (KeyboardCleanTool: 38 s to 5 s).
- Pages WebKit can't change (no scripts and text of their own, or no body at all) are no longer rendered, and an update feed's linked release-notes pages are read together, at most four rendering at once (CleanShot X: 28 s to 0.2 s).
- Links that only mention a generic word ("Hacker News", "Browse clipboard history") or lead to a download are no longer followed as changelog links (BetterTouchTool: 47 s to 1 s).
- A rendered page is read as soon as its text has settled, 0.4 s sooner, and a page that stays empty is given up on after a few seconds instead of 25 (VirtualDJ's).
- An address that timed out or couldn't connect isn't asked again during the same run.
- Refresh prefetches changelogs with four workers that each take the next item when free, instead of in batches waiting on their slowest item: about twice as many are fetched within the time limit. Together with the changes above, a refresh that warms 45 changelogs takes 22 s instead of about 60.
- Text that only points elsewhere ("Please visit the Help Centre…") is never shown as a version's notes, including copies already stored: the version reads "(no details given)" instead (Affinity's).
- With a GitHub token (`GITHUB_TOKEN`, `GH_TOKEN`, or `gh auth login`), GitHub releases are read through GraphQL, which sends only the fields Sift reads instead of every release's assets: gh's 210 releases are 0.5 MB instead of 7 MB (about 4 s to 1.6 s). Without a token, or if GraphQL fails, the REST API is used as before.
- Long changelogs display faster with `--all` (Claude Code's 434 versions: 0.33 s to 0.24 s).
- Changelogs numbered by build ("BUILD 9644 (2026-09-21)") are read, and an installed version is placed by its build (VirtualDJ's 8.5.9307 is build 9307), so only the builds after it show as new. Notes written as `-Fix …` lines read as bullets.
- VirtualDJ's changelog is found at its own page, which neither the app nor its site links.
- An update to a new major version keeps that version's own release notes: going from 7 to 8.3, the 8.x notes are no longer set aside as another product's (KeyboardCleanTool).
- A homepage listing versions without the installed one (OnyX's table of the newest release for each macOS) gives way to the changelog it links when that has the installed version. Lines starting with a typed "•" read as bullets.
- A beta of a new major version shows the previous major's release notes instead of bare version numbers, since its own aren't published yet (Little Snitch 7.0 beta shows 6.5's).
- An app with no other known source is looked up as its copyright holder's GitHub project of the same name (Caffeinate, from Lennard Kittner, is LennardKittner/Caffeinate).

## 1.0.3 - 2026-11-01

- Licensed under AGPL-3.0-or-later instead of GPL-3.0-or-later.

### Changelogs

- The cache records the kind of authoritative source that produced a changelog (such as GitHub releases, a Sparkle feed, or a vendor release-notes page). When a cached changelog needs revalidation, Sift retries that source before rediscovering it.
- A remembered URL is only a scheduling hint: it is revalidated against the current app or package evidence and the existing HTTPS/public-host safety policy before use.
- Refresh prefetch is bounded to four changelog lookups at a time and a 45-second warming budget, avoiding unbounded workers, page rendering, and SQLite/cache contention on large update sets.
- Cache lookups reuse already loaded state, removing redundant SQLite reads.

### Reliability and distribution

- The WebKit renderer keeps its navigation delegate alive for the full page load, fixing script-rendered changelog pages that could otherwise fail immediately.
- `Scripts/build-app` produces a locally ad-hoc-signed `Sift.app` with bundle identifier `org.deppes.sift`; `Scripts/install-local` installs it at a stable path and links the `sift` CLI to the bundled executable.
- The database schema upgrades in place to version 18, preserving changelog history while recording the successful source type.

## 1.0.2 - 2026-10-31

### Changelogs

- `sift changelog <name>` shows the changelog of any app, game, or package in the terminal, newest first: the versions newer than the installed one by default, `--all` for the whole history, `--full` for links and download sections, `--fetch` to ask the source again.
- Sources: changelog files the package installed, every item of an app's Sparkle feed (following release-notes links, including ones inside placeholder text), App Store version history, Steam patch notes, Blackmagic's downloads feed, GitHub releases and repository changelog files, and the changelog page on the project's website found from its package metadata.
- Placeholder text that only points elsewhere is never shown as a changelog; when nothing is found, Sift lists where it looked.
- `sift refresh` prefetches changelogs for pending updates and recent changes; `sift show` displays what's new from that cache.
- "Notes" is now "Changelog" everywhere.
- Every changelog read is kept per version, so feeds that only list recent releases build a full history over time.
- More sources: changelog files inside app bundles, plain-text NEWS/CHANGES formats, GitHub releases merged with the repository changelog, tags and commits for repositories with neither, RSS/Atom feeds and embedded data on project sites, JavaScript-built pages rendered in WebKit, PyPI/npm/crates.io metadata for Homebrew formulae, and a homepage's link to the project's own repository.
- Helpers installed with another app show that app's changelog.
- GitHub requests use the GitHub CLI's login when no token is set; `SIFT_DEBUG=1` traces every request.
- Release notes written by date instead of version (Claude, Figma, Zoom, Google Drive, ChatGPT, Warp) are read as a dated log, and entries after the installed copy's install date count as new.
- Short or partial sources are combined: an update feed listing only the latest release is merged with the project's GitHub history or the notes page it links to; versions from another product (a vendor's other app) are refused rather than shown.
- Vendor sources for JetBrains IDEs, Temurin (Adoptium), 1Password, Microsoft Edge, Office for Mac, Windows App, Unity Hub, Postman, Signal, Emacs, Docker, Ansible, PostgreSQL, git, GCC, QEMU, and GNU packages' NEWS files.
- Per-version release-note sites (VS Code, Firefox, Blender, PostgreSQL) show the previous few versions too.
- Changelog hubs are followed to the item's own section (LM Studio) or to its newest years (Warp); monorepo releases keep the installed product's tags (Bitwarden desktop, not its CLI).
- Installed versions with build stamps or channel letters (Word's 16.114.26102720, Zen's 1.24b, Miniconda's py314_26.9.4-0) match their changelog entries.
- A re-read replaces a stored entry's title as well as its text.

### Updates

- MacPorts updates are checked against ports.macports.org when the local port index is over a week old (MacPorts can't sync after a macOS upgrade until it's reinstalled), so updates since the last sync aren't missed.
- `sift refresh` shows each provider's notes and warnings.

### Update log

- `sift log` lists every observed version change across apps, Homebrew, npm, uv, cargo, MacPorts, and Steam, grouped by day; `sift log <name>` and `--since` narrow it. `changes` remains as an alias.
- `sift show` and `sift changelog` now accept npm, uv, cargo, MacPorts, and Steam packages (`npm:`, `uv:`, `cargo:`, `port:`, `steam:` selectors, or a Steam app ID).

### Completions

- `sift changelog`, `sift log`, and `sift show` complete cached app and package names; `sift completions` completes fish, bash, and zsh.
- Flags are offered only for the subcommand that accepts them (`--fetch` after `changelog`, `--since` after `log`, `--update-homebrew` after `refresh`).
- The zsh script completes on the first Tab when autoloaded from `fpath`.

### Cache

- Schema 17, applied in place to a 1.0 cache on first use, keeping its history.

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
