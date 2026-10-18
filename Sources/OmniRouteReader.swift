import Foundation
import SQLite3

enum OmniRouteReadError: LocalizedError {
    case missingDatabase(String)
    case open(String)
    case query(String)

    var errorDescription: String? {
        switch self {
        case .missingDatabase(let path): "OmniRoute database not found at \(path)."
        case .open(let message): "Couldn't open OmniRoute's local usage database: \(message)"
        case .query(let message): "Couldn't read OmniRoute quota snapshots: \(message)"
        }
    }
}

struct OmniRouteReadResult {
    var accounts: [ProviderAccount]
    var readAt: Date
}

struct OmniRouteReader: Sendable {
    static let defaultDatabaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".omniroute/storage.sqlite")

    private let databaseURL: URL

    init(databaseURL: URL = OmniRouteReader.defaultDatabaseURL) {
        self.databaseURL = databaseURL
    }

    func readAccounts() throws -> OmniRouteReadResult {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw OmniRouteReadError.missingDatabase(databaseURL.path)
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "unknown error"
            if let database { sqlite3_close(database) }
            throw OmniRouteReadError.open(message)
        }
        defer { sqlite3_close(database) }

        // This intentionally selects only public account labels and quota fields.
        // Credential columns (API keys, access/refresh tokens, cookies, ID tokens,
        // provider-specific data) are never read by TDZStatus.
        let sql = """
        SELECT
            p.provider,
            p.id,
            COALESCE(NULLIF(p.display_name, ''), NULLIF(p.name, ''), NULLIF(p.email, ''), 'Account') AS account_name,
            COALESCE(p.is_active, 1) AS is_active,
            q.window_key,
            q.remaining_percentage,
            q.is_exhausted,
            q.next_reset_at,
            q.window_duration_ms,
            q.created_at
        FROM provider_connections AS p
        LEFT JOIN (
            SELECT provider, connection_id, window_key, MAX(id) AS latest_id
            FROM quota_snapshots
            GROUP BY provider, connection_id, window_key
        ) AS latest
            ON latest.provider = p.provider AND latest.connection_id = p.id
        LEFT JOIN quota_snapshots AS q ON q.id = latest.latest_id
        WHERE COALESCE(p.is_active, 1) != 0
        ORDER BY p.provider COLLATE NOCASE, account_name COLLATE NOCASE, q.window_key COLLATE NOCASE
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw OmniRouteReadError.query(database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "invalid query")
        }
        defer { sqlite3_finalize(statement) }

        var records: [String: ProviderAccount] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let provider = stringColumn(statement, 0),
                  let connectionID = stringColumn(statement, 1) else { continue }
            let accountKey = "\(provider)|\(connectionID)"
            var account = records[accountKey] ?? ProviderAccount(
                provider: provider,
                connectionID: connectionID,
                displayName: stringColumn(statement, 2) ?? "Account",
                isActive: sqlite3_column_int(statement, 3) != 0,
                windows: []
            )

            if let key = stringColumn(statement, 4) {
                let remaining = sqlite3_column_type(statement, 5) == SQLITE_NULL
                    ? nil : sqlite3_column_double(statement, 5)
                let duration = sqlite3_column_type(statement, 8) == SQLITE_NULL
                    ? nil : sqlite3_column_int64(statement, 8)
                account.windows.append(QuotaWindow(
                    provider: provider,
                    connectionID: connectionID,
                    accountName: account.displayName,
                    key: key,
                    remainingPercentage: remaining.map { min(100, max(0, $0)) },
                    isExhausted: sqlite3_column_int(statement, 6) != 0,
                    resetsAt: parseQuotaDate(stringColumn(statement, 7)),
                    durationMilliseconds: duration,
                    capturedAt: parseQuotaDate(stringColumn(statement, 9))
                ))
            }
            records[accountKey] = account
        }

        if sqlite3_errcode(database) != SQLITE_OK && sqlite3_errcode(database) != SQLITE_DONE {
            throw OmniRouteReadError.query(database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "query failed")
        }
        return OmniRouteReadResult(
            accounts: records.values.sorted {
                let providerOrder = $0.provider.localizedCaseInsensitiveCompare($1.provider)
                if providerOrder != .orderedSame { return providerOrder == .orderedAscending }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            },
            readAt: Date()
        )
    }

    private func stringColumn(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }
}
