# Sift

Sift is a macOS-native command-line observer for installed software, available updates, observed version changes, and cached release notes.

`refresh` inventories native application bundles and detected Homebrew prefixes, resolves Homebrew update targets, and stores available Homebrew release notes. Other commands read the cache.

## Build And Run

```sh
swift build
swift run sift
swift run sift --json
swift run sift refresh
swift run sift apps
swift test
./Scripts/test-integration
./Scripts/test-security
./Scripts/benchmark
```

`swift test` runs the unit suite. `./Scripts/test-integration` runs the opt-in process, SQLite, permission, schema, and concurrency checks in unique temporary directories. `./Scripts/test-security` deterministically repeats the security regression and integration tests; it is not a fuzz harness. `./Scripts/benchmark` builds release configuration and reports repeated core-test timings. Set `SIFT_SECURITY_ITERATIONS` or `SIFT_BENCHMARK_ITERATIONS` to adjust runs; `SIFT_SECURITY_SEED` labels a security run.

`swift run SiftVerification` remains available as a dependency-free smoke check.

Use an isolated database while developing:

```sh
swift run sift --database /tmp/sift.sqlite3
```

`sift --help` writes usage to standard output and exits successfully. Argument errors exit with status 2. Dashboard data is always standard output; diagnostics are always standard error. A custom database parent directory must already exist, be a real directory, and either be private to the current user or sticky; database files must be user-owned regular single-link files.

`refresh` reads native bundle `Info.plist` metadata without launching applications, inventories Homebrew through detected `brew` executables, resolves Homebrew targets, and fetches release notes when applicable. `sift`, `apps`, `updates`, `show`, and dynamic completion lookups are cache-only: they do not run providers, make network requests, or write the database. Cached dashboard and Homebrew update output mark data stale after 24 hours; a failed or partial refresh preserves prior cached data and reports the incomplete state.

## Naming Conflict

An unrelated `sift` formula exists in Homebrew Core and provides a binary of the same name. This project intentionally retains the name. Do not expect `brew install sift` to install this project. A future Homebrew distribution would use a custom tap, but both binaries cannot coexist in the same Homebrew prefix.

## License

Sift is licensed under GPL-3.0-or-later. See [PROJECT.md](PROJECT.md) for architecture, scope, security, and attribution requirements.
