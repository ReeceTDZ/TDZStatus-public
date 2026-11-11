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
        // Include inactive connections for every provider so they can be enabled
        // from the app and their last saved usage remains available by account.
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
            q.created_at,
            q.id,
            CASE WHEN json_valid(p.provider_specific_data) THEN json_extract(p.provider_specific_data, '$.workspacePlanType') END,
            (SELECT h.remaining_percentage FROM quota_snapshots h
             WHERE h.provider = q.provider AND h.connection_id = q.connection_id AND h.window_key = q.window_key
               AND h.next_reset_at = q.next_reset_at AND datetime(h.created_at) < datetime(q.created_at, '-30 minutes')
               AND datetime(h.created_at) >= datetime(q.created_at, '-5 hours')
             ORDER BY h.created_at ASC LIMIT 1),
            (SELECT h.created_at FROM quota_snapshots h
             WHERE h.provider = q.provider AND h.connection_id = q.connection_id AND h.window_key = q.window_key
               AND h.next_reset_at = q.next_reset_at AND datetime(h.created_at) < datetime(q.created_at, '-30 minutes')
               AND datetime(h.created_at) >= datetime(q.created_at, '-5 hours')
             ORDER BY h.created_at ASC LIMIT 1),
            (SELECT h.remaining_percentage FROM quota_snapshots h
             WHERE h.provider = q.provider AND h.connection_id = q.connection_id AND h.window_key = q.window_key
               AND h.next_reset_at = q.next_reset_at AND datetime(h.created_at) <= datetime(q.created_at, '-1 day')
               AND datetime(h.created_at) >= datetime(q.created_at, '-7 days')
             ORDER BY h.created_at ASC LIMIT 1),
            (SELECT h.created_at FROM quota_snapshots h
             WHERE h.provider = q.provider AND h.connection_id = q.connection_id AND h.window_key = q.window_key
               AND h.next_reset_at = q.next_reset_at AND datetime(h.created_at) <= datetime(q.created_at, '-1 day')
               AND datetime(h.created_at) >= datetime(q.created_at, '-7 days')
             ORDER BY h.created_at ASC LIMIT 1)
        FROM provider_connections AS p
        LEFT JOIN (
            SELECT provider, connection_id, window_key, MAX(id) AS latest_id
            FROM quota_snapshots
            GROUP BY provider, connection_id, window_key
        ) AS latest
            ON latest.provider = p.provider AND latest.connection_id = p.id
        LEFT JOIN quota_snapshots AS q ON q.id = latest.latest_id
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
                windows: [],
                planName: stringColumn(statement, 11)
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
                    capturedAt: parseQuotaDate(stringColumn(statement, 9)),
                    snapshotID: sqlite3_column_type(statement, 10) == SQLITE_NULL
                        ? nil : sqlite3_column_int64(statement, 10),
                    priorRemaining: sqlite3_column_type(statement, 12) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 12),
                    priorCapturedAt: parseQuotaDate(stringColumn(statement, 13)),
                    weekPriorRemaining: sqlite3_column_type(statement, 14) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 14),
                    weekPriorCapturedAt: parseQuotaDate(stringColumn(statement, 15))
                ))
            }
            records[accountKey] = account
        }

        if sqlite3_errcode(database) != SQLITE_OK && sqlite3_errcode(database) != SQLITE_DONE {
            throw OmniRouteReadError.query(database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "query failed")
        }
        // OmniRoute changed the label for some primary Codex windows. Snapshots
        // with the same account and reset are the same window, so keep the most
        // recently captured reading instead of counting both in the pool.
        for key in Array(records.keys) {
            guard var account = records[key], account.provider.caseInsensitiveCompare("codex") == .orderedSame,
                  let primary = account.windows.first(where: { $0.key == "unknown_primary" }),
                  let session = account.windows.first(where: { $0.key == "session" }),
                  let reset = primary.resetsAt, let sessionReset = session.resetsAt,
                  abs(reset.timeIntervalSince(sessionReset)) < 1 else { continue }
            let discard = (primary.capturedAt ?? .distantPast) >= (session.capturedAt ?? .distantPast) ? "session" : "unknown_primary"
            account.windows.removeAll { $0.key == discard }
            records[key] = account
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
