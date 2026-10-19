import SwiftUI

private enum CookieQuotaPreset: String, CaseIterable, Identifiable {
    case custom
    case xkiro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .custom: "Custom endpoint"
        case .xkiro: "xKiro · Free models daily allowance"
        }
    }

    static func suggested(for provider: String?) -> CookieQuotaPreset {
        provider?.caseInsensitiveCompare("xkiro") == .orderedSame ? .xkiro : .custom
    }

    var configuration: (
        endpoint: String,
        windowKey: String,
        valueField: String,
        limitField: String,
        resetField: String,
        durationField: String,
        valueMode: CookieQuotaValueMode
    )? {
        switch self {
        case .custom: nil
        case .xkiro:
            (
                endpoint: "https://xkiro.com/api/v1/me/subscription",
                windowKey: "Free models · daily",
                valueField: "data.freeQuota.usedToday",
                limitField: "data.freeQuota.cap",
                resetField: "data.freeQuota.resetAt",
                durationField: "",
                valueMode: .usedOfLimit
            )
        }
    }
}

struct CookieSourceEditor: View {
    @ObservedObject var model: TDZStatusModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAccountID: String
    @State private var providerName: String
    @State private var accountName: String
    @State private var preset: CookieQuotaPreset
    @State private var endpoint: String
    @State private var cookie = ""
    @State private var windowKey: String
    @State private var valueField: String
    @State private var limitField: String
    @State private var resetField: String
    @State private var durationField: String
    @State private var valueMode: CookieQuotaValueMode
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(model: TDZStatusModel, initialAccountID: String? = nil) {
        self.model = model
        let initialAccount = model.accounts.first { $0.id == initialAccountID }
        let initialPreset = CookieQuotaPreset.suggested(for: initialAccount?.provider)
        let configuration = initialPreset.configuration
        _selectedAccountID = State(initialValue: initialAccount?.id ?? "__custom__")
        _providerName = State(initialValue: initialAccount?.provider ?? "")
        _accountName = State(initialValue: initialAccount?.displayName ?? "")
        _preset = State(initialValue: initialPreset)
        _endpoint = State(initialValue: configuration?.endpoint ?? "")
        _windowKey = State(initialValue: configuration?.windowKey ?? "Usage window")
        _valueField = State(initialValue: configuration?.valueField ?? "data.usage.remaining_percentage")
        _limitField = State(initialValue: configuration?.limitField ?? "")
        _resetField = State(initialValue: configuration?.resetField ?? "data.usage.resets_at")
        _durationField = State(initialValue: configuration?.durationField ?? "")
        _valueMode = State(initialValue: configuration?.valueMode ?? .remainingPercentage)
    }

    private var selectedAccount: ProviderAccount? {
        model.accounts.first { $0.id == selectedAccountID }
    }

    private var usesAmountLimit: Bool { valueMode == .usedOfLimit }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect a provider dashboard")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("Saved in Keychain · refreshed every two minutes")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }

            Form {
                Section("Account") {
                    Picker("Provider account", selection: $selectedAccountID) {
                        ForEach(model.accounts) { account in
                            Text("\(displayProviderName(account.provider)) · \(account.displayName)").tag(account.id)
                        }
                        Text("New provider account").tag("__custom__")
                    }
                    if let selectedAccount {
                        TextField("Account label", text: $accountName)
                        LabeledContent("Provider", value: displayProviderName(selectedAccount.provider))
                    } else {
                        TextField("Provider ID", text: $providerName, prompt: Text("e.g. anthropic, gemini-web"))
                        TextField("Account label", text: $accountName, prompt: Text("e.g. Personal"))
                    }
                }

                Section("Dashboard usage") {
                    Picker("Provider preset", selection: $preset) {
                        ForEach(CookieQuotaPreset.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    TextField("HTTPS endpoint", text: $endpoint, prompt: Text("https://provider.example/api/usage"))
                    TextField("Window label", text: $windowKey)
                    Picker("Response value", selection: $valueMode) {
                        ForEach(CookieQuotaValueMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    TextField(usesAmountLimit ? "Used amount field" : "Percentage field", text: $valueField)
                    if usesAmountLimit {
                        TextField("Limit field", text: $limitField)
                    }
                    TextField("Reset timestamp field", text: $resetField, prompt: Text("data.usage.resets_at"))
                    TextField("Window duration in minutes field", text: $durationField, prompt: Text("Optional"))
                    Text("xKiro is prefilled from its dashboard endpoint. Custom sources can use dot paths or JSON Pointer paths. Reset values may be ISO dates or Unix timestamps.")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Website cookie") {
                    SecureField("Cookie-Editor header", text: $cookie, prompt: Text("__xt_at=…; __xt_rt=…; __xt_user=…; xtrouter_theme=dark"))
                    if selectedAccount?.provider.caseInsensitiveCompare("xkiro") == .orderedSame {
                        Text("Paste Cookie-Editor’s full semicolon-separated header. TDZStatus keeps xKiro’s __xt_at, __xt_rt, and __xt_user cookies and drops theme and analytics cookies.")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("The cookie is sent only to this provider endpoint and is stored in macOS Keychain after a successful test.")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    testAndSave()
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Test & Save")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || (selectedAccount == nil && providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(18)
        .onChange(of: selectedAccountID) { _ in
            guard let selectedAccount else {
                providerName = ""
                accountName = ""
                return
            }
            providerName = selectedAccount.provider
            accountName = selectedAccount.displayName
            let suggested = CookieQuotaPreset.suggested(for: selectedAccount.provider)
            if suggested != .custom {
                preset = suggested
                applyPreset(suggested)
            }
        }
        .onChange(of: preset) { _ in applyPreset(preset) }
    }

    private func applyPreset(_ preset: CookieQuotaPreset) {
        guard let configuration = preset.configuration else { return }
        endpoint = configuration.endpoint
        windowKey = configuration.windowKey
        valueField = configuration.valueField
        limitField = configuration.limitField
        resetField = configuration.resetField
        durationField = configuration.durationField
        valueMode = configuration.valueMode
    }

    private func testAndSave() {
        isSaving = true
        errorMessage = nil
        let account = selectedAccount
        let source = CookieQuotaSource(
            id: UUID().uuidString,
            provider: account?.provider ?? providerName.trimmingCharacters(in: .whitespacesAndNewlines),
            connectionID: account?.connectionID ?? "cookie:\(UUID().uuidString)",
            accountName: accountName.trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            windowKey: windowKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Usage window" : windowKey.trimmingCharacters(in: .whitespacesAndNewlines),
            remainingField: valueField.trimmingCharacters(in: .whitespacesAndNewlines),
            resetField: resetField.trimmingCharacters(in: .whitespacesAndNewlines),
            durationField: durationField.trimmingCharacters(in: .whitespacesAndNewlines),
            valueIsUsedPercentage: valueMode == .usedPercentage,
            valueMode: valueMode,
            limitField: usesAmountLimit ? limitField.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            updatedAt: Date()
        )
        model.testAndSaveCookieSource(source, cookie: cookie) { result in
            isSaving = false
            switch result {
            case .success:
                cookie = ""
                dismiss()
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }
}
