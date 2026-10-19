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
    var resetIsEstimated = false
    var capturedAt: Date?
    var snapshotID: Int64? = nil

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
    var isSingleAccount: Bool { accountCount == 1 }
    var isNVIDIA: Bool { provider.caseInsensitiveCompare("nvidia") == .orderedSame }
    var isAntigravity: Bool { provider.caseInsensitiveCompare("antigravity") == .orderedSame }
    var isGitHubCopilot: Bool { provider.caseInsensitiveCompare("github") == .orderedSame }
    var isCodex: Bool { provider.caseInsensitiveCompare("codex") == .orderedSame }

    /// Some integrations publish individual model entries even though their
    /// consumption is charged against one shared window. Only show windows
    /// that represent independently meaningful limits.
    func shows(_ window: QuotaWindow) -> Bool {
        if isNVIDIA { return false }
        if isAntigravity {
            return ["gemini_weekly", "claude_gpt_weekly"].contains(window.key)
        }
        // OmniRoute currently records 0% for these Copilot entries even when
        // they are not exhausted. Treat that value as unavailable rather than
        // rendering a false empty bar.
        if isGitHubCopilot,
           ["chat", "completions"].contains(window.key),
           window.remainingPercentage == 0,
           !window.isExhausted {
            return false
        }
        return true
    }

    var windowKeys: [String] {
        Array(Set(windows.filter(shows).map(\.key))).sorted { lhs, rhs in
            displayQuotaWindowName(lhs, provider: provider)
                .localizedCaseInsensitiveCompare(displayQuotaWindowName(rhs, provider: provider)) == .orderedAscending
        }
    }

    func accounts(for key: String) -> [QuotaWindow] {
        windows.filter { $0.key == key && shows($0) }
    }

    func windows(for account: ProviderAccount) -> [QuotaWindow] {
        account.windows.filter(shows).sorted {
            displayQuotaWindowName($0.key, provider: provider)
                .localizedCaseInsensitiveCompare(displayQuotaWindowName($1.key, provider: provider)) == .orderedAscending
        }
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

    func resetIsEstimated(for key: String) -> Bool {
        accounts(for: key).contains { $0.resetIsEstimated }
    }
}

func displayQuotaWindowName(_ key: String, provider: String) -> String {
    if provider.caseInsensitiveCompare("antigravity") == .orderedSame {
        switch key {
        case "gemini_weekly": return "Gemini · weekly"
        case "claude_gpt_weekly": return "Other models · weekly"
        default: break
        }
    }
    if provider.caseInsensitiveCompare("github") == .orderedSame {
        switch key {
        case "premium_interactions": return "Premium interactions"
        case "chat": return "Chat"
        case "completions": return "Completions"
        default: break
        }
    }
    return key
        .replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .capitalized
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
    let identifier = provider.lowercased()
    if identifier == "codecraft" { return "CodeCraft API" }
    if identifier == "tokenharbor" { return "Token Harbor" }
    if identifier.hasPrefix("anthropic-compatible") { return "Anthropic Compatible" }
    if identifier.hasPrefix("openai-compatible-chat") { return "OpenAI Compatible" }
    switch identifier {
    case "antigravity": return "Google Antigravity"
    case "github": return "GitHub Copilot"
    case "nvidia": return "NVIDIA"
    case "xkiro": return "xKiro"
    case "orcarouter": return "OrcaRouter"
    case "openrouter": return "OpenRouter"
    default: break
    }
    let normalized = provider
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
    return normalized.split(separator: " ").map { part in
        guard let first = part.first else { return String(part) }
        return String(first).uppercased() + part.dropFirst()
    }.joined(separator: " ")
}

func isCodeCraftProvider(_ provider: String?) -> Bool {
    provider?.caseInsensitiveCompare("codecraft") == .orderedSame
}

func isTokenHarborProvider(_ provider: String?) -> Bool {
    provider?.caseInsensitiveCompare("tokenharbor") == .orderedSame
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
