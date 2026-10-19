import AppKit
import Combine
import Foundation

enum OmniRouteStatus: Equatable {
    case disconnected
    case connected
    case unavailable(String)

    var message: String {
        switch self {
        case .disconnected: "Not connected"
        case .connected: "Connected locally"
        case .unavailable(let reason): reason
        }
    }
}

@MainActor
final class TDZStatusModel: ObservableObject {
    @Published var section: DashboardSection = .overview
    @Published private(set) var harnesses: [HarnessState] = HarnessKind.allCases.map { HarnessState(kind: $0) }
    @Published private(set) var accounts: [ProviderAccount] = []
    @Published private(set) var cookieSources: [CookieQuotaSource] = []
    @Published private(set) var cookieSourceErrors: [String: String] = [:]
    @Published private(set) var omniRouteStatus: OmniRouteStatus = .disconnected
    @Published private(set) var omniRouteReadAt: Date?
    @Published private(set) var codexSnapshot: CodexUsageSnapshot?
    @Published private(set) var codexStatusMessage = "Checking Codex account…"
    @Published private(set) var isRefreshingCodexUsage = false
    @Published private(set) var zcodeUsage: ZCodeUsageSnapshot?
    @Published private(set) var codexConfigSummary = CodexConfigSummary.read()
    @Published private(set) var codexResetForecast: CodexResetForecast?
    @Published private(set) var codexResetForecastError: String?
    @Published private(set) var isRefreshingCodexResetForecast = false
    @Published private(set) var lastRefreshAt: Date?
    @Published var refreshMessage: String?
    @Published var showOnboarding: Bool
    @Published var iconPreference: IconPreference {
        didSet { UserDefaults.standard.set(iconPreference.rawValue, forKey: "iconPreference") }
    }
    @Published var manualAnimationMode: ManualAnimationMode {
        didSet { UserDefaults.standard.set(manualAnimationMode.rawValue, forKey: "manualAnimationMode") }
    }
    @Published var splitAccounts = false {
        didSet { UserDefaults.standard.set(splitAccounts, forKey: "splitAccounts") }
    }
    @Published var showCodexGlobalEstimate = true {
        didSet {
            UserDefaults.standard.set(showCodexGlobalEstimate, forKey: "showCodexGlobalEstimate")
            if showCodexGlobalEstimate { refreshCodexResetForecast() }
        }
    }

