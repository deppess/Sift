import CSQLite
import Foundation

/// Inventories stored as managed packages: npm, uv, Steam, MacPorts, cargo.
extension Database {
    public func hasActiveManagedPackages(provider: RefreshProvider) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try scalarInt("SELECT EXISTS(SELECT 1 FROM managed_packages WHERE active = 1 AND provider = ?);", bindings: [.text(provider.rawValue)]) == 1
    }

    func applyManagedPackageInventoryLocked(_ inventory: ManagedPackageInventory, observedAt: Date) throws {
        for scope in inventory.scopes {
            for package in scope.packages {
                // A nil availableVersion is ambiguous: it means "confirmed not outdated" when this
                // round's data for this package is trustworthy, but "unknown this round" when the
                // whole scope's outdated check failed or just this package's version was inconsistent
                // between the inventory and outdated-check calls. Only overwrite the cached value in
                // the former case, matching homebrew_packages' target resolution, which distinguishes
                // "resolved to nothing" from "failed to resolve." This is deliberately per-package
                // (not scope-wide): one package's inconsistent data must not block legitimate updates
                // for every other package in the same scope.
                let trustworthy = scope.outdatedDataComplete && package.isVersionConsistent
                try recordPackageTransition(
                    provider: inventory.provider.rawValue, scope: scope.scope, kind: "package", name: package.name, to: package.installedVersion,
                    observedAt: observedAt,
                    previous: "SELECT installed_version, observed_at FROM managed_packages WHERE provider = ? AND scope = ? AND name = ?;",
                    bindings: [.text(inventory.provider.rawValue), .text(scope.scope), .text(package.name)])
                try run(
                    "INSERT INTO managed_packages (provider, scope, name, installed_version, available_version, active, observed_at, last_seen_at, requested, self_updating, identifier) VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?) ON CONFLICT(provider, scope, name) DO UPDATE SET installed_version = excluded.installed_version, identifier = COALESCE(excluded.identifier, managed_packages.identifier), available_version = CASE WHEN ? = 1 THEN excluded.available_version ELSE managed_packages.available_version END, active = 1, observed_at = excluded.observed_at, last_seen_at = excluded.last_seen_at, requested = excluded.requested, self_updating = excluded.self_updating;",
                    bindings: [
                        .text(inventory.provider.rawValue), .text(scope.scope), .text(package.name), .text(package.installedVersion),
                        .optionalText(package.availableVersion), .double(observedAt.timeIntervalSince1970), .double(observedAt.timeIntervalSince1970),
                        .int(package.requested ? 1 : 0), .int(package.selfUpdating ? 1 : 0), .optionalText(package.identifier), .int(trustworthy ? 1 : 0)
                    ])
                let packageID = try selectID(
                    "SELECT id FROM managed_packages WHERE provider = ? AND scope = ? AND name = ?;",
                    bindings: [.text(inventory.provider.rawValue), .text(scope.scope), .text(package.name)])
                if let packageID {
                    try run("DELETE FROM managed_artifacts WHERE managed_package_id = ?;", bindings: [.int64(packageID)])
                    for path in Set(package.applicationPaths) {
                        try run(
                            "INSERT INTO managed_artifacts (managed_package_id, normalized_path) VALUES (?, ?);", bindings: [.int64(packageID), .text(path)])
                    }
                }
            }
            try run(
                "UPDATE managed_packages SET active = 0 WHERE provider = ? AND scope = ? AND last_seen_at < ?;",
                bindings: [.text(inventory.provider.rawValue), .text(scope.scope), .double(observedAt.timeIntervalSince1970)])
        }
    }

    /// Logs a version change when a package already on record reports a different installed
    /// version. `previous` selects the stored installed_version and observed_at.
    func recordPackageTransition(
        provider: String, scope: String, kind: String, name: String, to version: String, observedAt: Date, previous: String, bindings: [Binding]
    ) throws {
        var stored: (version: String, observedAt: Double)?
        try withStatement(previous) { statement in
            try bind(statement, bindings)
            if try stepRow(statement) { stored = (String(cString: sqlite3_column_text(statement, 0)), sqlite3_column_double(statement, 1)) }
        }
        guard let stored, stored.version != version else { return }
        try run(
            "INSERT INTO package_transitions (provider, scope, kind, name, from_version, to_version, first_observed_at, observed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
            bindings: [
                .text(provider), .text(scope), .text(kind), .text(name), .text(stored.version), .text(version), .double(stored.observedAt),
                .double(observedAt.timeIntervalSince1970)
            ])
    }
}
