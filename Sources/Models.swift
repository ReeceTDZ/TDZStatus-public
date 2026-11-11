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
    var priorRemaining: Double? = nil
    var priorCapturedAt: Date? = nil
    var weekPriorRemaining: Double? = nil
    var weekPriorCapturedAt: Date? = nil
    var balanceUSD: Double? = nil
    var consumedUSD: Double? = nil

    var id: String { "\(provider)|\(connectionID)|\(key)" }
    var usedPercentage: Double? {
        remainingPercentage.map { min(100, max(0, 100 - $0)) }
    }

    var isFiveHourWindow: Bool {
        if let durationMilliseconds { return (17_000_000...19_000_000).contains(durationMilliseconds) }
        let name = key.lowercased()
        if name.contains("5h") || name.contains("five_hour") || name.contains("5_hour") { return true }
        if name == "session", let reset = resetsAt, let captured = capturedAt {
            return reset > captured && reset.timeIntervalSince(captured) <= 18_000
        }
        return false
    }

    func projectedExhaustion(now: Date = Date()) -> Date? {
        guard let remainingPercentage, let old = priorRemaining,
              let start = priorCapturedAt, let end = capturedAt,
              end.timeIntervalSince(start) >= 1800, now.timeIntervalSince(end) < 21600,
              old > remainingPercentage, let reset = resetsAt, reset > now else { return nil }
        let rate = (old - remainingPercentage) / end.timeIntervalSince(start)
        return end.addingTimeInterval(remainingPercentage / rate)
    }

    var supportsPacePrediction: Bool {
        guard !isFiveHourWindow, remainingPercentage != nil, let reset = resetsAt, let captured = capturedAt else { return false }
        let name = key.lowercased()
        return name.contains("week") || name.contains("month") || name == "unknown_primary"
            || (durationMilliseconds ?? 0) >= 86_400_000 || reset.timeIntervalSince(captured) > 86_400
    }
}

struct ProviderAccount: Identifiable {
    var provider: String
    var connectionID: String
    var displayName: String
    var isActive: Bool
    var windows: [QuotaWindow]
    var planName: String? = nil

    var isPaidPlan: Bool {
        guard let plan = planName?.lowercased(), !plan.isEmpty else { return false }
        return !["free", "unknown", "none"].contains(plan)
    }

    var id: String { "\(provider)|\(connectionID)" }
    var hasUsage: Bool { !windows.isEmpty }
    var latestCapture: Date? { windows.compactMap(\.capturedAt).max() }

    /// The longest reported window represents the account's primary pool.
    var codexPrimary: QuotaWindow? {
        windows.filter { !$0.isFiveHourWindow && $0.remainingPercentage != nil }
            .max { ($0.resetsAt ?? .distantPast) < ($1.resetsAt ?? .distantPast) }
    }

    var codexSession: QuotaWindow? { windows.first(where: \.isFiveHourWindow) }
    var codexWeekly: QuotaWindow? {
        windows.first { $0.key.lowercased().contains("week") && !$0.isFiveHourWindow }
    }

    /// A rolling usage budget inferred from snapshots and time until the
    /// provider's real reset. It is never presented as an official limit.
    func estimatedBudget(period: TimeInterval, now: Date = Date()) -> Double? {
        guard let source = codexPrimary, let current = source.remainingPercentage,
              let captured = source.capturedAt, let reset = source.resetsAt,
              now.timeIntervalSince(captured) >= -60, now.timeIntervalSince(captured) < 6 * 3600,
              reset > now else { return nil }
        let baseline = period <= 18_000 ? source.priorRemaining : source.weekPriorRemaining
        let baselineDate = period <= 18_000 ? source.priorCapturedAt : source.weekPriorCapturedAt
        guard let baseline, let baselineDate, baseline >= current,
              captured.timeIntervalSince(baselineDate) >= (period <= 18_000 ? 4.5 * 3600 : 6 * 86400) else { return nil }
        let spent = baseline - current
        let fairRemaining = min(current, current * period / reset.timeIntervalSince(now))
        let budget = spent + fairRemaining
        guard budget > 0 else { return 0 }
        return max(0, min(100, 100 * fairRemaining / budget))
    }

    var paceWindows: [QuotaWindow] { windows.filter(\.supportsPacePrediction) }

