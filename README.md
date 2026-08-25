# Sift

Sift is a macOS-native command-line observer for installed software, available updates, observed version changes, and trustworthy release notes.

The project is in its foundation phase. It creates and reads its SQLite cache, exposes a **pre-v1** JSON dashboard envelope, and inventories native macOS application bundles during `refresh`.

## Build And Run

```sh
swift build
swift run sift
swift run sift --json
swift run sift refresh
swift run sift apps
swift test
```

The XCTest suite covers the database dashboard, refresh freshness semantics, JSON encoding, and command return codes. `swift run SiftVerification` remains available as a dependency-free smoke check.

Run the opt-in local integration suite for real process, SQLite, permission, schema, and concurrency checks. It uses only unique temporary directories and never touches the default Sift database:

```sh
./Scripts/test-integration
```

Use an isolated database while developing:

```sh
swift run sift --database /tmp/sift.sqlite3
```

`sift --help` writes usage to standard output and exits successfully. Argument errors exit with status 2. Dashboard data is always standard output; diagnostics are always standard error. Custom database parent directories must already exist.

`refresh` performs a read-only native application inventory of standard macOS application roots. It reads bundle `Info.plist` metadata only: it does not launch applications, run subprocesses, or perform network requests. `apps` displays that cached inventory without scanning again.

## Naming Conflict

An unrelated `sift` formula exists in Homebrew Core and provides a binary of the same name. This project intentionally retains the name. Do not expect `brew install sift` to install this project. A future Homebrew distribution would use a custom tap, but both binaries cannot coexist in the same Homebrew prefix.

## License

Sift is licensed under GPL-3.0-or-later. See [PROJECT.md](PROJECT.md) for architecture, scope, security, and attribution requirements.
