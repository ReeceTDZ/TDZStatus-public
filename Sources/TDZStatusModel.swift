import AppKit
import Combine
import Foundation
import Network

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
    @Published private(set) var providerAccountUpdatesInProgress: Set<String> = []
    @Published private(set) var providerAccountUpdateErrors: [String: String] = [:]
    @Published private(set) var hiddenProviderUsageIDs: Set<String>
    @Published private(set) var hiddenProviderIDs: Set<String>
    @Published private(set) var paceDisabledProviderIDs: Set<String>
    @Published var showFiveHourBudgets: Bool {
        didSet { UserDefaults.standard.set(showFiveHourBudgets, forKey: "showFiveHourBudgets") }
    }
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
    @Published private(set) var isRefreshingUsage = false
    @Published private(set) var hasOmniRouteRefreshSession = false
    @Published var notifyOnTaskCompletion: Bool {
        didSet {
            UserDefaults.standard.set(notifyOnTaskCompletion, forKey: "notifyOnTaskCompletion")
            if notifyOnTaskCompletion { notificationCenter.requestAuthorizationIfNeeded() }
        }
    }
    @Published var notifyNearUsageLimits: Bool {
        didSet {
            UserDefaults.standard.set(notifyNearUsageLimits, forKey: "notifyNearUsageLimits")
            if notifyNearUsageLimits { notificationCenter.requestAuthorizationIfNeeded() }
        }
    }
    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var launchAtLoginMessage: String?
    @Published var codeSleepEnabled: Bool {
        didSet {
            UserDefaults.standard.set(codeSleepEnabled, forKey: "codeSleepEnabled")
            updateCodeSleep()
        }
    }
    @Published var pauseOtherAppsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(pauseOtherAppsEnabled, forKey: "pauseOtherAppsEnabled")
            updateCodeSleep()
        }
    }
    @Published var autoConnectPhoneHotspot: Bool {
        didSet {
            UserDefaults.standard.set(autoConnectPhoneHotspot, forKey: "autoConnectPhoneHotspot")
            if autoConnectPhoneHotspot {
                hotspotStatusMessage = hotspotSSID.isEmpty
                    ? "Set up your hotspot name and password."
                    : "Watching the network connection."
                attemptPhoneHotspotConnection()
            } else {
                hotspotStatusMessage = "Automatic hotspot connection is off."
            }
            updateHotspotRetryTimer()
        }
    }
    @Published private(set) var hotspotSSID: String
    @Published private(set) var hotspotStatusMessage = "Automatic hotspot connection is off."
    @Published private(set) var codeSleepHolding = false
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
    private var hasInitialHarnessSnapshot = false
    private var taskTokenBaselines: [HarnessKind: Int64] = [:]
    private var taskTokenReadIDs: [HarnessKind: UUID] = [:]
    private var activeOmniRouteRefreshID: UUID?
    private var providerAccountUpdateIDs: [String: UUID] = [:]
    private var networkIsSatisfied = true
    private var hotspotConnectInProgress = false
    private var lastHotspotAttempt = Date.distantPast
    private var hotspotRetryTimer: Timer?
    private var cachedHotspotPasswords: [String: String] = [:]
    private var pathMonitorStarted = false
    private let codexBridge = CodexUsageBridge()
    private let codexTokenUsageReader = CodexTokenUsageReader()
    private let codexResetForecastFetcher = CodexResetForecastFetcher()
    private let notificationCenter = TDZStatusNotificationCenter.shared
    private let codeSleepController = CodeSleepController()
    private let hotspotCredentialStore = HotspotCredentialStore()
    private let hotspotPathMonitor = NWPathMonitor()
    private let hotspotMonitorQueue = DispatchQueue(label: "com.reecedove.tdzstatus.public.network-monitor")
    private let cookieSourceStore = CookieQuotaSourceStore()
    private let cookieQuotaFetcher = CookieQuotaFetcher()
    private let omniRouteRefreshSessionStore = OmniRouteDashboardSessionStore()
    private let omniRouteRefreshClient = OmniRouteRefreshClient()
    private var omniRouteAccounts: [ProviderAccount] = []
    private var cookieWindows: [String: QuotaWindow] = [:]
    private let zcodeStateDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".zcode-status", isDirectory: true)
    private let codexStateDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex-status/sessions", isDirectory: true)
    private let tdzStateDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TDZStatus Public/sessions", isDirectory: true)

    var allProviderPools: [ProviderPool] {
        Dictionary(grouping: accounts.filter { !isHiddenDashboardProvider($0.provider) }, by: \.provider)
            .map { ProviderPool(provider: $0.key, accounts: $0.value) }
            .sorted { $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending }
    }

    var providerPools: [ProviderPool] {
        allProviderPools.filter { !hiddenProviderIDs.contains($0.provider.lowercased()) }
    }

    var accountsMissingQuota: [ProviderAccount] {
        accounts.filter {
            !isHiddenDashboardProvider($0.provider) && $0.windows.isEmpty
        }
    }

    var visibleCookieSources: [CookieQuotaSource] {
        cookieSources.filter { !isHiddenDashboardProvider($0.provider) }
    }

    var hasMultiAccountPools: Bool {
        providerPools.contains { $0.accountCount > 1 }
    }

    var codexProvidersMissingFromOmniRoute: [String] {
        let configured = Set(codexConfigSummary.activeProviders + codexConfigSummary.declaredProviders)
            .filter {
                $0.caseInsensitiveCompare("omniroute") != .orderedSame
                    && !isHiddenDashboardProvider($0)
            }
        let omniProviders = accounts.map { $0.provider.lowercased() }
        return configured.filter { provider in
            let normalized = provider.lowercased()
            return !omniProviders.contains { configuredProvider in
                configuredProvider == normalized || configuredProvider.hasPrefix(normalized + "-")
            }
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var codexConfigProviderSummary: String {
        let names = Array(Set(codexConfigSummary.activeProviders + codexConfigSummary.declaredProviders)
            .filter { !isHiddenDashboardProvider($0) })
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
        Self.migrateLegacyPreferences(defaults)
        let oldHiddenUsageIDs = Set(defaults.stringArray(forKey: "hiddenProviderUsageIDs") ?? [])
        hiddenProviderUsageIDs = oldHiddenUsageIDs
        var hiddenProviders = Set(defaults.stringArray(forKey: "hiddenProviderIDs") ?? [])
        if !defaults.bool(forKey: "providerVisibilityMigrated") {
            hiddenProviders.formUnion(oldHiddenUsageIDs.compactMap { $0.split(separator: "|", maxSplits: 1).first.map(String.init) })
            defaults.set(hiddenProviders.sorted(), forKey: "hiddenProviderIDs")
            defaults.set(true, forKey: "providerVisibilityMigrated")
        }
        hiddenProviderIDs = hiddenProviders
        paceDisabledProviderIDs = Set(defaults.stringArray(forKey: "paceDisabledProviderIDs") ?? [])
        showFiveHourBudgets = defaults.object(forKey: "showFiveHourBudgets") as? Bool ?? true
        iconPreference = IconPreference(rawValue: defaults.string(forKey: "iconPreference") ?? "automatic") ?? .automatic
        manualAnimationMode = ManualAnimationMode(rawValue: defaults.string(forKey: "manualAnimationMode") ?? "automatic") ?? .automatic
        splitAccounts = defaults.bool(forKey: "splitAccounts")
        showCodexGlobalEstimate = defaults.object(forKey: "showCodexGlobalEstimate") as? Bool ?? true
        let oldNotifications = defaults.object(forKey: "notifyOnFinish") as? Bool
        notifyOnTaskCompletion = defaults.object(forKey: "notifyOnTaskCompletion") as? Bool ?? oldNotifications ?? true
        notifyNearUsageLimits = defaults.object(forKey: "notifyNearUsageLimits") as? Bool ?? oldNotifications ?? true
        launchAtLoginEnabled = TDZLaunchAtLogin.isEnabled
        launchAtLoginMessage = nil
        codeSleepEnabled = defaults.object(forKey: "codeSleepEnabled") as? Bool
            ?? defaults.bool(forKey: "codeSleepArmed")
        pauseOtherAppsEnabled = defaults.object(forKey: "pauseOtherAppsEnabled") as? Bool
            ?? defaults.bool(forKey: "pauseOthers")
        autoConnectPhoneHotspot = defaults.object(forKey: "autoConnectPhoneHotspot") as? Bool
            ?? defaults.bool(forKey: "hotspotAutoConnect")
        hotspotSSID = defaults.string(forKey: "hotspotSSID") ?? ""
        showOnboarding = !defaults.bool(forKey: "hasCompletedOnboarding")
        cookieSources = cookieSourceStore.sources()
        hasOmniRouteRefreshSession = (try? omniRouteRefreshSessionStore.cookie()) != nil
        let databaseExists = FileManager.default.fileExists(atPath: OmniRouteReader.defaultDatabaseURL.path)
        omniRouteStatus = databaseExists ? .connected : .unavailable("OmniRoute was not found")
    }

    func start() {
        refreshAll()
        refreshCookieSources()
        startHotspotNetworkMonitor()
        updateHotspotRetryTimer()
        if notifyOnTaskCompletion || notifyNearUsageLimits {
            notificationCenter.requestAuthorizationIfNeeded()
        }
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
        hotspotRetryTimer?.invalidate()
        hotspotRetryTimer = nil
        if pathMonitorStarted {
            hotspotPathMonitor.cancel()
            pathMonitorStarted = false
        }
        codeSleepController.release()
        codeSleepHolding = false
    }

    private static func migrateLegacyPreferences(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: "settingsMigratedFromZCodeStatus") else { return }
        let old = UserDefaults(suiteName: "com.reecedove.zcodestatus")
        let mappings = [
            "notifyOnFinish": "notifyOnTaskCompletion",
            "codeSleepArmed": "codeSleepEnabled",
            "pauseOthers": "pauseOtherAppsEnabled",
            "hotspotAutoConnect": "autoConnectPhoneHotspot",
            "hotspotSSID": "hotspotSSID",
        ]
        for (oldKey, newKey) in mappings where defaults.object(forKey: newKey) == nil {
            if let value = old?.object(forKey: oldKey) { defaults.set(value, forKey: newKey) }
        }
        if defaults.object(forKey: "notifyNearUsageLimits") == nil,
           let oldValue = old?.object(forKey: "notifyOnFinish") {
            defaults.set(oldValue, forKey: "notifyNearUsageLimits")
        }
        defaults.set(true, forKey: "settingsMigratedFromZCodeStatus")
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        showOnboarding = false
    }

    func setProviderUsageVisible(provider: String, key: String, isVisible: Bool) {
        let usageID = providerUsageVisibilityID(provider, key)
        if isVisible {
            hiddenProviderUsageIDs.remove(usageID)
        } else {
            hiddenProviderUsageIDs.insert(usageID)
        }
        UserDefaults.standard.set(hiddenProviderUsageIDs.sorted(), forKey: "hiddenProviderUsageIDs")
    }

    func setProviderVisible(_ provider: String, isVisible: Bool) {
        if isVisible { hiddenProviderIDs.remove(provider.lowercased()) }
        else { hiddenProviderIDs.insert(provider.lowercased()) }
        UserDefaults.standard.set(hiddenProviderIDs.sorted(), forKey: "hiddenProviderIDs")
    }

    func setPaceVisible(_ provider: String, isVisible: Bool) {
        if isVisible { paceDisabledProviderIDs.remove(provider.lowercased()) }
        else { paceDisabledProviderIDs.insert(provider.lowercased()) }
        UserDefaults.standard.set(paceDisabledProviderIDs.sorted(), forKey: "paceDisabledProviderIDs")
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try TDZLaunchAtLogin.setEnabled(enabled)
            launchAtLoginEnabled = TDZLaunchAtLogin.isEnabled
            if TDZLaunchAtLogin.needsApproval {
                launchAtLoginMessage = "Approve TDZStatus under System Settings → General → Login Items."
            } else {
                launchAtLoginMessage = nil
            }
        } catch {
            launchAtLoginEnabled = TDZLaunchAtLogin.isEnabled
            launchAtLoginMessage = error.localizedDescription
        }
    }

    func setHotspotCredentials(ssid: String, password: String) throws {
        let normalizedSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        try hotspotCredentialStore.save(password: password, for: normalizedSSID)
        cachedHotspotPasswords[normalizedSSID] = password
        hotspotSSID = normalizedSSID
        UserDefaults.standard.set(normalizedSSID, forKey: "hotspotSSID")
        hotspotStatusMessage = autoConnectPhoneHotspot
            ? "Saved. TDZStatus will try to connect when macOS reports no network path."
            : "Hotspot details saved. Turn on automatic connection when you want it."
    }

    func sendTestNotification() {
        notificationCenter.requestAuthorizationIfNeeded { [weak self] in
            Task { @MainActor [weak self] in
                self?.notificationCenter.send(
                    title: "TDZStatus notifications are ready",
                    body: "Task completion and usage limit alerts will appear here.",
                    identifier: "tdzstatus-test-\(Int(Date().timeIntervalSince1970))"
                )
            }
        }
    }

    private func updateCodeSleep() {
        codeSleepController.update(
            shouldHold: codeSleepEnabled && busyHarnessCount > 0,
            pauseOtherApps: pauseOtherAppsEnabled
        )
        codeSleepHolding = codeSleepController.isHolding
    }

    private func startHotspotNetworkMonitor() {
        guard !pathMonitorStarted else { return }
        pathMonitorStarted = true
        hotspotPathMonitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.networkIsSatisfied = isSatisfied
                if isSatisfied {
                    self.hotspotStatusMessage = self.autoConnectPhoneHotspot
                        ? "Internet connection is available."
                        : "Automatic hotspot connection is off."
                } else {
                    self.attemptPhoneHotspotConnection()
                }
            }
        }
        hotspotPathMonitor.start(queue: hotspotMonitorQueue)
    }

    private func updateHotspotRetryTimer() {
        if autoConnectPhoneHotspot {
            guard hotspotRetryTimer == nil else { return }
            let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.attemptPhoneHotspotConnection() }
            }
            RunLoop.main.add(timer, forMode: .common)
            hotspotRetryTimer = timer
        } else {
            hotspotRetryTimer?.invalidate()
            hotspotRetryTimer = nil
        }
    }

    private func attemptPhoneHotspotConnection() {
        guard autoConnectPhoneHotspot else { return }
        guard !hotspotSSID.isEmpty else {
            hotspotStatusMessage = "Set up your hotspot name and password."
            return
        }
        guard !networkIsSatisfied else { return }
        guard !hotspotConnectInProgress,
              Date().timeIntervalSince(lastHotspotAttempt) >= 60 else { return }

        let ssid = hotspotSSID
        let password: String
        do {
            if let cached = cachedHotspotPasswords[ssid] {
                password = cached
            } else {
                password = try hotspotCredentialStore.password(for: ssid)
                cachedHotspotPasswords[ssid] = password
            }
        } catch {
            hotspotStatusMessage = error.localizedDescription
            return
        }

        hotspotConnectInProgress = true
        lastHotspotAttempt = Date()
        hotspotStatusMessage = "Trying to connect to \(ssid)…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result: Result<Void, Error>
            do {
                try PhoneHotspotConnector.connect(ssid: ssid, password: password)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hotspotConnectInProgress = false
                switch result {
                case .success:
                    self.hotspotStatusMessage = "Connecting to \(ssid)…"
                case .failure(let error):
                    self.hotspotStatusMessage = error.localizedDescription
                }
            }
        }
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

    /// Refreshes linked website quotas immediately, then asks OmniRoute's local
    /// dashboard to refresh its upstream provider data before reading the local snapshot.
    func refreshUsageNow() {
        refreshHarnesses()
        codexConfigSummary = CodexConfigSummary.read()
        refreshZCodeUsage()
        refreshCodexUsage()
        refreshCookieSources()
        requestOmniRouteQuotaRefresh()
    }

    func refreshProviderUsage(_ provider: String, connectionID: String? = nil) {
        refreshHarnesses()
        if provider.caseInsensitiveCompare("codex") == .orderedSame {
            refreshCodexUsage()
        }
        refreshCookieSources(provider: provider, connectionID: connectionID)
        requestOmniRouteQuotaRefresh(provider: provider, connectionID: connectionID)
    }

    func setProviderAccountActive(_ account: ProviderAccount, isActive: Bool) {
        guard account.isActive != isActive,
              !providerAccountUpdatesInProgress.contains(account.id) else { return }
        providerAccountUpdateErrors.removeValue(forKey: account.id)

        let cookie: String
        do {
            cookie = try omniRouteRefreshSessionStore.cookie()
            hasOmniRouteRefreshSession = true
        } catch {
            // The dashboard session can be removed or expire while the app is
            // open. Don't leave an apparently live switch enabled on a stale
            // in-memory Keychain check.
            hasOmniRouteRefreshSession = false
            providerAccountUpdateErrors[account.id] = "OmniRoute dashboard session is unavailable. Reconnect it in Settings."
            return
        }

        let operationID = UUID()
        providerAccountUpdateIDs[account.id] = operationID
        providerAccountUpdatesInProgress.insert(account.id)
        omniRouteRefreshClient.setAccountActive(
            connectionID: account.connectionID,
            isActive: isActive,
            cookie: cookie
        ) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.providerAccountUpdateIDs[account.id] == operationID else { return }
                switch result {
                case .success:
                    self.confirmProviderAccountStatus(
                        account,
                        isActive: isActive,
                        operationID: operationID,
                        attemptsRemaining: 10
                    )
                case .failure(let error):
                    if (error as? OmniRouteRefreshError)?.isAuthenticationFailure == true {
                        self.hasOmniRouteRefreshSession = false
                    }
                    self.finishProviderAccountUpdate(account.id, operationID: operationID, error: error.localizedDescription)
                }
            }
        }
    }

    func testAndSaveOmniRouteRefreshSession(cookie: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let normalized: String
        do {
            normalized = try OmniRouteDashboardSessionStore.normalizedCookieHeader(cookie)
        } catch {
            completion(.failure(error))
            return
        }
        omniRouteRefreshClient.validate(cookie: normalized) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    do {
                        try self.omniRouteRefreshSessionStore.save(cookie: normalized)
                        self.hasOmniRouteRefreshSession = true
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

    func removeOmniRouteRefreshSession() {
        omniRouteRefreshSessionStore.remove()
        hasOmniRouteRefreshSession = false
    }

    private func refreshZCodeUsage() {
        guard !zcodeReadInProgress else { return }
        zcodeReadInProgress = true
        let reader = ZCodeUsageReader()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = reader.read()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let snapshot {
                    self.zcodeUsage = snapshot
                    self.checkNearLimitNotifications()
                }
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
                    self.applyOmniRouteRead(result)
                    if !self.isRefreshingUsage { self.refreshMessage = nil }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.omniRouteStatus = .unavailable(error.localizedDescription)
                    if !self.isRefreshingUsage { self.refreshMessage = error.localizedDescription }
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
                    self.checkNearLimitNotifications()
                case .failure(let error):
                    self.codexStatusMessage = error.localizedDescription
                }
            }
        }
    }

    func refreshCookieSources(provider: String? = nil, connectionID: String? = nil) {
        cookieSources = cookieSourceStore.sources()
        for source in cookieSources where !isHiddenDashboardProvider(source.provider)
            && !cookieRequestsInProgress.contains(source.id)
            && (provider == nil || source.provider.caseInsensitiveCompare(provider!) == .orderedSame)
            && (connectionID == nil || source.connectionID == connectionID!) {
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

    private func requestOmniRouteQuotaRefresh(provider: String? = nil, connectionID: String? = nil) {
        guard !isRefreshingUsage else { return }
        guard let cookie = try? omniRouteRefreshSessionStore.cookie() else {
            refreshMessage = "Showing OmniRoute's latest saved data. Connect the dashboard refresh session in Settings to fetch new provider usage."
            refreshOmniRoute()
            return
        }

        isRefreshingUsage = true
        let refreshID = UUID()
        activeOmniRouteRefreshID = refreshID
        refreshMessage = "Checking the current OmniRoute snapshot…"

        // Establish the baseline before triggering OmniRoute. The dashboard
        // endpoint may return before its provider fetches finish, so the UI
        // waits for a newer SQLite snapshot instead of sleeping for a fixed delay.
        let reader = OmniRouteReader()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let baseline = try? reader.readAccounts().accounts
            Task { @MainActor [weak self] in
                guard let self, self.activeOmniRouteRefreshID == refreshID else { return }
                let baselineAccounts = baseline ?? self.omniRouteAccounts
                self.refreshMessage = "Refreshing provider usage in OmniRoute…"
                self.omniRouteRefreshClient.refresh(cookie: cookie) { [weak self] result in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeOmniRouteRefreshID == refreshID else { return }
                        switch result {
                        case .success:
                            self.refreshMessage = "Waiting for OmniRoute to save fresh quota snapshots…"
                            self.pollOmniRouteSnapshots(
                                refreshID: refreshID,
                                baseline: baselineAccounts,
                                provider: provider,
                                connectionID: connectionID,
                                startedAt: Date(),
                                lastChangeAt: nil,
                                previous: baselineAccounts
                            )
                        case .failure(let error):
                            self.activeOmniRouteRefreshID = nil
                            self.isRefreshingUsage = false
                            self.refreshMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }

    private func pollOmniRouteSnapshots(
        refreshID: UUID,
        baseline: [ProviderAccount],
        provider: String?,
        connectionID: String?,
        startedAt: Date,
        lastChangeAt: Date?,
        previous: [ProviderAccount]
    ) {
        let reader = OmniRouteReader()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let read = Result { try reader.readAccounts() }
            Task { @MainActor [weak self] in
                guard let self, self.activeOmniRouteRefreshID == refreshID else { return }
                switch read {
                case .failure(let error):
                    self.activeOmniRouteRefreshID = nil
                    self.isRefreshingUsage = false
                    self.refreshMessage = error.localizedDescription
                case .success(let result):
                    let now = Date()
                    let hasNewData = Self.hasNewQuotaSnapshot(
                        comparedWith: baseline,
                        accounts: result.accounts,
                        provider: provider,
                        connectionID: connectionID
                    )
                    let changedSinceLastPoll = Self.hasNewQuotaSnapshot(
                        comparedWith: previous,
                        accounts: result.accounts,
                        provider: provider,
                        connectionID: connectionID
                    )
                    let changedAt = changedSinceLastPoll ? now : lastChangeAt
                    self.applyOmniRouteRead(result)

                    if let changedAt, now.timeIntervalSince(changedAt) >= 2.5 {
                        self.finishOmniRouteQuotaRefresh(refreshID, freshDataLoaded: hasNewData)
                    } else if now.timeIntervalSince(startedAt) >= 45 {
                        self.finishOmniRouteQuotaRefresh(refreshID, freshDataLoaded: hasNewData)
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                            self?.pollOmniRouteSnapshots(
                                refreshID: refreshID,
                                baseline: baseline,
                                provider: provider,
                                connectionID: connectionID,
                                startedAt: startedAt,
                                lastChangeAt: changedAt,
                                previous: result.accounts
                            )
                        }
                    }
                }
            }
        }
    }

    private func applyOmniRouteRead(_ result: OmniRouteReadResult) {
        omniRouteAccounts = result.accounts
        mergeAccounts()
        omniRouteReadAt = result.readAt
        omniRouteStatus = .connected
        lastRefreshAt = Date()
    }

    private func confirmProviderAccountStatus(
        _ account: ProviderAccount,
        isActive: Bool,
        operationID: UUID,
        attemptsRemaining: Int
    ) {
        let reader = OmniRouteReader()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let read = Result { try reader.readAccounts() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.providerAccountUpdateIDs[account.id] == operationID else { return }
                switch read {
                case .failure(let error):
                    self.finishProviderAccountUpdate(account.id, operationID: operationID, error: error.localizedDescription)
                case .success(let result):
                    self.applyOmniRouteRead(result)
                    let updatedAccount = result.accounts.first {
                        $0.connectionID == account.connectionID
                            && $0.provider.caseInsensitiveCompare(account.provider) == .orderedSame
                    }
                    if updatedAccount?.isActive == isActive {
                        self.finishProviderAccountUpdate(account.id, operationID: operationID, error: nil)
                    } else if attemptsRemaining > 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                            self?.confirmProviderAccountStatus(
                                account,
                                isActive: isActive,
                                operationID: operationID,
                                attemptsRemaining: attemptsRemaining - 1
                            )
                        }
                    } else {
                        self.finishProviderAccountUpdate(
                            account.id,
                            operationID: operationID,
                            error: "OmniRoute accepted the change, but its local account status has not updated yet."
                        )
                    }
                }
            }
        }
    }

    private func finishProviderAccountUpdate(_ accountID: String, operationID: UUID, error: String?) {
        guard providerAccountUpdateIDs[accountID] == operationID else { return }
        providerAccountUpdateIDs.removeValue(forKey: accountID)
        providerAccountUpdatesInProgress.remove(accountID)
        if let error {
            providerAccountUpdateErrors[accountID] = error
        } else {
            providerAccountUpdateErrors.removeValue(forKey: accountID)
        }
    }

    private func finishOmniRouteQuotaRefresh(_ refreshID: UUID, freshDataLoaded: Bool) {
        guard activeOmniRouteRefreshID == refreshID else { return }
        activeOmniRouteRefreshID = nil
        isRefreshingUsage = false
        refreshMessage = freshDataLoaded
            ? "Fresh OmniRoute usage data loaded."
            : "OmniRoute accepted the refresh, but no newer quota snapshot appeared within 45 seconds. Showing its latest saved data."
    }

    private static func hasNewQuotaSnapshot(
        comparedWith baseline: [ProviderAccount],
        accounts: [ProviderAccount],
        provider: String?,
        connectionID: String?
    ) -> Bool {
        func selected(_ account: ProviderAccount) -> Bool {
            (provider == nil || account.provider.caseInsensitiveCompare(provider!) == .orderedSame)
                && (connectionID == nil || account.connectionID == connectionID!)
        }
        let oldWindows = Dictionary(
            baseline.filter(selected).flatMap(\.windows).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return accounts.filter(selected).flatMap(\.windows).contains { window in
            guard let old = oldWindows[window.id] else { return true }
            return old != window
        }
    }

    func testAndSaveCookieSource(
        _ source: CookieQuotaSource,
        cookie: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard !isHiddenDashboardProvider(source.provider) else {
            completion(.failure(CookieQuotaError.monitoringRemoved))
            return
        }
        let cookieHeader: String
        do {
            cookieHeader = try CookieQuotaFetcher.normalizedCookieHeader(cookie, provider: source.provider)
        } catch {
            completion(.failure(error))
            return
        }
        cookieQuotaFetcher.fetch(source: source, cookie: cookieHeader) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let window):
                    do {
                        try self.cookieSourceStore.save(source, cookie: cookieHeader)
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
            guard !isHiddenDashboardProvider(source.provider) else { continue }
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
        checkNearLimitNotifications()
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

        let nextHarnesses = HarnessKind.allCases.map { kind in
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

        let previousByKind = Dictionary(uniqueKeysWithValues: harnesses.map { ($0.kind, $0) })
        for state in nextHarnesses {
            guard let previous = previousByKind[state.kind] else { continue }
            if !previous.isBusy && state.isBusy {
                captureTaskTokenBaseline(for: state.kind)
            } else if previous.isBusy && !state.isBusy && hasInitialHarnessSnapshot {
                notifyTaskFinished(kind: state.kind, model: previous.model ?? state.model)
            }
        }
        if !hasInitialHarnessSnapshot {
            for state in nextHarnesses where state.isBusy {
                captureTaskTokenBaseline(for: state.kind)
            }
            hasInitialHarnessSnapshot = true
        }
        harnesses = nextHarnesses
        updateCodeSleep()
    }

    private func captureTaskTokenBaseline(for kind: HarnessKind) {
        guard kind == .codex else { return }
        let requestID = UUID()
        taskTokenReadIDs[kind] = requestID
        taskTokenBaselines.removeValue(forKey: kind)
        let reader = codexTokenUsageReader
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let baseline = reader.read()?.cumulativeTokens
            Task { @MainActor [weak self] in
                guard let self, self.taskTokenReadIDs[kind] == requestID else { return }
                if let baseline { self.taskTokenBaselines[kind] = baseline }
            }
        }
    }

    private func notifyTaskFinished(kind: HarnessKind, model: String?) {
        let baseline = taskTokenBaselines.removeValue(forKey: kind)
        taskTokenReadIDs[kind] = nil
        guard notifyOnTaskCompletion else { return }

        if kind == .codex {
            let reader = codexTokenUsageReader
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let usage = reader.read()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let tokenCount: Int64?
                    if let baseline, let usage, usage.cumulativeTokens >= baseline,
                       usage.cumulativeTokens > baseline {
                        tokenCount = usage.cumulativeTokens - baseline
                    } else if let lastTurn = usage?.latestTurnTokens, lastTurn > 0 {
                        tokenCount = lastTurn
                    } else {
                        tokenCount = nil
                    }
                    self.deliverTaskFinished(kind: kind, model: model, tokenCount: tokenCount)
                }
            }
        } else {
            deliverTaskFinished(kind: kind, model: model, tokenCount: nil)
        }
    }

    private func deliverTaskFinished(kind: HarnessKind, model: String?, tokenCount: Int64?) {
        let tokenDescription = tokenCount.map { "~\(formattedTokenCount($0)) tokens" }
            ?? "token total unavailable"
        let usageDescription = completionUsageSummary(for: kind)
        let modelDescription = model.flatMap { $0.isEmpty ? nil : $0 }
        let details = [modelDescription, tokenDescription, usageDescription].compactMap { $0 }
            .joined(separator: " · ")
        notificationCenter.send(
            title: "\(kind.title) task finished",
            body: details,
            identifier: "task-finished-\(kind.rawValue)-\(Int(Date().timeIntervalSince1970))"
        )
    }

    private func completionUsageSummary(for kind: HarnessKind) -> String {
        let values: [(String, Double)]
        switch kind {
        case .codex:
            if let snapshot = codexSnapshot,
               Date().timeIntervalSince(snapshot.fetchedAt) < 30 * 60 {
                values = snapshot.windows.map { ($0.title, $0.usedPercentage) }
            } else {
                values = providerUsageValues(matching: { $0.isCodex })
            }
        case .zcode:
            values = (zcodeUsage?.balances ?? []).compactMap { balance in
                balance.remainingPercentage.map { (balance.model, 100 - $0) }
            }
        case .claude:
            let anthropic = providerUsageValues(matching: {
                $0.provider.localizedCaseInsensitiveContains("anthropic")
                    || $0.provider.localizedCaseInsensitiveContains("claude")
                    || isTokenHarborProvider($0.provider)
            })
            values = anthropic.isEmpty ? providerUsageValues(matching: { _ in true }) : anthropic
        }
        let summary = values
            .sorted { $0.1 > $1.1 }
            .prefix(2)
            .map { "\($0.0) \(Int($0.1.rounded()))% used" }
            .joined(separator: ", ")
        return summary.isEmpty ? "usage limits unavailable" : summary
    }

    private func providerUsageValues(matching poolFilter: (ProviderPool) -> Bool) -> [(String, Double)] {
        allProviderPools.filter(poolFilter).flatMap { pool in
            pool.accounts.filter(\.isActive).flatMap { account in
                pool.windows(for: account).compactMap { window in
                    window.usedPercentage.map { (displayProviderName(pool.provider), $0) }
                }
            }
        }
    }

    private func checkNearLimitNotifications() {
        guard notifyNearUsageLimits else { return }
        let now = Date()

        for pool in allProviderPools {
            for account in pool.accounts where account.isActive {
                for window in pool.windows(for: account) {
                    guard let used = window.usedPercentage,
                          let reset = window.resetsAt,
                          let captured = window.capturedAt,
                          now.timeIntervalSince(captured) < 30 * 60 else { continue }
                    notifyNearLimit(
                        scope: window.id,
                        title: "\(displayProviderName(pool.provider)) usage near limit",
                        detail: "\(account.displayName) · \(displayQuotaWindowName(window.key, provider: pool.provider))",
                        used: used,
                        reset: reset
                    )
                }
            }
        }

        if let snapshot = codexSnapshot, now.timeIntervalSince(snapshot.fetchedAt) < 30 * 60 {
            for window in snapshot.windows {
                guard let reset = window.resetsAt else { continue }
                notifyNearLimit(
                    scope: "official-codex-\(window.id)",
                    title: "Codex usage near limit",
                    detail: window.title,
                    used: window.usedPercentage,
                    reset: reset
                )
            }
        }

        if let snapshot = zcodeUsage,
           let captured = snapshot.capturedAt,
           now.timeIntervalSince(captured) < 30 * 60 {
            for balance in snapshot.balances {
                guard let used = balance.remainingPercentage.map({ 100 - $0 }),
                      let reset = balance.resetsAt else { continue }
                notifyNearLimit(
                    scope: "zcode-\(balance.model)",
                    title: "ZCode usage near limit",
                    detail: balance.model,
                    used: used,
                    reset: reset
                )
            }
        }
    }

    private func notifyNearLimit(scope: String, title: String, detail: String, used: Double, reset: Date) {
        guard used >= 90, reset > Date() else { return }
        let resetKey = Int(reset.timeIntervalSince1970)
        let encodedScope = Data(scope.utf8).base64EncodedString()
        let defaultsKey = "nearLimitNotified.\(encodedScope).\(resetKey)"
        guard !UserDefaults.standard.bool(forKey: defaultsKey) else { return }
        UserDefaults.standard.set(true, forKey: defaultsKey)
        notificationCenter.send(
            title: title,
            body: "\(detail) · \(Int(used.rounded()))% used · resets \(reset.formatted(date: .abbreviated, time: .shortened))",
            identifier: "near-limit-\(encodedScope)-\(resetKey)"
        )
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
