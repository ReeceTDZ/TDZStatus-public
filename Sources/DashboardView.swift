import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: TDZStatusModel
    @State private var expandedProvider: String?
    @State private var showCookieEditor = false
    @State private var selectedCookieAccountID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            sectionPicker
            Divider().opacity(0.45)
            ScrollView(showsIndicators: false) {
                if model.showOnboarding {
                    firstLaunch
                } else {
                    switch model.section {
                    case .overview: overview
                    case .usage: usage
                    case .settings: settings
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 640, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(nil)
        .sheet(isPresented: $showCookieEditor, onDismiss: { selectedCookieAccountID = nil }) {
            CookieSourceEditor(model: model, initialAccountID: selectedCookieAccountID)
                .frame(width: 520, height: 590)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.92), Color.accentColor.opacity(0.62)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 38, height: 38)
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("TDZStatus")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text(model.activitySummary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(model.omniRouteStatus == .connected ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(model.omniRouteStatus == .connected ? "OmniRoute" : "Setup needed")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Button { model.refreshAll() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 29, height: 29)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Refresh usage and harness status")
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private var sectionPicker: some View {
        HStack(spacing: 5) {
            ForEach(DashboardSection.allCases) { section in
                Button { model.section = section } label: {
                    HStack(spacing: 6) {
                        Image(systemName: section.symbol)
                        Text(section.title)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.section == section ? Color.primary : Color.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(model.section == section ? Color.primary.opacity(0.08) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 11)
    }

    private var firstLaunch: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Bring your harnesses together")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                Text("TDZStatus reads local usage snapshots from OmniRoute and tracks activity from ZCode, Claude, and Codex.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                ForEach(HarnessKind.allCases) { harness in
                    HStack(spacing: 7) {
                        Image(systemName: harness.symbol)
                            .foregroundStyle(Color(nsColor: harness.accent))
                        Text(harness.title)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                Label("OmniRoute local read-only connection", systemImage: "externaldrive.connected.to.line.below")
                    .font(.system(size: 13, weight: .semibold))
                Text(OmniRouteReader.defaultDatabaseURL.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Only account labels and quota snapshots are queried. API keys, cookies, access tokens, and provider credentials are never read.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.primary.opacity(0.07)))

            if case .unavailable(let reason) = model.omniRouteStatus {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
            } else {
                Label("OmniRoute database detected", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
            }

            HStack(spacing: 10) {
                Button {
                    model.refreshOmniRoute()
                    model.finishOnboarding()
                } label: {
                    Label("Connect OmniRoute", systemImage: "link")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.omniRouteStatus != .connected)

                Button("Continue without OmniRoute") { model.finishOnboarding() }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            heroCard
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading("Harness activity", subtitle: "Detected from open apps and local lifecycle events")
                HStack(spacing: 10) {
                    ForEach(model.harnesses) { harness in
                        HarnessCard(state: harness)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    sectionHeading("Usage pools", subtitle: "Latest quota snapshots from OmniRoute")
                    Spacer()
                    Button("See all") { model.section = .usage }
                        .font(.system(size: 11, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
                if model.providerPools.isEmpty {
                    EmptyStateCard(
                        symbol: "chart.bar.xaxis",
                        title: "No provider accounts found",
                        detail: model.omniRouteStatus == .connected
                            ? "OmniRoute has no active provider connections yet."
                            : "Connect OmniRoute to show provider usage here."
                    )
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(model.providerPools.prefix(4)) { pool in
                            ProviderPoolCard(pool: pool, expandedProvider: $expandedProvider, splitAccounts: model.splitAccounts, configureCookie: configureCookie)
                        }
                    }
                }
            }
            ZCodeUsageCard(model: model, compact: true)
            CodexOfficialCard(model: model, compact: true)
        }
        .padding(18)
    }

    private var heroCard: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.14)).frame(width: 64, height: 64)
                Image(systemName: model.busyHarnessCount > 0 ? "waveform.path" : "circle.hexagongrid.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.busyHarnessCount > 0 ? "Work in progress" : "Your AI workspace")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text(model.activitySummary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if let updated = model.lastRefreshAt {
                    Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(model.providerPools.count)")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                Text("providers")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(LinearGradient(colors: [Color.accentColor.opacity(0.12), Color.accentColor.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.accentColor.opacity(0.12)))
    }

    private var usage: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Provider usage")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Providers with several accounts show an average remaining percentage. A provider with one account is shown directly, and resets include the exact timestamp.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.hasMultiAccountPools {
                Picker("Display", selection: $model.splitAccounts) {
                    Text("Combined pools").tag(false)
                    Text("By account").tag(true)
                }
                .pickerStyle(.segmented)
            }

            if model.providerPools.isEmpty {
                EmptyStateCard(symbol: "tray", title: "No provider connections", detail: "Connect OmniRoute to find configured provider accounts.")
            } else {
                VStack(spacing: 10) {
                    ForEach(model.providerPools) { pool in
                        ProviderPoolCard(pool: pool, expandedProvider: $expandedProvider, splitAccounts: model.splitAccounts, fullWidth: true, configureCookie: configureCookie)
                    }
                }
            }

            ZCodeUsageCard(model: model, compact: false)
            CodexOfficialCard(model: model, compact: false)
            if model.showCodexGlobalEstimate {
                GlobalResetEstimateCard(model: model)
            }
        }
        .padding(18)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preferences")
                .font(.system(size: 20, weight: .bold, design: .rounded))

            SettingsCard(title: "Menu bar animation", symbol: "sparkles") {
                Picker("Animation", selection: $model.iconPreference) {
                    ForEach(IconPreference.allCases) { preference in
                        Text(preference.title).tag(preference)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            SettingsCard(title: "Animation mode", symbol: "play.rectangle") {
                Picker("Mode", selection: $model.manualAnimationMode) {
                    ForEach(ManualAnimationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            SettingsCard(title: "Usage display", symbol: "chart.bar.xaxis") {
                if model.hasMultiAccountPools {
                    Toggle("Show accounts separately", isOn: $model.splitAccounts)
                        .toggleStyle(.switch)
                        .font(.system(size: 12))
                } else {
                    Text("Single-account providers are shown directly. Account splitting appears when a provider has multiple connected accounts.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsCard(title: "Connections", symbol: "link") {
                VStack(alignment: .leading, spacing: 10) {
                    connectionLine(
                        title: "OmniRoute",
                        detail: model.omniRouteStatus.message,
                        good: model.omniRouteStatus == .connected
                    )
                    Text(OmniRouteReader.defaultDatabaseURL.path)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                    HStack {
                        Button("Reconnect") { model.refreshOmniRoute() }
                            .buttonStyle(.bordered)
                        Button("Refresh Codex limits") { model.refreshCodexUsage() }
                            .buttonStyle(.bordered)
                    }
                }
            }

            SettingsCard(title: "Codex configuration", symbol: "terminal") {
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.codexConfigProviderSummary)
                        .font(.system(size: 10, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if model.codexProvidersMissingFromOmniRoute.isEmpty {
                        Label("No additional Codex providers are missing from OmniRoute.", systemImage: "checkmark.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.codexProvidersMissingFromOmniRoute, id: \.self) { provider in
                            Label("\(displayProviderName(provider)) is configured in Codex but not listed by OmniRoute.", systemImage: "exclamationmark.circle")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(model.codexConfigSummary.configPath)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }

            SettingsCard(title: "Provider dashboard cookies", symbol: "key.horizontal") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Use this when OmniRoute does not publish an account quota. xKiro has a ready-to-use dashboard preset; custom endpoints support percentage or used-and-limit values.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.cookieSources.isEmpty {
                        Text("No dashboard cookies saved.")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(Array(model.cookieSources), id: \CookieQuotaSource.id) { (source: CookieQuotaSource) in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(displayProviderName(source.provider)) · \(source.accountName)")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(model.cookieSourceErrors[source.id] ?? source.endpoint)
                                        .font(.system(size: 8))
                                        .foregroundStyle(model.cookieSourceErrors[source.id] == nil ? Color.secondary.opacity(0.6) : Color.orange)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Button { model.removeCookieSource(source) } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Remove cookie source and delete its Keychain cookie")
                            }
                        }
                    }
                    if !model.accountsMissingQuota.isEmpty {
                        Text("\(model.accountsMissingQuota.count) OmniRoute account\(model.accountsMissingQuota.count == 1 ? "" : "s") have no quota snapshot yet.")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Add dashboard cookie…") { showCookieEditor = true }
                            .buttonStyle(.bordered)
                        Button("Refresh cookie sources") { model.refreshCookieSources() }
                            .buttonStyle(.bordered)
                    }
                    Text("Cookies are stored in macOS Keychain and sent only to the HTTPS endpoint you enter. TDZStatus does not send them to OmniRoute or the Codex Reset site.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsCard(title: "OpenAI reset estimates", symbol: "clock.arrow.circlepath") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Show global community reset forecast", isOn: $model.showCodexGlobalEstimate)
                        .toggleStyle(.switch)
                        .font(.system(size: 12))
                    Text("Personal limits and reset times come from the official Codex app-server. The optional global forecast reads codex-reset.com once per minute or less and does not predict your account’s quota reset.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsCard(title: "Activity detection", symbol: "waveform.path") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Open apps are detected automatically. Accurate thinking and tool activity comes from each harness’s lifecycle hooks.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Label("Codex reads the existing ~/.codex-status hook markers when installed.", systemImage: "checkmark.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Label("Claude Code hook setup is not installed automatically.", systemImage: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Text("TDZStatus reads only OmniRoute account labels and quota snapshot columns. Cookies entered for provider dashboards will be stored in macOS Keychain.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
    }

    private var footer: some View {
        HStack {
            Label("Local data", systemImage: "lock.shield")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button { model.section = .settings } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Settings")
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .font(.system(size: 10, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private func sectionHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .bold, design: .rounded))
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func connectionLine(title: String, detail: String, good: Bool) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold))
            Spacer()
            Circle().fill(good ? Color.green : Color.orange).frame(width: 6, height: 6)
            Text(detail).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    private func configureCookie(for account: ProviderAccount) {
        selectedCookieAccountID = account.id
        showCookieEditor = true
    }
}

private struct HarnessCard: View {
    let state: HarnessState

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: state.kind.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(nsColor: state.kind.accent))
                    .frame(width: 30, height: 30)
                    .background(Color(nsColor: state.kind.accent).opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                Spacer(minLength: 0)
                Circle()
                    .fill(state.isBusy ? Color.orange : state.isOpen ? Color.green : Color.gray.opacity(0.45))
                    .frame(width: 7, height: 7)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(state.kind.title).font(.system(size: 12, weight: .bold))
                Text(state.isBusy ? state.activity.title : state.isOpen ? "Open · idle" : "Not open")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(state.isBusy ? Color.orange : Color.secondary)
                if let model = state.model, !model.isEmpty {
                    Text(model).font(.system(size: 9)).lineLimit(1).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.045)))
    }
}

private struct ProviderPoolCard: View {
    let pool: ProviderPool
    @Binding var expandedProvider: String?
    var splitAccounts: Bool
    var fullWidth = false
    var configureCookie: (ProviderAccount) -> Void

    private var isExpanded: Bool {
        !pool.isSingleAccount && expandedProvider == pool.id
    }

    private var summaryDetail: String {
        if pool.isNVIDIA { return "No measurable quota exposed" }
        if let account = pool.accounts.first, pool.isSingleAccount {
            return "\(account.displayName) · direct account"
        }
        return "\(pool.accountsWithUsage) of \(pool.accountCount) accounts reporting"
    }

    private var hasHiddenGitHubLimits: Bool {
        pool.isGitHubCopilot && pool.windows.contains {
            ["chat", "completions"].contains($0.key)
                && $0.remainingPercentage == 0
                && !$0.isExhausted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header

            if pool.isNVIDIA {
                noMeasuredQuota
            } else if pool.windowKeys.isEmpty {
                noSnapshot
            } else {
                usageSummary
            }

            if isExpanded || (splitAccounts && !pool.isSingleAccount && !pool.isNVIDIA) {
                accountBreakdown
            }
        }
        .padding(14)
        .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.06)))
    }

    private var header: some View {
        Button {
            guard !pool.isSingleAccount else { return }
            expandedProvider = isExpanded ? nil : pool.id
        } label: {
            HStack(alignment: .center, spacing: 9) {
                ProviderGlyph(provider: pool.provider)
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayProviderName(pool.provider))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary)
                    Text(summaryDetail)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !pool.isSingleAccount {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pool.isSingleAccount)
    }

    private var noMeasuredQuota: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "infinity")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(.quaternary, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("No measurable usage limit")
                    .font(.system(size: 10, weight: .semibold))
                Text("NVIDIA does not expose a quota that TDZStatus can track for this connection.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private var noSnapshot: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("No quota snapshot yet")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(pool.isSingleAccount
                ? "Connect this provider dashboard to show its current allowance and reset."
                : "Open an account row to connect a provider dashboard.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if pool.isSingleAccount, let account = pool.accounts.first {
                Button(cookieButtonTitle(for: account)) { configureCookie(account) }
                    .font(.system(size: 9, weight: .semibold))
                    .buttonStyle(.link)
            }
        }
    }

    private var usageSummary: some View {
        VStack(alignment: .leading, spacing: 9) {
            if pool.isAntigravity {
                Label("Two shared weekly pools: Gemini and all other models.", systemImage: "link")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            ForEach(pool.windowKeys.prefix(fullWidth ? 5 : 2), id: \.self) { key in
                UsageSummaryLine(
                    title: displayQuotaWindowName(key, provider: pool.provider),
                    remaining: pool.averageRemaining(for: key),
                    reset: pool.nextReset(for: key)
                )
            }
            if hasHiddenGitHubLimits {
                Label("Chat and Completions do not report a measurable quota in this Copilot snapshot.", systemImage: "info.circle")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accountBreakdown: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider().opacity(0.5)
            Text("Accounts")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            ForEach(pool.accounts.indices, id: \.self) { index in
                accountDetail(pool.accounts[index])
            }
        }
    }

    @ViewBuilder
    private func accountDetail(_ account: ProviderAccount) -> some View {
        let accountWindows = pool.windows(for: account)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(account.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(accountWindows.isEmpty ? "Needs dashboard" : "Reporting")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(accountWindows.isEmpty ? Color.secondary : Color.green)
            }
            if accountWindows.isEmpty {
                Text("No trackable quota was recorded for this account.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Button(cookieButtonTitle(for: account)) { configureCookie(account) }
                    .font(.system(size: 9, weight: .semibold))
                    .buttonStyle(.link)
            } else {
                ForEach(accountWindows) { window in
                    UsageWindowLine(window: window)
                }
            }
        }
        .padding(.top, 1)
    }

    private func cookieButtonTitle(for account: ProviderAccount) -> String {
        pool.provider.caseInsensitiveCompare("xkiro") == .orderedSame
            ? "Connect xKiro dashboard…"
            : "Connect provider dashboard…"
    }
}

private struct UsageSummaryLine: View {
    let title: String
    let remaining: Double?
    let reset: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let remaining {
                    Text("\(Int(remaining.rounded()))% left")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
            UsageProgress(remaining: remaining)
            if let reset {
                Text(resetCaption(reset))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

private struct UsageWindowLine: View {
    let window: QuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(displayQuotaWindowName(window.key, provider: window.provider))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let remaining = window.remainingPercentage {
                    Text("\(Int(remaining.rounded()))% left")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
            UsageProgress(remaining: window.remainingPercentage)
            if let reset = window.resetsAt {
                Text(resetCaption(reset))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(window.isExhausted ? Color.red : Color.secondary.opacity(0.65))
                    .lineLimit(1)
            } else {
                Text(window.isExhausted ? "Limit reached · reset unavailable" : "Reset time unavailable")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(window.isExhausted ? Color.red : Color.secondary.opacity(0.65))
            }
        }
    }
}

private func resetCaption(_ reset: Date) -> String {
    "Resets \(reset.formatted(.relative(presentation: .named))) · \(reset.formatted(date: .abbreviated, time: .shortened))"
}

private struct UsageProgress: View {
    var remaining: Double?
    var body: some View {
        let left = min(100, max(0, remaining ?? 0))
        ProgressView(value: left, total: 100)
            .progressViewStyle(.linear)
            .tint(left < 15 ? .red : left < 40 ? .orange : .green)
            .scaleEffect(x: 1, y: 0.8, anchor: .center)
    }
}

private struct ProviderGlyph: View {
    let provider: String
    var body: some View {
        let color: Color = {
            let name = provider.lowercased()
            if name.contains("anthropic") || name.contains("claude") { return Color(red: 0.85, green: 0.47, blue: 0.34) }
            if name.contains("openai") || name.contains("codex") { return Color(red: 0.20, green: 0.65, blue: 0.48) }
            if name.contains("google") || name.contains("gemini") || name.contains("antigravity") { return Color.blue }
            if name.contains("github") { return Color.primary }
            return Color.accentColor
        }()
        Image(systemName: "circle.hexagongrid.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 30, height: 30)
            .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct CodexOfficialCard: View {
    @ObservedObject var model: TDZStatusModel
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color.green)
                Text("OpenAI · Codex limits")
                    .font(.system(size: 12, weight: .bold))
                Text("OFFICIAL")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.5)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.green.opacity(0.12), in: Capsule())
                    .foregroundStyle(.green)
                Spacer()
                Button { model.refreshCodexUsage() } label: {
                    if model.isRefreshingCodexUsage {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.isRefreshingCodexUsage)
                .help("Refresh the official account limit data")
            }
            if let snapshot = model.codexSnapshot {
                HStack {
                    Text(snapshot.accountName ?? "ChatGPT account")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let plan = snapshot.planName {
                        Text(plan.capitalized)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    Text("Updated \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                ForEach(compact ? Array(snapshot.windows.prefix(2)) : snapshot.windows) { window in
                    CodexWindowLine(window: window)
                }
            } else {
                Text(model.codexStatusMessage)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Connect a ChatGPT account in Codex to show the official usage windows and resets.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.green.opacity(0.035), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.green.opacity(0.14)))
    }
}

private struct ZCodeUsageCard: View {
    @ObservedObject var model: TDZStatusModel
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color(nsColor: HarnessKind.zcode.accent))
                Text("ZCode plan limits")
                    .font(.system(size: 12, weight: .bold))
                Text("LOCAL")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.5)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: HarnessKind.zcode.accent).opacity(0.12), in: Capsule())
                    .foregroundStyle(Color(nsColor: HarnessKind.zcode.accent))
                Spacer()
                if let capturedAt = model.zcodeUsage?.capturedAt {
                    Text("Updated \(capturedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }

            if let snapshot = model.zcodeUsage, !snapshot.balances.isEmpty {
                ForEach(compact ? Array(snapshot.balances.prefix(2)) : snapshot.balances) { balance in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(balance.model)
                                .font(.system(size: 10, weight: .semibold))
                            Spacer()
                            if let remaining = balance.remainingPercentage {
                                Text("\(Int(remaining.rounded()))% left")
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                            }
                        }
                        UsageProgress(remaining: balance.remainingPercentage)
                        if let reset = balance.resetsAt {
                            Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened)) · \(reset.formatted(.relative(presentation: .named)))")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Reset time unavailable")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } else {
                Text("No cached ZCode plan quota was found. Open ZCode and let its usage panel load, then refresh TDZStatus.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: HarnessKind.zcode.accent).opacity(0.045), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Color(nsColor: HarnessKind.zcode.accent).opacity(0.13)))
    }
}

private struct CodexWindowLine: View {
    let window: CodexQuotaWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.title).font(.system(size: 10, weight: .semibold))
                if let duration = window.windowDurationMinutes {
                    Text("· \(duration >= 60 ? "\(duration / 60)h" : "\(duration)m")")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int((100 - window.usedPercentage).rounded()))% left")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            UsageProgress(remaining: 100 - window.usedPercentage)
            if let reset = window.resetsAt {
                Text("Official reset \(reset.formatted(date: .abbreviated, time: .shortened)) · \(reset.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Text("Reset time unavailable")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct GlobalResetEstimateCard: View {
    @ObservedObject var model: TDZStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.orange)
                Text("Global Codex reset forecast")
                    .font(.system(size: 11, weight: .bold))
                Spacer()
                Text("COMMUNITY")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(.orange)
            }
            Text("Global community forecast from public OpenAI staff signals. It is not a personal quota reset prediction.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let forecast = model.codexResetForecast {
                HStack(spacing: 8) {
                    forecastMetric("Next 24 hours", value: forecast.probability.next24Hours)
                    forecastMetric("Next 48 hours", value: forecast.probability.next48Hours)
                }
                HStack(spacing: 5) {
                    if let confidence = forecast.confidence {
                        Text("Confidence: \(confidence.capitalized)")
                    }
                    if let window = forecast.likelyWindow {
                        Text("· Likely window: \(window) \(forecast.likelyWindowTimeZone ?? "")")
                    }
                }
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
                if let lastReset = forecast.lastResetAt {
                    Text("Last confirmed global reset \(lastReset.formatted(date: .abbreviated, time: .shortened)) · \(lastReset.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                if let updated = forecast.updatedAt {
                    Text("Forecast updated \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            } else if let error = model.codexResetForecastError {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            } else {
                Text(model.isRefreshingCodexResetForecast ? "Loading community forecast…" : "The global forecast will appear here when available.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Link("Data: codex-reset.com", destination: URL(string: "https://codex-reset.com/")!)
                    .font(.system(size: 9, weight: .semibold))
                Button(model.isRefreshingCodexResetForecast ? "Updating…" : "Refresh") {
                    model.refreshCodexResetForecast()
                }
                .font(.system(size: 9, weight: .semibold))
                .buttonStyle(.plain)
                .disabled(model.isRefreshingCodexResetForecast || !model.canRefreshCodexResetForecast)
                Link("Details", destination: URL(string: "https://codex-reset.com/developers/")!)
                    .font(.system(size: 9, weight: .medium))
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.orange.opacity(0.14)))
    }

    private func forecastMetric(_ label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value)%")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .bold, design: .rounded))
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.primary.opacity(0.055)))
    }
}

private struct EmptyStateCard: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(detail).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
