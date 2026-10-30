# Sift

Sift is a macOS-native, CLI-first tool for answering three related questions:

1. What installed software has an update available?
2. What software version changed between Sift observations? (`sift log`)
3. What changed in any app, game, or package, at any version? (`sift changelog`)

Sift is an observer. It does not install updates, run in the background, inspect project dependency trees, or invent changelogs. A changelog is always shown in the terminal: Sift never sends the user to a browser or the app, and text that only points elsewhere ("see our website") is treated as no changelog.

## Product Contract

- Target macOS 15 and later. macOS 26 is the primary development platform.
- Use Swift 6 and Swift Package Manager.
- Persist state in SQLite at `~/Library/Application Support/Sift/sift.sqlite3` by default.
- `sift`, `apps`, `updates`, `log`, `show`, and dynamic completion lookups read only cached state. They never run providers, make network requests, or write the database (beyond upgrading an earlier 1.x schema in place).
- `sift refresh` is the only command allowed to discover software or run provider commands. It and `sift changelog` are the only commands that fetch metadata: `changelog` fetches only the requested item's changelog, and only when its cached copy is missing or more than six hours old (or `--fetch` is given).
- Cached dashboard and Homebrew update output mark data stale after 24 hours; no command refreshes implicitly. Failed or partial refreshes preserve cached data and surface their incomplete status.
- Human-readable output is compact. Detailed provenance and changelogs belong in detail commands.
- Version 1.0.0 is the first public release. Its JSON output is stable across 1.x: fields may be added, but none are renamed or removed.

## Name And Distribution

The project, Swift package, and executable are all named `Sift` / `sift`.

An unrelated `sift` formula already exists in Homebrew Core and installs an executable of the same name. This is an accepted naming overlap. A future Sift Homebrew formula must live in a custom tap and cannot coexist with the Core formula in the same Homebrew prefix. Direct binary and source installations are unaffected.

## Scope

Implemented providers and refresh work:

1. Native `.app` bundle inventory from the standard application folders, Spotlight, and symlinked bundles (Safari is a hidden link into its Cryptex).
2. Every detected Homebrew prefix, including formulae and casks, with update targets from `brew outdated --greedy-auto-updates` and release notes for resolved updates.
3. npm global packages, uv tools, and cargo-installed crates.
4. MacPorts, read from its registry database and synced port index without running `port`.
5. Steam games, read from Steam's library folders and app manifests.
6. Native application updates from each app's own authority: its Sparkle feed (declared in Info.plist or saved in its preferences), its Mac App Store listing, its electron-builder manifest, or Blackmagic's downloads feed. When that can't be queried: Homebrew's public cask catalog by exact bundle identifier, then the GitHub release check the app's own executable makes, then a catalog cask with the same app name whose vendor domain the app references. Apps left over are credited to a same-vendor app installed by the same package or in the same product folder.

Sift stores dependency packages (Homebrew formulae and MacPorts ports nobody requested) but hides them from the dashboard and `sift updates` unless `--all` is passed. It inventories unsupported, system-managed, and Setapp applications so that the inventory is honest even when Sift cannot determine an update source. Bundles outside the application folders (helpers in Application Support, cached updaters, build products) are recorded as `auxiliary`, and Steam desktop shortcuts as `launcher`; both are hidden by default.

Explicitly deferred:

- update execution
- daemons, watchers, notifications, GUI, and TUI
- `softwareupdate`
- external `mas` dependency
- pipx, mise, Go binaries, gems, and Squirrel.Mac update servers (no fixtures yet)
- project dependency scanning
- AI summaries
- Linux support

## Evidence Model

Installation provenance, update authority, and release-note provenance are independent values. They must never be collapsed into one `source` field.

For example, an application can have a Homebrew cask installation, Sparkle as its update authority, and a Sparkle appcast as its release-note source.

Sift records these version axes separately where available:

- application short version
- application build version
- provider-installed version
- available version
- release-note target version

Versions are stored losslessly as strings. Do not force every provider into semantic versioning. Each source is compared with its own ordering: Sparkle's for appcasts and store listings, MacPorts' `vercmp` for ports.

