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
                try run("INSERT INTO managed_packages (provider, scope, name, installed_version, available_version, active, observed_at, last_seen_at, requested, self_updating) VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, ?) ON CONFLICT(provider, scope, name) DO UPDATE SET installed_version = excluded.installed_version, available_version = CASE WHEN ? = 1 THEN excluded.available_version ELSE managed_packages.available_version END, active = 1, observed_at = excluded.observed_at, last_seen_at = excluded.last_seen_at, requested = excluded.requested, self_updating = excluded.self_updating;", bindings: [.text(inventory.provider.rawValue), .text(scope.scope), .text(package.name), .text(package.installedVersion), .optionalText(package.availableVersion), .double(observedAt.timeIntervalSince1970), .double(observedAt.timeIntervalSince1970), .int(package.requested ? 1 : 0), .int(package.selfUpdating ? 1 : 0), .int(trustworthy ? 1 : 0)])
                let packageID = try selectID("SELECT id FROM managed_packages WHERE provider = ? AND scope = ? AND name = ?;", bindings: [.text(inventory.provider.rawValue), .text(scope.scope), .text(package.name)])
                if let packageID {
                    try run("DELETE FROM managed_artifacts WHERE managed_package_id = ?;", bindings: [.int64(packageID)])
                    for path in Set(package.applicationPaths) { try run("INSERT INTO managed_artifacts (managed_package_id, normalized_path) VALUES (?, ?);", bindings: [.int64(packageID), .text(path)]) }
                }
            }
            try run("UPDATE managed_packages SET active = 0 WHERE provider = ? AND scope = ? AND last_seen_at < ?;", bindings: [.text(inventory.provider.rawValue), .text(scope.scope), .double(observedAt.timeIntervalSince1970)])
        }
    }
}