    func paceAssessment(now: Date = Date()) -> (window: QuotaWindow, exhaustedAt: Date)? {
        paceWindows.compactMap { window -> (window: QuotaWindow, exhaustedAt: Date)? in
            guard let reset = window.resetsAt, let projected = window.projectedExhaustion(now: now), projected < reset else { return nil }
            return (window, projected)
        }.min { $0.exhaustedAt < $1.exhaustedAt }
    }
}

struct ProviderPool: Identifiable {
    var provider: String
    var accounts: [ProviderAccount]
    var hiddenUsageIDs: Set<String> = []

    var id: String { provider }
    var windows: [QuotaWindow] { accounts.flatMap(\.windows) }
    var activeAccounts: [ProviderAccount] { accounts.filter(\.isActive) }
    var activeWindows: [QuotaWindow] { activeAccounts.flatMap(\.windows) }
    var accountCount: Int { accounts.count }
    var activeAccountCount: Int { activeAccounts.count }
    var disabledAccountCount: Int { accountCount - activeAccountCount }
    /// Number of accounts with saved quota data, including disabled accounts.
    var accountsWithUsage: Int { accounts.filter(\.hasUsage).count }
    var isSingleAccount: Bool { accountCount == 1 }
    var isAntigravity: Bool { provider.caseInsensitiveCompare("antigravity") == .orderedSame }
    var isGitHubCopilot: Bool { provider.caseInsensitiveCompare("github") == .orderedSame }
    var isCodex: Bool { provider.caseInsensitiveCompare("codex") == .orderedSame }

    var codexPrimaryWindows: [QuotaWindow] { accounts.compactMap(\.codexPrimary) }

    func codexFiveHourValues() -> [Double] {
        accounts.compactMap { $0.codexSession?.remainingPercentage ?? $0.estimatedBudget(period: 18_000) }
    }

    func codexWeeklyValues() -> [Double] {
        accounts.compactMap { account in
            if account.isPaidPlan { return account.codexWeekly?.remainingPercentage }
            return account.estimatedBudget(period: 604_800)
        }
    }

    var sortedAccounts: [ProviderAccount] {
        accounts.sorted {
            if isCodex && $0.isPaidPlan != $1.isPaidPlan { return $0.isPaidPlan }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func usageID(for key: String) -> String {
        providerUsageVisibilityID(provider, key)
    }

    func showsInApp(_ window: QuotaWindow) -> Bool {
        shows(window) && !hiddenUsageIDs.contains(usageID(for: window.key))
    }

    /// Some integrations publish individual model entries even though their
    /// consumption is charged against one shared window. Only show windows
    /// that represent independently meaningful limits.
    func shows(_ window: QuotaWindow) -> Bool {
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

    var allWindowKeys: [String] {
        Array(Set(windows.filter(shows).map(\.key))).sorted { lhs, rhs in
            displayQuotaWindowName(lhs, provider: provider)
                .localizedCaseInsensitiveCompare(displayQuotaWindowName(rhs, provider: provider)) == .orderedAscending
        }
    }

    var windowKeys: [String] {
        allWindowKeys.filter { !hiddenUsageIDs.contains(usageID(for: $0)) }
    }

    func accounts(for key: String) -> [QuotaWindow] {
        windows.filter { $0.key == key && showsInApp($0) }
    }

    func windows(for account: ProviderAccount) -> [QuotaWindow] {
        account.windows.filter(showsInApp).sorted {
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

func providerUsageVisibilityID(_ provider: String, _ key: String) -> String {
    "\(provider.lowercased())|\(key.lowercased())"
}

func isHiddenDashboardProvider(_ provider: String) -> Bool {
    let normalized = provider.lowercased()
    return normalized == "cline"
        || normalized.hasPrefix("cline-")
        || normalized == "nvidia"
        || normalized.hasPrefix("nvidia-")
        || normalized == "xkiro"
        || normalized.hasPrefix("xkiro ")
        || normalized.hasPrefix("xkiro-")
        || normalized == "kiro"
        || normalized.hasPrefix("kiro ")
        || normalized.hasPrefix("kiro-")
        || normalized.hasPrefix("codecraft")
        || isCodeCraftProvider(provider)
}

func displayQuotaWindowName(_ key: String, provider: String) -> String {
    if key.lowercased() == "unknown_primary" { return "Primary limit" }
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
    provider?.lowercased().contains("codecraft") == true
}

func isTokenHarborProvider(_ provider: String?) -> Bool {
    provider?.lowercased().contains("tokenharbor") == true || provider?.lowercased().contains("token-harbor") == true
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