An application's update authority is detected from the bundle: an App Store receipt, the Sparkle framework or `SUFeedURL`, a Steam library path, a Setapp path, an Apple system location, or a known Blackmagic bundle identifier. Apps installed by a package manager (a Homebrew cask artifact, a MacPorts registry file) are reported by that package manager instead. An update answer is shown only while the version it was checked against is still installed, and a failed check keeps the previous answer.

Observed version transitions are derived only from two persisted observations. Sift may state that a version changed between observations; it may not claim the precise time an update was installed unless a provider supplies that value authoritatively.

## Reconciliation Rules

Strong evidence can reconcile records:

- identical normalized bundle path, or the same file (device and inode) under two spellings
- exact bundle identifier
- an installed Homebrew cask artifact that points to the bundle
- a MacPorts registry file entry for the bundle
- a bundle or main executable that is a symlink into a Homebrew Caskroom or Cellar package
- the same macOS installer package receipt, or the same product folder, for two apps whose bundle identifiers share a vendor prefix (the second app is reported as updated with the first, never given a version of its own)
- exact App Store bundle identifier
- preserved provider-native identifier

Similar names, executable names, homepages, and catalog search results are weak evidence. They never establish ownership. In particular, Sift must not infer Homebrew ownership by matching a discovered application's name against the cask catalog.

The cask catalog may supply a *version* for an app Homebrew did not install, but only through the bundle's exact identifier: the cask's uninstall step quits it, or the cask installs an app of the same file name and its uninstall/zap paths name the identifier, or it is a package-installer cask whose paths name it. The stable cask wins over `@beta`-style variants; any other ambiguity leaves the app unmatched. A catalog answer is labeled as such and never makes the app Homebrew-owned. As a last resort, a single stable cask with the app's file name is accepted only when the app itself references that cask's vendor domain (shared hosts such as github.com or amazonaws.com never count); the answer names the domain.

An app's executable may reveal the GitHub release check its own updater makes (`api.github.com/repos/<owner>/<repo>/releases` or `github.com/<owner>/<repo>/releases`); it is used only when that owner or repository also appears in the bundle identifier or app name. Executables are read as bytes for URLs, never run, and only for apps no stronger source covers.

When reconciliation is uncertain, retain separate records and surface that uncertainty.

## Changelogs

`sift changelog <name>` works for anything in the catalog: apps, games, Homebrew formulae and casks, npm, uv, cargo, MacPorts, and Steam packages. Entries are newest first and go as far back as the source does; by default the versions newer than the installed one are shown, then the installed version's own entry.

Sources are tried in order, and the first with real content for the installed version wins (a source that has versions but not the installed one lets up to two more be tried, and the fuller one is kept):

1. Changelog files the package installed (a Homebrew keg, `node_modules`, the cargo registry source) or the app bundle ships in `Contents/Resources`; of several, the one with the installed version and the most entries.
2. A small table of known locations for projects whose metadata points nowhere useful (Go, Python, FL Studio, the Steam client), like Homebrew's livecheck blocks.
3. The app's Sparkle feed, every item; an item that only links to its notes (as `releaseNotesLink` or a link inside its description) has the linked page read, rendered if needed, and the matching version kept.
4. The App Store listing's version history (the lookup API's latest notes otherwise).
5. Steam's news feed for the game (patch notes when the game tags them, every announcement otherwise); the app ID comes from Steam's manifests when the cache predates it.
6. Blackmagic's downloads feed. A helper installed and updated with another app shows that app's changelog.
7. The project's GitHub releases, merged with its repository changelog file (common spellings of `CHANGELOG`, `NEWS`, `HISTORY`, `ChangeLog`, …) when the releases are short, lack the installed version, or have empty bodies; for a repository with neither, its version tags with the commits between them.
8. The project's own website: the homepage or changelog link its package metadata names (Homebrew, npm, PyPI, crates.io, Python `Project-URL`s, a formula's PyPI/npm/crates download, the cask for the app's bundle identifier or vendor domain, changelog links embedded in the bundle on the vendor's own domain), followed to the page that lists versions. A homepage's link to a GitHub repository named like the item is tried before its other links.

