# Sift

Sift is a macOS-native, CLI-first tool for answering two related questions:

1. What installed software has an update available?
2. What software version changed between Sift observations, and what changed in that release?

Sift is an observer. It does not install updates, run in the background, inspect project dependency trees, or invent release notes.

## Product Contract

- Target macOS 15 and later. macOS 26 is the primary development platform.
- Use Swift 6 and Swift Package Manager.
- Persist state in SQLite at `~/Library/Application Support/Sift/sift.sqlite3` by default.
- `sift` reads only cached state. It never starts subprocesses or performs network requests.
- `sift refresh` is the only v1 command allowed to discover software, run provider commands, or fetch metadata.
- Cached output warns when its last successful refresh is stale; it never refreshes implicitly.
- Human-readable output is compact. Detailed provenance and release notes belong in detail commands.
- JSON is explicitly pre-v1 until native inventory and refresh semantics are settled. It becomes a stable, versioned machine-readable contract at v1.

## Name And Distribution

The project, Swift package, and executable are all named `Sift` / `sift`.

An unrelated `sift` formula already exists in Homebrew Core and installs an executable of the same name. This is an accepted naming overlap. A future Sift Homebrew formula must live in a custom tap and cannot coexist with the Core formula in the same Homebrew prefix. Direct binary and source installations are unaffected.

## Scope

V1 providers, in implementation order:

1. Native `.app` bundle inventory.
2. Every detected Homebrew prefix, including formulae and casks.
3. Sparkle update feeds advertised by installed applications.
4. Built-in Mac App Store metadata lookup using exact bundle identifiers.

Sift stores all Homebrew formulae but defaults dashboard output to requested formulae. It inventories unsupported, system-managed, and Setapp applications so that the inventory is honest even when Sift cannot determine an update source.

Explicitly deferred from v1:

- update execution
- daemons, watchers, notifications, GUI, and TUI
- `softwareupdate`
- external `mas` dependency
- npm, uv, pipx, Cargo, mise, and other package managers
- project dependency scanning
- generic web scraping and AI summaries
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

Versions are stored losslessly as strings. Do not force every provider into semantic versioning.

Observed version transitions are derived only from two persisted observations. Sift may state that a version changed between observations; it may not claim the precise time an update was installed unless a provider supplies that value authoritatively.

## Reconciliation Rules

Strong evidence can reconcile records:

- identical normalized bundle path
- exact bundle identifier
- an installed Homebrew cask artifact that points to the bundle
- exact App Store bundle identifier
- preserved provider-native identifier

Similar names, executable names, homepages, and catalog search results are weak evidence. They never establish ownership. In particular, Sift must not infer Homebrew ownership by matching a discovered application's name against the cask catalog.

When reconciliation is uncertain, retain separate records and surface that uncertainty.

## Release Notes

Sift uses authoritative sources in this order:

1. Sparkle appcast notes for the selected release.
2. App Store release notes for the exact store version.
3. Provider metadata that identifies an exact upstream release.
4. Unknown.

Each note records a source URL and one confidence value: `exact`, `strong`, `inferred`, or `unknown`. V1 does not scrape arbitrary pages or manufacture a summary.

## Persistence

The initial schema contains:

- `schema_migrations`
- `settings`
- `software`
- `installations`
- `observations`
- `version_transitions`
- `update_availability`
- `release_notes`
- `provider_runs`

Observations are immutable. Refreshes must be idempotent: a repeated observation of the same installation and version cannot create a false transition. Database migrations run in transactions and all SQL values use bound parameters.

## CLI Contract

Commands planned for v1:

```text
sift
sift refresh
sift recent
sift show <software>
sift apps
sift brew
sift providers
sift doctor
```

Initial global options:

```text
--json
--no-color
--database <path>
```

The foundation implements cache-only `sift` and `sift apps`, plus `sift refresh` for read-only native `.app` bundle inventory. Native discovery scans bounded standard application roots, reads `Info.plist` metadata without executing applications, and records immutable version observations. Commands are added only when they have real data behind them.

The pre-v1 JSON envelope is:

```json
{
  "schemaVersion": 0,
  "generatedAt": "2026-08-21T00:00:00Z",
  "lastAttemptAt": null,
  "dataAsOf": null,
  "freshness": "unknown",
  "latestRefreshStatus": "never",
  "data": {
    "availableUpdateCount": 0,
    "recentTransitionCount": 0,
    "failedProviderCount": 0
  }
}
```

`lastAttemptAt` records the latest completed refresh attempt. `dataAsOf` records the newest successfully collected provider data and drives freshness: `unknown`, `current`, or `stale`. A failed attempt never makes cached data current. The stale threshold is 24 hours; “recently changed” means distinct installations with a transition observed in the previous seven days. JSON uses RFC 3339 timestamps, explicit `null` for unavailable values, stable string enums, standard output for data, and standard error for diagnostics.

## Security And Reliability

- Run provider executables directly with argument arrays, never through a shell.
- Use subprocess timeouts and output-size limits.
- Permit HTTPS metadata URLs by default; reject local and executable URL schemes.
- Disable XML external entities and bound feed and HTTP response sizes.
- Bound redirect count, request duration, and HTTP concurrency.
- Sanitize terminal control characters from provider and release-note content.
- Use restrictive permissions for Sift's state directory and database.
- Record partial provider failures without discarding successful provider data.
- Never execute provider metadata, feed content, or release-note content.

## Licensing And Attribution

Sift is GPL-3.0-or-later. Selected macOS application, Sparkle, App Store, and Homebrew implementation details may be adapted from [Latest](https://github.com/mangerlahn/Latest), also GPL-3.0. Adapted code must preserve its applicable copyright and license notices, identify its upstream source and revision in `NOTICE`, and record material modifications.

## Delivery Milestones

1. Foundation: executable, database migrations, cache-only dashboard, JSON contract, and tests.
2. Native inventory: discover application bundles and persist observations.
3. Homebrew: all prefixes, formulae, casks, requested classification, and authoritative artifact reconciliation.
4. History: transitions, availability, recent views, and stale-cache behavior.
5. Sparkle: secure appcast retrieval, channel/version selection, notes, and caching.
6. App Store: exact bundle lookup and cached release notes.
7. Reconciliation and UX: detail views, diagnostics, provenance display, and output polish.
8. Release hardening: fixtures, integration tests, Apple Silicon/Intel validation, documentation, archives, and optional signing/notarization.

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
