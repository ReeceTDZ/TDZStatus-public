import Foundation

struct ZCodeQuotaBalance: Identifiable, Hashable {
    let model: String
    let remaining: Int
    let total: Int
    let resetsAt: Date?

    var id: String { model }
    var remainingPercentage: Double? {
        guard total > 0 else { return nil }
        return min(100, max(0, Double(remaining) / Double(total) * 100))
    }
}

struct ZCodeUsageSnapshot {
    let balances: [ZCodeQuotaBalance]
    let capturedAt: Date?
}

struct ZCodeUsageReader: Sendable {
    private static let storageDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ZCode/session/Local Storage/leveldb", isDirectory: true)
    private static let snapshotKeys = [
        "zcode:usage-entitlement:subscription-v2:account:zai-start-plan",
        "zcode:usage-entitlement:builtin:zai-start-plan",
    ]

    func read() -> ZCodeUsageSnapshot? {
        guard let snapshot = newestSnapshot(),
              let body = snapshot["snapshot"] as? [String: Any],
              let quota = body["quota"] as? [String: Any],
              let limits = quota["limits"] as? [[String: Any]] else { return nil }

        var balances: [String: ZCodeQuotaBalance] = [:]
        for limit in limits {
            guard let details = limit["usageDetails"] as? [[String: Any]] else { continue }
            let remaining = integer(limit["remaining"]) ?? 0
            let total = integer(limit["number"]) ?? 0
            let reset = integer64(limit["nextResetTime"]).flatMap { milliseconds in
                milliseconds > 0 ? Date(timeIntervalSince1970: Double(milliseconds) / 1000) : nil
            }
            for detail in details {
                guard let model = detail["displayName"] as? String, !model.isEmpty else { continue }
                let previous = balances[model]
                balances[model] = ZCodeQuotaBalance(
                    model: model,
                    remaining: (previous?.remaining ?? 0) + remaining,
                    total: (previous?.total ?? 0) + total,
                    resetsAt: [previous?.resetsAt, reset].compactMap { $0 }.max()
                )
            }
        }

        let cachedAt = integer64(snapshot["cachedAt"]).flatMap { value in
            value > 100_000_000_000
                ? Date(timeIntervalSince1970: Double(value) / 1000)
                : Date(timeIntervalSince1970: Double(value))
        }
        return ZCodeUsageSnapshot(
            balances: balances.values.sorted { $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending },
            capturedAt: cachedAt
        )
    }

    private func newestSnapshot() -> [String: Any]? {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: Self.storageDirectory, includingPropertiesForKeys: nil) else { return nil }

        var newestTimestamp: Int64 = 0
        var newest: [String: Any]?
        for file in files where ["log", "ldb"].contains(file.pathExtension.lowercased()) {
            guard let raw = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
            let text = String(decoding: raw, as: UTF8.self)
            for key in Self.snapshotKeys {
                var searchStart = text.startIndex
                while let keyRange = text.range(of: key, range: searchStart..<text.endIndex) {
                    guard let start = text.range(of: "{\"cachedAt\":", range: keyRange.upperBound..<text.endIndex) else { break }
                    if let end = matchingJSONObjectEnd(in: text, startingAt: start.lowerBound) {
                        let json = String(text[start.lowerBound...end])
                        if let data = json.data(using: .utf8),
                           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let timestamp = integer64(object["cachedAt"]), timestamp > newestTimestamp {
                            newestTimestamp = timestamp
                            newest = object
                        }
                        searchStart = text.index(after: end)
                    } else {
                        searchStart = keyRange.upperBound
                    }
                }
            }
        }
        return newest
    }

    private func matchingJSONObjectEnd(in text: String, startingAt start: String.Index) -> String.Index? {
        var depth = 0
        var index = start
        var inString = false
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" && inString {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private func integer(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func integer64(_ value: Any?) -> Int64? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }
}