Documents are split at their version headings: Markdown and setext headings, plain-text NEWS formats (GNU `* Noteworthy changes in release X`, FFmpeg `version X:`, tmux `CHANGES FROM X TO Y`, Bash's `This document details the changes…`, and a version at the margin with indented text below when used consistently), and a lone version line followed by a date on converted pages. A page is read as HTML, then through an advertised RSS/Atom feed (only its release posts, when there are at least three), then through release records in JSON it embeds for its scripts (`__NEXT_DATA__`, `ld+json`), and last, when its content is built by scripts, rendered by WebKit in a separate `sift __render` process with a 30-second limit, no persistent storage, no downloads, HTTPS only, and WebKit's own user agent with Sift's name added. Page scripts run only inside WebKit's sandbox. Sift identifies itself honestly and does not work around bot checks, so a site that refuses anything but a mainstream browser is reported as giving no changelog. Placeholder text (links elsewhere, "update your browser", "enable JavaScript") never counts. A source with versions and dates but no text is used as a version history when nothing better exists.

History is cumulative (`changelog_history`, keyed by item and version): versions a source stops listing are kept, a placeholder never replaces real text, and placeholder or unversioned leftovers are dropped once a versioned changelog replaces them. `changelog_state` records the latest lookup. `refresh` prefetches the changelogs of pending updates and of anything that changed in the last week. GitHub requests use `GITHUB_TOKEN`, `GH_TOKEN`, or the GitHub CLI's login (`gh auth token`, unless `SIFT_NO_GH_TOKEN` is set); when rate-limited, release lists fall back to the repository's `releases.atom`.

The 1.0 per-update notes (`homebrew_release_notes`, `release_notes`) are still collected by `refresh` and shown by `sift show` when no changelog is cached.

## Persistence

Sift 1.0.0 creates its schema (version 15) directly as a clean baseline; it does not carry forward the incremental pre-release migration history, and pre-release caches, including development builds of version 15, are intentionally unsupported. Later versions are steps applied on top of the baseline in one transaction, so a 1.x cache keeps its history: version 16 adds `package_transitions` (version history for Homebrew and managed packages), `managed_packages.identifier` (a Steam app ID), and `changelog_state`; version 17 replaces 16's per-fetch `changelog_entries` with the cumulative `changelog_history`. A cache-only command that finds an older 1.x schema upgrades it in place first. Its core tables include:

- `schema_migrations`
- `settings`
- `software`
- `installations`
- `observations`
- `version_transitions`
- `update_availability`
- `release_notes`
- `provider_runs`
- `refresh_sessions`
- `provider_state`
- `homebrew_packages`
- `homebrew_release_notes`
- `cask_artifacts`
- `metadata_http_cache`
- `managed_packages`
- `managed_artifacts`

Observations are immutable. Refreshes must be idempotent: a repeated observation of the same installation and version cannot create a false transition. Database migrations run in transactions and all SQL values use bound parameters.

## CLI Contract

Implemented commands:

```text
sift
sift refresh
sift show <software>
sift apps
sift updates
sift log [software] [--since <30d|2w|12h|YYYY-MM-DD>]   (`changes` is an alias)
sift changelog <software> [--all] [--full] [--fetch]
sift completions <fish|bash|zsh>
```

Initial global options:

```text
--version
--json
--all
--full
--fetch
--since <duration|date>
--no-color
--update-homebrew|--no-update-homebrew
--database <path>
```

`refresh` scans standard native application roots, Spotlight candidates, and symlinked bundles, reads `Info.plist` metadata without executing applications, inventories detected Homebrew prefixes (running `brew update` first when a prefix's metadata is over an hour old), npm globals, uv tools, cargo crates, MacPorts, and Steam libraries, resolves Homebrew targets, checks native applications against their update authority, and caches release notes. Providers run concurrently. Cache-reading commands do not scan, invoke providers, fetch metadata, or write the database. Dynamic completion reads the existing cache when present and otherwise returns no matches.

`--json` writes the dashboard as this envelope:

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-08-21T00:00:00Z",
  "lastAttemptAt": null,
  "dataAsOf": null,
  "freshness": "unknown",
  "latestRefreshStatus": "never",
  "data": {
    "availableUpdateCount": 0,
    "informationalUpdateCount": 0,
    "recentTransitionCount": 0,
    "partialProviderCount": 0,
    "failedProviderCount": 0,
    "providerResults": []
  }
}
```

`updates`, `apps`, and `log` write a JSON array of records, and `show` and `changelog` write one record. Within 1.x, fields are only ever added; a change that would break an existing reader waits for 2.0, and the dashboard's `schemaVersion` changes with it.

`lastAttemptAt` records the latest completed refresh attempt. `dataAsOf` records the newest successfully collected provider data and drives freshness: `unknown`, `current`, or `stale`. A failed attempt never makes cached data current. The stale threshold is 24 hours; “recently changed” means distinct installations with a transition observed in the previous seven days. JSON uses RFC 3339 timestamps, explicit `null` for unavailable values, stable string enums, standard output for data, and standard error for diagnostics.

## Security And Reliability

- Run provider executables directly with argument arrays, never through a shell.
- Use subprocess timeouts and output-size limits.
- Permit only allowlisted HTTPS metadata hosts (`formulae.brew.sh`, `api.github.com`, `raw.githubusercontent.com`, `itunes.apple.com`, `apps.apple.com`, `www.blackmagicdesign.com`, `index.crates.io`, `crates.io`, `registry.npmjs.org`, `pypi.org`, `api.steampowered.com`); reject local and executable URL schemes. A changelog page may use only the host its package metadata, app bundle, feed, or Sift's table of known locations names, on a named public HTTPS host, and may redirect only to another such host; a page WebKit renders may load the subresources a browser would. A Sparkle feed or electron-builder `latest-mac.yml` may use only the host its own app declares, over HTTPS, on a named public host (no IP literals, ports, credentials, or `.local` names); it may redirect only to another such public HTTPS host, as Sparkle itself allows.
- Disable XML external entities and bound feed and HTTP response sizes.
- Bound redirect count, request duration, and HTTP concurrency.
- Sanitize terminal control characters from provider and changelog content.
- Use restrictive permissions for Sift's state directory and database.
- For custom databases, require an existing real parent directory that is private to the current user or sticky; reject symlinks and unsafe database files. Database files must be user-owned, regular, single-link files and are created or tightened to mode `0600`.
- Record partial provider failures without discarding successful provider data.
- Never execute provider metadata, feed content, or changelog content. Bundle scripts (Steam shortcuts) and other tools' databases (MacPorts' registry) are read, never run or written.

## Licensing And Attribution

Sift is GPL-3.0-or-later. Selected macOS application, Sparkle, App Store, and Homebrew implementation details may be adapted from [Latest](https://github.com/mangerlahn/Latest), also GPL-3.0. Adapted code must preserve its applicable copyright and license notices, identify its upstream source and revision in `NOTICE`, and record material modifications.

## Delivery Milestones

1. Foundation, native inventory, and Homebrew inventory/targets/notes. Done.
2. History and stale-cache behavior. Done.
3. Sparkle: secure appcast retrieval, channel/version selection, notes, and caching. Done; feeds set at run time fall back to the cask catalog.
4. App Store: exact bundle lookup and cached release notes. Done.
5. Reconciliation and UX: detail views, diagnostics, provenance display, and output polish. Update sources and reasons are shown per app; further polish remains.
6. Release hardening: fixtures, deterministic security regression/integration runs, benchmarks, Apple Silicon/Intel validation, documentation, archives, and optional signing/notarization.

## Definition Of Done For V1

- Cached invocations perform no provider subprocess or network work.
- Refresh inventories native applications and all detected Homebrew installations.
- Homebrew ownership is never based on name matching.
- Available updates and observed installed-version transitions remain distinct.
- Release-note sources and confidence are visible.
- Unknown remains unknown.
- Partial provider failures are isolated.
- Human and JSON output remain stable and tested.
- No deferred feature has slipped into the release.
