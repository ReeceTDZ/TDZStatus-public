import Foundation
import Security

enum CookieQuotaValueMode: String, Codable, CaseIterable, Identifiable {
    case remainingPercentage
    case usedPercentage
    case usedOfLimit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .remainingPercentage: "Remaining percentage"
        case .usedPercentage: "Used percentage"
        case .usedOfLimit: "Used amount and limit"
        }
    }
}

struct CookieQuotaSource: Codable, Identifiable, Hashable {
    var id: String
    var provider: String
    var connectionID: String
    var accountName: String
    var endpoint: String
    var windowKey: String
    var remainingField: String
    var resetField: String
    var durationField: String
    var valueIsUsedPercentage: Bool
    /// Optional fields preserve compatibility with dashboard sources saved by
    /// earlier releases, which only supported percentage-valued responses.
    var valueMode: CookieQuotaValueMode? = nil
    var limitField: String? = nil
    var updatedAt: Date

    var effectiveValueMode: CookieQuotaValueMode {
        valueMode ?? (valueIsUsedPercentage ? .usedPercentage : .remainingPercentage)
    }
}

enum CookieQuotaError: LocalizedError {
    case badEndpoint
    case emptyCookie
    case httpStatus(Int)
    case invalidJSON
    case invalidCookieHeader
    case missingXKiroCookies
    case missingField(String)
    case invalidNumber(String)
    case keychain(String)

    var errorDescription: String? {
        switch self {
        case .badEndpoint: "Enter an HTTPS usage endpoint (HTTP is allowed only for localhost)."
        case .emptyCookie: "Paste the website cookie for this account."
        case .httpStatus(let code): "The usage endpoint returned HTTP \(code). Check the endpoint and cookie."
        case .invalidJSON: "The endpoint did not return a JSON object."
        case .invalidCookieHeader: "Paste a Cookie-Editor header in name=value; name=value format."
        case .missingXKiroCookies: "The xKiro header must include __xt_at and __xt_rt cookies."
        case .missingField(let path): "The response did not contain the configured field ‘\(path)’."
        case .invalidNumber(let path): "The field ‘\(path)’ is not a number."
        case .keychain(let reason): "Couldn't store the cookie in Keychain: \(reason)"
        }
    }
}

final class CookieQuotaSourceStore {
    private let defaultsKey = "cookieQuotaSources"
    private let service = "com.reecedove.tdzstatus.provider-cookie"

    func sources() -> [CookieQuotaSource] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let sources = try? JSONDecoder().decode([CookieQuotaSource].self, from: data) else { return [] }
        return sources
    }

    func save(_ source: CookieQuotaSource, cookie: String) throws {
        let cleaned = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw CookieQuotaError.emptyCookie }
        let account = source.id as CFString
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: Data(cleaned.utf8)]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = Data(cleaned.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CookieQuotaError.keychain(SecCopyErrorMessageString(addStatus, nil) as String? ?? "Keychain error \(addStatus)") }
        } else if status != errSecSuccess {
            throw CookieQuotaError.keychain(SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)")
        }

        var current = sources().filter { $0.id != source.id }
        current.append(source)
        current.sort { $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending }
        let data = try JSONEncoder().encode(current)
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    func cookie(for sourceID: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sourceID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw CookieQuotaError.keychain(SecCopyErrorMessageString(status, nil) as String? ?? "Keychain item is unavailable")
        }
        return value
    }

    func remove(_ sourceID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sourceID,
        ]
        SecItemDelete(query as CFDictionary)
        let current = sources().filter { $0.id != sourceID }
        if let data = try? JSONEncoder().encode(current) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

final class CookieQuotaFetcher {
    private lazy var session = URLSession(
        configuration: .ephemeral,
        delegate: SameOriginCookieRedirectDelegate(),
        delegateQueue: nil
    )

