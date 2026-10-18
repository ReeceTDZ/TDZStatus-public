import AppKit
import Foundation

enum HarnessKind: String, CaseIterable, Identifiable, Codable {
    case zcode
    case claude
    case codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zcode: "ZCode"
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    var symbol: String {
        switch self {
        case .zcode: "sparkles"
        case .claude: "asterisk"
        case .codex: "command"
        }
    }

    var accent: NSColor {
        switch self {
        case .zcode: NSColor(srgbRed: 0.28, green: 0.73, blue: 0.53, alpha: 1)
        case .claude: NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        case .codex: NSColor(srgbRed: 0.43, green: 0.82, blue: 0.65, alpha: 1)
        }
    }
}

enum HarnessActivity: String, Codable {
    case idle
    case thinking
    case working

    var title: String {
        switch self {
        case .idle: "Idle"
        case .thinking: "Thinking"
        case .working: "Using tools"
        }
    }
}

struct HarnessState: Identifiable {
    var kind: HarnessKind
    var isOpen = false
    var isFrontmost = false
    var activity: HarnessActivity = .idle
    var model: String?
    var lastEvent: Date?

    var id: String { kind.rawValue }
    var isBusy: Bool { activity != .idle }
}

struct QuotaWindow: Identifiable, Hashable {
    var provider: String
    var connectionID: String
    var accountName: String
    var key: String
    var remainingPercentage: Double?
    var isExhausted: Bool
    var resetsAt: Date?
    var durationMilliseconds: Int64?
    var capturedAt: Date?

    var id: String { "\(provider)|\(connectionID)|\(key)" }
    var usedPercentage: Double? {
        remainingPercentage.map { min(100, max(0, 100 - $0)) }
    }
}

struct ProviderAccount: Identifiable {
    var provider: String
    var connectionID: String
    var displayName: String
    var isActive: Bool
    var windows: [QuotaWindow]

    var id: String { "\(provider)|\(connectionID)" }
    var hasUsage: Bool { !windows.isEmpty }
    var latestCapture: Date? { windows.compactMap(\.capturedAt).max() }
}

struct ProviderPool: Identifiable {
    var provider: String
    var accounts: [ProviderAccount]

    var id: String { provider }
    var windows: [QuotaWindow] { accounts.flatMap(\.windows) }
    var accountCount: Int { accounts.count }
    var accountsWithUsage: Int { accounts.filter(\.hasUsage).count }
    var windowKeys: [String] { Array(Set(windows.map(\.key))).sorted() }

    func accounts(for key: String) -> [QuotaWindow] {
        windows.filter { $0.key == key }
    }

    /// Providers expose percentages rather than a consistent absolute quota.
    /// The combined view therefore reports the average remaining percentage;
    /// it never pretends unlike account limits can be added together.
    func averageRemaining(for key: String) -> Double? {
        let values = accounts(for: key).compactMap(\.remainingPercentage)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    func nextReset(for key: String) -> Date? {
        accounts(for: key).compactMap(\.resetsAt).min()
    }
}

struct CodexQuotaWindow: Identifiable, Hashable {
    var id: String
    var title: String
    var usedPercentage: Double
    var windowDurationMinutes: Int?
    var resetsAt: Date?
}

struct CodexUsageSnapshot {
    var accountName: String?
    var planName: String?
    var windows: [CodexQuotaWindow]
    var fetchedAt: Date
}

enum IconPreference: String, CaseIterable, Identifiable {
    case automatic
    case cycleActive
    case zcode
    case claude
    case codex

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Follow open harness"
        case .cycleActive: "Cycle active harnesses"
        case .zcode: "Always ZCode"
        case .claude: "Always Claude"
        case .codex: "Always Codex"
        }
    }
}

enum ManualAnimationMode: String, CaseIterable, Identifiable {
    case automatic
    case multi
    case thinking
    case working

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Follow activity"
        case .multi: "Alternate every 7 seconds"
        case .thinking: "Thinking animation"
        case .working: "Tool animation"
        }
    }
}

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview
    case usage
    case settings

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .overview: "rectangle.grid.1x2"
        case .usage: "chart.bar.xaxis"
        case .settings: "slider.horizontal.3"
        }
    }
}

func displayProviderName(_ provider: String) -> String {
    let normalized = provider
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
    return normalized.split(separator: " ").map { part in
        guard let first = part.first else { return String(part) }
        return String(first).uppercased() + part.dropFirst()
    }.joined(separator: " ")
}

func parseQuotaDate(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    if let seconds = Double(value), seconds > 100_000_000 {
        return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
    }
    let iso = ISO8601DateFormatter()
    if let result = iso.date(from: value) { return result }
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return iso.date(from: value)
}