    private var refreshTimer: Timer?
    private var codexRefreshTimer: Timer?
    private var cookieRefreshTimer: Timer?
    private var resetForecastTimer: Timer?
    private var resetForecastAllowedAfter = Date.distantPast
    private var zcodeReadInProgress = false
    private var cookieRequestsInProgress: Set<String> = []
    private let codexBridge = CodexUsageBridge()
    private let codexResetForecastFetcher = CodexResetForecastFetcher()
    private let cookieSourceStore = CookieQuotaSourceStore()
    private let cookieQuotaFetcher = CookieQuotaFetcher()
    private var omniRouteAccounts: [ProviderAccount] = []
    private var cookieWindows: [String: QuotaWindow] = [:]
    private let zcodeStateDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".zcode-status", isDirectory: true)
    private let codexStateDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex-status/sessions", isDirectory: true)
    private let tdzStateDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TDZStatus/sessions", isDirectory: true)

    var providerPools: [ProviderPool] {
        Dictionary(grouping: accounts, by: \.provider)
            .map { ProviderPool(provider: $0.key, accounts: $0.value) }
            .sorted { $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending }
    }

    var accountsMissingQuota: [ProviderAccount] {
        accounts.filter {
            $0.provider.caseInsensitiveCompare("nvidia") != .orderedSame && $0.windows.isEmpty
        }
    }

    var hasMultiAccountPools: Bool {
        providerPools.contains { $0.accountCount > 1 }
    }

    var codexProvidersMissingFromOmniRoute: [String] {
        let configured = Set(codexConfigSummary.activeProviders + codexConfigSummary.declaredProviders)
            .filter { $0.caseInsensitiveCompare("omniroute") != .orderedSame }
        let omniProviders = accounts.map { $0.provider.lowercased() }
        return configured.filter { provider in
            let normalized = provider.lowercased()
            return !omniProviders.contains { configuredProvider in
                configuredProvider == normalized || configuredProvider.hasPrefix(normalized + "-")
            }
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var codexConfigProviderSummary: String {
        let names = Array(Set(codexConfigSummary.activeProviders + codexConfigSummary.declaredProviders))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard !names.isEmpty else { return "No model providers were found in this Codex config." }
        if names.count == 1, names[0].caseInsensitiveCompare("omniroute") == .orderedSame {
            return "Codex routes through OmniRoute. Its provider accounts are listed below."
        }
        return names.map(displayProviderName).joined(separator: ", ")
    }

    var canRefreshCodexResetForecast: Bool {
        Date() >= resetForecastAllowedAfter
    }

    var busyHarnessCount: Int { harnesses.filter(\.isBusy).count }
    var openHarnessCount: Int { harnesses.filter(\.isOpen).count }

    var activitySummary: String {
        if busyHarnessCount > 0 { return "\(busyHarnessCount) harness\(busyHarnessCount == 1 ? "" : "es") working" }
        if openHarnessCount > 0 { return "\(openHarnessCount) harness\(openHarnessCount == 1 ? "" : "es") ready" }
        return "No harness open"
    }

    var iconHarness: HarnessKind {
        switch iconPreference {
        case .zcode: return .zcode
        case .claude: return .claude
        case .codex: return .codex
        case .automatic:
            if let frontmost = harnesses.first(where: \.isFrontmost) { return frontmost.kind }
            if let busy = harnesses.filter(\.isBusy).max(by: { ($0.lastEvent ?? .distantPast) < ($1.lastEvent ?? .distantPast) }) {
                return busy.kind
            }
            if let open = harnesses.first(where: \.isOpen) { return open.kind }
            return .zcode
        case .cycleActive:
            let active = harnesses.filter { $0.isOpen || $0.isBusy }
            guard !active.isEmpty else { return .zcode }
            let index = Int(Date().timeIntervalSince1970 / 3) % active.count
            return active[index].kind
        }
    }

    init() {
        let defaults = UserDefaults.standard
        iconPreference = IconPreference(rawValue: defaults.string(forKey: "iconPreference") ?? "automatic") ?? .automatic
        manualAnimationMode = ManualAnimationMode(rawValue: defaults.string(forKey: "manualAnimationMode") ?? "automatic") ?? .automatic
        splitAccounts = defaults.bool(forKey: "splitAccounts")
        showCodexGlobalEstimate = defaults.object(forKey: "showCodexGlobalEstimate") as? Bool ?? true
        showOnboarding = !defaults.bool(forKey: "hasCompletedOnboarding")
        cookieSources = cookieSourceStore.sources()
        let databaseExists = FileManager.default.fileExists(atPath: OmniRouteReader.defaultDatabaseURL.path)
        omniRouteStatus = databaseExists ? .connected : .unavailable("OmniRoute was not found")
    }

    func start() {
        refreshAll()
        refreshCookieSources()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        codexRefreshTimer?.invalidate()
        codexRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCodexUsage() }
        }
        cookieRefreshTimer?.invalidate()
        cookieRefreshTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCookieSources() }
        }
        resetForecastTimer?.invalidate()
        resetForecastTimer = Timer.scheduledTimer(withTimeInterval: 70, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCodexResetForecast() }
        }
        if showCodexGlobalEstimate { refreshCodexResetForecast() }
    }

    func stop() {
        refreshTimer?.invalidate()
        codexRefreshTimer?.invalidate()
        cookieRefreshTimer?.invalidate()
        resetForecastTimer?.invalidate()
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        showOnboarding = false
    }

    func refreshAll() {
        refreshHarnesses()
        codexConfigSummary = CodexConfigSummary.read()
        refreshZCodeUsage()
        refreshOmniRoute()
        if codexSnapshot == nil || Date().timeIntervalSince(codexSnapshot?.fetchedAt ?? .distantPast) > 60 {
            refreshCodexUsage()
        }
        lastRefreshAt = Date()
    }

    private func refreshZCodeUsage() {
        guard !zcodeReadInProgress else { return }
        zcodeReadInProgress = true
        let reader = ZCodeUsageReader()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = reader.read()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let snapshot { self.zcodeUsage = snapshot }
                self.zcodeReadInProgress = false
            }
        }
    }

    func refreshCodexResetForecast() {
        guard showCodexGlobalEstimate, !isRefreshingCodexResetForecast else { return }
        let now = Date()
        guard now >= resetForecastAllowedAfter else { return }
        resetForecastAllowedAfter = now.addingTimeInterval(65)
        isRefreshingCodexResetForecast = true
        codexResetForecastError = nil
        codexResetForecastFetcher.fetch { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isRefreshingCodexResetForecast = false
                switch result {
                case .success(let forecast):
                    self.codexResetForecast = forecast
                    self.codexResetForecastError = nil
                case .failure(let error):
                    self.codexResetForecastError = error.localizedDescription
                    if let forecastError = error as? CodexResetForecastError,
                       case .httpStatus(429, let retryAfter) = forecastError {
                        self.resetForecastAllowedAfter = Date().addingTimeInterval(max(65, retryAfter ?? 65))
                    }
                }
            }
        }
    }

    func refreshOmniRoute() {
        let reader = OmniRouteReader()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let result = try reader.readAccounts()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.omniRouteAccounts = result.accounts
                    self.mergeAccounts()
                    self.omniRouteReadAt = result.readAt
                    self.omniRouteStatus = .connected
                    self.refreshMessage = nil
                    self.lastRefreshAt = Date()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.omniRouteStatus = .unavailable(error.localizedDescription)
                    self.refreshMessage = error.localizedDescription
                }
            }
        }
    }

    func refreshCodexUsage() {
        guard !isRefreshingCodexUsage else { return }
        isRefreshingCodexUsage = true
        codexStatusMessage = "Refreshing official Codex limits…"
        codexBridge.fetch { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isRefreshingCodexUsage = false
                switch result {
                case .success(let snapshot):
                    self.codexSnapshot = snapshot
                    self.codexStatusMessage = snapshot.accountName.map { "Official limits · \($0)" } ?? "Official Codex limits"
                case .failure(let error):
                    self.codexStatusMessage = error.localizedDescription
                }
            }
        }
    }

    func refreshCookieSources() {
        cookieSources = cookieSourceStore.sources()
        for source in cookieSources where !cookieRequestsInProgress.contains(source.id) {
            do {
                let secret = try cookieSourceStore.cookie(for: source.id)
                cookieRequestsInProgress.insert(source.id)
                cookieQuotaFetcher.fetch(source: source, cookie: secret) { [weak self] result in
                    Task { @MainActor in
                        guard let self else { return }
                        self.cookieRequestsInProgress.remove(source.id)
                        switch result {
                        case .success(let window):
                            self.cookieWindows[source.id] = window
                            self.cookieSourceErrors.removeValue(forKey: source.id)
                            self.mergeAccounts()
                        case .failure(let error):
                            self.cookieSourceErrors[source.id] = error.localizedDescription
                        }
                    }
                }
            } catch {
                cookieSourceErrors[source.id] = error.localizedDescription
            }
        }
    }

    func testAndSaveCookieSource(
        _ source: CookieQuotaSource,
        cookie: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        cookieQuotaFetcher.fetch(source: source, cookie: cookie) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let window):
                    do {
                        try self.cookieSourceStore.save(source, cookie: cookie)
                        self.cookieSources = self.cookieSourceStore.sources()
                        self.cookieWindows[source.id] = window
                        self.cookieSourceErrors.removeValue(forKey: source.id)
                        self.mergeAccounts()
                        completion(.success(()))
                    } catch {
                        completion(.failure(error))
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }
    func removeCookieSource(_ source: CookieQuotaSource) {
        cookieSourceStore.remove(source.id)
        cookieSources = cookieSourceStore.sources()
        cookieWindows.removeValue(forKey: source.id)
        cookieSourceErrors.removeValue(forKey: source.id)
        mergeAccounts()
    }

    private func mergeAccounts() {
        var merged = omniRouteAccounts
        for source in cookieSources {
            guard let window = cookieWindows[source.id] else { continue }
            if let index = merged.firstIndex(where: {
                $0.provider == source.provider && $0.connectionID == source.connectionID
            }) {
                merged[index].windows.removeAll { $0.key == window.key }
                merged[index].windows.append(window)
            } else {
                merged.append(ProviderAccount(
                    provider: source.provider,
                    connectionID: source.connectionID,
                    displayName: source.accountName,
                    isActive: true,
                    windows: [window]
                ))
            }
        }
        accounts = merged.sorted {
            let order = $0.provider.localizedCaseInsensitiveCompare($1.provider)
            if order != .orderedSame { return order == .orderedAscending }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func finishCurrentSetup() {
        refreshAll()
        finishOnboarding()
    }

    func animationActivity(for harness: HarnessKind, at date: Date = Date()) -> HarnessActivity {
        switch manualAnimationMode {
        case .automatic:
            return harnesses.first(where: { $0.kind == harness })?.activity ?? .idle
        case .multi:
            return Int(date.timeIntervalSince1970 / 7).isMultiple(of: 2) ? .thinking : .working
        case .thinking:
            return .thinking
        case .working:
            return .working
        }
    }

    private func refreshHarnesses() {
        let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostIdentifier = frontmost?.bundleIdentifier?.lowercased() ?? ""
        let frontmostName = frontmost?.localizedName?.lowercased() ?? ""
        let codexActivity = activityFromCodexMarkers()
        let zcodeActivity = activityFromZCodeMarkers()
        let claudeActivity = activityFromTDZMarkers(for: .claude)
        let tdzCodexActivity = activityFromTDZMarkers(for: .codex)
        let tdzZcodeActivity = activityFromTDZMarkers(for: .zcode)

        harnesses = HarnessKind.allCases.map { kind in
            let matches: (NSRunningApplication) -> Bool = { app in
                let name = (app.localizedName ?? "").lowercased()
                let bundle = (app.bundleIdentifier ?? "").lowercased()
                switch kind {
                case .zcode: return name.contains("zcode") || bundle.contains("zcode")
                case .claude: return name.contains("claude") || bundle.contains("anthropic")
                case .codex: return name.contains("codex") || name.contains("chatgpt") || bundle.contains("openai")
                }
            }
            let isOpen = running.contains(where: matches)
            let isFrontmost = !frontmostIdentifier.isEmpty && matches(frontmost ?? NSRunningApplication.current)
                && (frontmostIdentifier.contains(kind.rawValue) || frontmostName.contains(kind.rawValue)
                    || (kind == .codex && frontmostName.contains("chatgpt")))
            let state: MarkerState
            switch kind {
            case .zcode: state = maxMarker(zcodeActivity, tdzZcodeActivity)
            case .claude: state = claudeActivity
            case .codex: state = maxMarker(codexActivity, tdzCodexActivity)
            }
            return HarnessState(
                kind: kind,
                isOpen: isOpen || state.activity != .idle,
                isFrontmost: isFrontmost,
                activity: state.activity,
                model: state.model,
                lastEvent: state.date
            )
        }
    }

    private struct MarkerState {
        var activity: HarnessActivity
        var date: Date?
        var model: String?
    }

    private func maxMarker(_ a: MarkerState, _ b: MarkerState) -> MarkerState {
        (a.date ?? .distantPast) >= (b.date ?? .distantPast) ? a : b
    }

    private func activityFromZCodeMarkers() -> MarkerState {
        let active = zcodeStateDirectory.appendingPathComponent("active")
        let done = zcodeStateDirectory.appendingPathComponent("done")
        let activeDate = modificationDate(active)
        let doneDate = modificationDate(done)
        guard let activeDate, Date().timeIntervalSince(activeDate) < 20 * 60,
              activeDate >= (doneDate ?? .distantPast) else {
            return MarkerState(activity: .idle, date: doneDate, model: nil)
        }
        return MarkerState(activity: .thinking, date: activeDate, model: readModel(in: zcodeStateDirectory))
    }

    private func activityFromCodexMarkers() -> MarkerState {
        markerState(in: codexStateDirectory)
    }

    private func activityFromTDZMarkers(for harness: HarnessKind) -> MarkerState {
        markerState(in: tdzStateDirectory, prefix: harness.rawValue + "-")
    }

    private func markerState(in directory: URL, prefix: String? = nil) -> MarkerState {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return MarkerState(activity: .idle, date: nil, model: nil)
        }
        let candidates = files.filter { url in
            if let prefix { return url.lastPathComponent.hasPrefix(prefix) && url.pathExtension == "json" }
            return url.pathExtension == "json"
        }
        let latest = candidates.compactMap { url -> (URL, Date, HarnessActivity, String?)? in
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = json["state"] as? String,
                  let timestamp = json["timestamp"] as? Double else { return nil }
            let date = Date(timeIntervalSince1970: timestamp)
            guard Date().timeIntervalSince(date) < 45 * 60 else { return nil }
            let activity: HarnessActivity
            switch state {
            case "thinking": activity = .thinking
            case "tool", "working": activity = .working
            default: activity = .idle
            }
            return (url, date, activity, json["model"] as? String)
        }.max { $0.1 < $1.1 }
        guard let latest else { return MarkerState(activity: .idle, date: nil, model: nil) }
        return MarkerState(activity: latest.2, date: latest.1, model: latest.3 ?? readModel(in: directory))
    }

    private func readModel(in directory: URL) -> String? {
        let url = directory.appendingPathComponent("current-model.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["model"] as? String
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }
}
