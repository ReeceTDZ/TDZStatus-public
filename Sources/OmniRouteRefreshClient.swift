import Foundation
import Security

enum OmniRouteRefreshError: LocalizedError {
    case emptyCookie
    case invalidCookieHeader
    case missingDashboardCookie
    case invalidCSRFResponse
    case httpStatus(Int)
    case accountUpdateFailed(Int)
    case keychain(String)

    var errorDescription: String? {
        switch self {
        case .emptyCookie: "Paste OmniRoute's dashboard auth_token cookie."
        case .invalidCookieHeader: "Paste a Cookie-Editor header in name=value; name=value format."
        case .missingDashboardCookie: "The header must include OmniRoute's auth_token cookie."
        case .invalidCSRFResponse: "OmniRoute did not return a dashboard refresh token."
        case .httpStatus(let code) where code == 401 || code == 403:
            "OmniRoute rejected the dashboard session (HTTP \(code)). Reconnect it in Settings."
        case .httpStatus(let code): "OmniRoute dashboard request failed (HTTP \(code))."
        case .accountUpdateFailed(let code) where code == 401 || code == 403:
            "OmniRoute rejected the dashboard session (HTTP \(code)). Reconnect it in Settings."
        case .accountUpdateFailed(let code) where code == 404:
            "OmniRoute couldn't find this provider account (HTTP 404). Refresh the provider list and try again."
        case .accountUpdateFailed(let code): "OmniRoute rejected the account status change (HTTP \(code))."
        case .keychain(let reason): "Couldn't access the OmniRoute dashboard session in Keychain: \(reason)"
        }
    }

    var isAuthenticationFailure: Bool {
        switch self {
        case .httpStatus(401), .httpStatus(403), .accountUpdateFailed(401), .accountUpdateFailed(403): true
        default: false
        }
    }
}

/// Stores only the local OmniRoute dashboard session cookie. TDZStatus uses it
/// only against localhost to ask OmniRoute to refresh its own provider limits.
final class OmniRouteDashboardSessionStore {
    private let service = "com.reecedove.tdzstatus.public.omniroute-dashboard"
    private let account = "auth_token"

    func cookie() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let resultCode = SecItemCopyMatching(query as CFDictionary, &result)
        guard resultCode == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw OmniRouteRefreshError.keychain(SecCopyErrorMessageString(resultCode, nil) as String? ?? "Keychain item is unavailable")
        }
        return value
    }

    func save(cookie: String) throws {
        let value = try Self.normalizedCookieHeader(cookie)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let updateCode = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if updateCode == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addCode = SecItemAdd(item as CFDictionary, nil)
            guard addCode == errSecSuccess else {
                throw OmniRouteRefreshError.keychain(SecCopyErrorMessageString(addCode, nil) as String? ?? "Keychain error \(addCode)")
            }
        } else if updateCode != errSecSuccess {
            throw OmniRouteRefreshError.keychain(SecCopyErrorMessageString(updateCode, nil) as String? ?? "Keychain error \(updateCode)")
        }
    }

    func remove() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func normalizedCookieHeader(_ input: String) throws -> String {
        var header = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !header.isEmpty else { throw OmniRouteRefreshError.emptyCookie }
        if let colon = header.firstIndex(of: ":"),
           header[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Cookie") == .orderedSame {
            header = String(header[header.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let pairs = header.split(separator: ";", omittingEmptySubsequences: true).compactMap { segment -> (String, String)? in
            let pieces = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { return nil }
            let name = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { return nil }
            return (name, value)
        }
        guard !pairs.isEmpty else { throw OmniRouteRefreshError.invalidCookieHeader }
        guard let token = pairs.first(where: { $0.0 == "auth_token" }) else {
            throw OmniRouteRefreshError.missingDashboardCookie
        }
        return "auth_token=\(token.1)"
    }
}

struct OmniRouteRefreshClient {
    private let baseURL = URL(string: "http://localhost:20128")!
    private let session = URLSession(configuration: .ephemeral)

    func validate(cookie: String, completion: @escaping (Result<Void, Error>) -> Void) {
        csrfToken(cookie: cookie) { result in
            completion(result.map { _ in () })
        }
    }

    func refresh(cookie: String, completion: @escaping (Result<Void, Error>) -> Void) {
        csrfToken(cookie: cookie) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let csrf):
                var request = URLRequest(url: self.baseURL.appendingPathComponent("api/usage/provider-limits"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
                request.httpMethod = "POST"
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
                request.setValue(csrf, forHTTPHeaderField: "x-omniroute-csrf")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("TDZStatus/0.1.0", forHTTPHeaderField: "User-Agent")
                self.session.dataTask(with: request) { _, response, error in
                    if let error { completion(.failure(error)); return }
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(code) else {
                        completion(.failure(OmniRouteRefreshError.httpStatus(code)))
                        return
                    }
                    completion(.success(()))
                }.resume()
            }
        }
    }

    /// Changes a provider connection through OmniRoute's dashboard API. The
    /// local SQLite database remains read-only to TDZStatus; OmniRoute owns the
    /// account state and persists the change itself.
    func setAccountActive(
        connectionID: String,
        isActive: Bool,
        cookie: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        csrfToken(cookie: cookie) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let csrf):
                let allowedPathCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
                let encodedID = connectionID.addingPercentEncoding(withAllowedCharacters: allowedPathCharacters) ?? connectionID
                guard let url = URL(string: "/api/providers/\(encodedID)", relativeTo: self.baseURL)?.absoluteURL else {
                    completion(.failure(OmniRouteRefreshError.accountUpdateFailed(0)))
                    return
                }

                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                request.httpMethod = "PUT"
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
                request.setValue(csrf, forHTTPHeaderField: "x-omniroute-csrf")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("TDZStatus/0.1.0", forHTTPHeaderField: "User-Agent")
                request.httpBody = try? JSONSerialization.data(withJSONObject: ["isActive": isActive])

                self.session.dataTask(with: request) { _, response, error in
                    if let error { completion(.failure(error)); return }
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(code) else {
                        completion(.failure(OmniRouteRefreshError.accountUpdateFailed(code)))
                        return
                    }
                    completion(.success(()))
                }.resume()
            }
        }
    }

    private func csrfToken(cookie: String, completion: @escaping (Result<String, Error>) -> Void) {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/auth/csrf"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                completion(.failure(OmniRouteRefreshError.httpStatus(code)))
                return
            }
            guard let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = object["token"] as? String,
                  !token.isEmpty else {
                completion(.failure(OmniRouteRefreshError.invalidCSRFResponse))
                return
            }
            completion(.success(token))
        }.resume()
    }
}