    func fetch(source: CookieQuotaSource, cookie: String, completion: @escaping (Result<QuotaWindow, Error>) -> Void) {
        guard let url = URL(string: source.endpoint), validEndpoint(url) else {
            completion(.failure(CookieQuotaError.badEndpoint))
            return
        }
        let cleaned: String
        do {
            cleaned = try Self.normalizedCookieHeader(cookie, provider: source.provider)
        } catch {
            completion(.failure(error))
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
        request.httpMethod = "GET"
        request.setValue(cleaned, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TDZStatus/0.1.0", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                completion(.failure(CookieQuotaError.httpStatus(code)))
                return
            }
            guard let data,
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                completion(.failure(CookieQuotaError.invalidJSON))
                return
            }
            do {
                let value = try self.number(at: source.remainingField, in: object)
                let remaining: Double
                switch source.effectiveValueMode {
                case .remainingPercentage:
                    remaining = value
                case .usedPercentage:
                    remaining = 100 - value
                case .usedOfLimit:
                    guard let limitPath = source.limitField?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !limitPath.isEmpty else {
                        throw CookieQuotaError.missingField("usage limit")
                    }
                    let limit = try self.number(at: limitPath, in: object)
                    guard limit > 0 else { throw CookieQuotaError.invalidNumber(limitPath) }
                    remaining = 100 * (limit - value) / limit
                }
                let resetValue = self.value(at: source.resetField, in: object)
                let resetDate = self.date(from: resetValue)
                let duration = source.durationField.isEmpty ? nil : try? self.number(at: source.durationField, in: object)
                let window = QuotaWindow(
                    provider: source.provider,
                    connectionID: source.connectionID,
                    accountName: source.accountName,
                    key: source.windowKey,
                    remainingPercentage: min(100, max(0, remaining)),
                    isExhausted: remaining <= 0,
                    resetsAt: resetDate,
                    durationMilliseconds: duration.map { Int64($0 * 60_000) },
                    capturedAt: Date()
                )
                completion(.success(window))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    /// Cookie-Editor exports a normal semicolon-separated Cookie header. For
    /// xKiro, retain only its auth/account cookies and ignore theme/analytics
    /// values. Accept the older unprefixed cookie names as well.
    static func normalizedCookieHeader(_ cookie: String, provider: String) throws -> String {
        var header = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !header.isEmpty else { throw CookieQuotaError.emptyCookie }
        if let colon = header.firstIndex(of: ":"),
           header[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Cookie") == .orderedSame {
            header = String(header[header.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let pairs = header.split(separator: ";", omittingEmptySubsequences: true).compactMap { item -> (String, String)? in
            let pieces = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { return nil }
            let name = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { return nil }
            return (name, value)
        }
        guard !pairs.isEmpty else { throw CookieQuotaError.invalidCookieHeader }

        guard provider.caseInsensitiveCompare("xkiro") == .orderedSame else {
            return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
        }

        let aliases = [
            ["__xt_at", "xt_at"],
            ["__xt_rt", "xt_rt"],
            ["__xt_user", "xt_user"],
        ]
        var selected: [(String, String)] = []
        for names in aliases {
            if let pair = pairs.first(where: { names.contains($0.0) }) {
                selected.append(pair)
            }
        }
        guard selected.contains(where: { ["__xt_at", "xt_at"].contains($0.0) }),
              selected.contains(where: { ["__xt_rt", "xt_rt"].contains($0.0) }) else {
            throw CookieQuotaError.missingXKiroCookies
        }
        return selected.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    private func validEndpoint(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        return scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
    }

    private func value(at path: String, in root: Any) -> Any? {
        let parts: [String]
        if path.hasPrefix("/") {
            parts = path.dropFirst().split(separator: "/").map {
                String($0).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            }
        } else {
            parts = path.split(separator: ".").map(String.init)
        }
        return parts.reduce(Optional(root)) { value, part in
            guard let value else { return nil }
            if let dictionary = value as? [String: Any] { return dictionary[part] }
            if let array = value as? [Any], let index = Int(part), array.indices.contains(index) { return array[index] }
            return nil
        }
    }

    private func number(at path: String, in root: Any) throws -> Double {
        guard let value = value(at: path, in: root) else { throw CookieQuotaError.missingField(path) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String, let number = Double(string) { return number }
        throw CookieQuotaError.invalidNumber(path)
    }

    private func date(from value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue > 100_000_000_000 ? number.doubleValue / 1000 : number.doubleValue)
        }
        return parseQuotaDate(value as? String)
    }
}

private final class SameOriginCookieRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url,
              let target = request.url,
              original.scheme?.lowercased() == target.scheme?.lowercased(),
              original.host?.caseInsensitiveCompare(target.host ?? "") == .orderedSame,
              effectivePort(original) == effectivePort(target) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private func effectivePort(_ url: URL) -> Int {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}
