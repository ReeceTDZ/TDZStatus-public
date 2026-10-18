import Foundation

struct CodexResetForecast {
    struct Probability {
        let next24Hours: Int
        let next48Hours: Int
    }

    let probability: Probability
    let confidence: String?
    let lastResetAt: Date?
    let updatedAt: Date?
    let likelyWindow: String?
    let likelyWindowTimeZone: String?
}

private struct CodexResetForecastResponse: Decodable {
    struct Probabilities: Decodable {
        let rounded24Hours: Double?
        let rounded48Hours: Double?

        enum CodingKeys: String, CodingKey {
            case rounded24Hours = "rounded_24h"
            case rounded48Hours = "rounded_48h"
        }
    }

    struct TimeWindow: Decodable {
        let label: String?
        let timezone: String?
    }

    let probabilities: Probabilities
    let confidence: String?
    let lastResetAt: String?
    let updatedAt: String?
    let timeWindow: TimeWindow?

    enum CodingKeys: String, CodingKey {
        case probabilities
        case confidence
        case lastResetAt = "last_reset_at"
        case updatedAt = "updated_at"
        case timeWindow = "time_window"
    }
}

enum CodexResetForecastError: LocalizedError {
    case badResponse
    case httpStatus(Int, retryAfter: TimeInterval?)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .badResponse: "Codex Reset returned an unexpected response."
        case .httpStatus(let code, _): "Codex Reset returned HTTP \(code)."
        case .invalidData: "Codex Reset's forecast could not be read."
        }
    }
}

final class CodexResetForecastFetcher {
    private let endpoint = URL(string: "https://codex-reset.com/api/forecast?tz=\(TimeZone.current.identifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "UTC")")!

    func fetch(completion: @escaping (Result<CodexResetForecast, Error>) -> Void) {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TDZStatus/0.1.0 (local macOS menu bar app; source: https://codex-reset.com/developers)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let response = response as? HTTPURLResponse else {
                completion(.failure(CodexResetForecastError.badResponse))
                return
            }
            guard (200..<300).contains(response.statusCode) else {
                completion(.failure(CodexResetForecastError.httpStatus(
                    response.statusCode,
                    retryAfter: response.statusCode == 429 ? Self.retryDelay(response) : nil
                )))
                return
            }
            guard let data,
                  let response = try? JSONDecoder().decode(CodexResetForecastResponse.self, from: data),
                  let next24 = response.probabilities.rounded24Hours,
                  let next48 = response.probabilities.rounded48Hours else {
                completion(.failure(CodexResetForecastError.invalidData))
                return
            }

            let forecast = CodexResetForecast(
                probability: .init(
                    next24Hours: min(100, max(0, Int(next24.rounded()))),
                    next48Hours: min(100, max(0, Int(next48.rounded())))
                ),
                confidence: response.confidence,
                lastResetAt: Self.parseDate(response.lastResetAt),
                updatedAt: Self.parseDate(response.updatedAt),
                likelyWindow: response.timeWindow?.label,
                likelyWindowTimeZone: response.timeWindow?.timezone
            )
            completion(.success(forecast))
        }.resume()
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private static func retryDelay(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }
}
