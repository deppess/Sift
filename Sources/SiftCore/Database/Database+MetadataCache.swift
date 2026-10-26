import CSQLite
import Foundation

/// Cached HTTP metadata responses.
extension Database {
    public func cachedMetadataResponse(url: String, resourceKind: String) throws -> CachedMetadataResponse? {
        lock.lock()
        defer { lock.unlock() }
        var response: CachedMetadataResponse?
        try withStatement("SELECT status_code, body, etag, last_modified, validated_at FROM metadata_http_cache WHERE request_url = ? AND resource_kind = ?;") { statement in
            try bind(statement, [.text(url), .text(resourceKind)])
            if try stepRow(statement) {
                let body: Data?
                if sqlite3_column_type(statement, 1) == SQLITE_NULL {
                    body = nil
                } else if let bytes = sqlite3_column_blob(statement, 1) {
                    body = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
                } else {
                    body = Data()
                }
                response = CachedMetadataResponse(statusCode: Int(sqlite3_column_int(statement, 0)), body: body, etag: optionalText(statement, column: 2), lastModified: optionalText(statement, column: 3), validatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)))
            }
        }
        return response
    }

    public func storeMetadataResponse(url: String, resourceKind: String, statusCode: Int, body: Data?, etag: String?, lastModified: String?, validatedAt: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        try run("INSERT INTO metadata_http_cache (request_url, resource_kind, status_code, body, etag, last_modified, validated_at) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(request_url, resource_kind) DO UPDATE SET status_code = excluded.status_code, body = excluded.body, etag = excluded.etag, last_modified = excluded.last_modified, validated_at = excluded.validated_at;", bindings: [.text(url), .text(resourceKind), .int(Int32(statusCode)), .blob(body), .optionalText(etag), .optionalText(lastModified), .double(validatedAt.timeIntervalSince1970)])
    }

    func setting(_ key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        var value: String?
        try withStatement("SELECT value FROM settings WHERE key = ?;") { statement in
            try bind(statement, [.text(key)])
            if try stepRow(statement) { value = optionalText(statement, column: 0) }
        }
        return value
    }

    func setSetting(_ key: String, value: String) throws {
        lock.lock(); defer { lock.unlock() }
        try run("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;", bindings: [.text(key), .text(value)])
    }
}
