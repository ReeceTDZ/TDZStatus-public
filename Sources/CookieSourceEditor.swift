import SwiftUI

struct CookieSourceEditor: View {
    @ObservedObject var model: TDZStatusModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAccountID: String
    @State private var providerName: String
    @State private var accountName: String
    @State private var endpoint = ""
    @State private var cookie = ""
    @State private var windowKey = "Usage window"
    @State private var remainingField = "data.usage.remaining_percentage"
    @State private var resetField = "data.usage.resets_at"
    @State private var durationField = "data.usage.window_minutes"
    @State private var valueIsUsedPercentage = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(model: TDZStatusModel, initialAccountID: String? = nil) {
        self.model = model
        let initialAccount = model.accounts.first { $0.id == initialAccountID }
        _selectedAccountID = State(initialValue: initialAccount?.id ?? "__custom__")
        _providerName = State(initialValue: initialAccount?.provider ?? "")
        _accountName = State(initialValue: initialAccount?.displayName ?? "")
    }

    private var selectedAccount: ProviderAccount? {
        model.accounts.first { $0.id == selectedAccountID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect a provider dashboard")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("Secure cookie fallback for missing quota snapshots")
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

                Section("Usage endpoint") {
                    TextField("HTTPS JSON endpoint", text: $endpoint, prompt: Text("https://provider.example/api/usage"))
                    TextField("Window label", text: $windowKey)
                    TextField("Remaining or used % field", text: $remainingField)
                    Toggle("The field is used % (not remaining %)", isOn: $valueIsUsedPercentage)
                    TextField("Reset timestamp field", text: $resetField, prompt: Text("data.usage.resets_at"))
                    TextField("Window duration in minutes field", text: $durationField, prompt: Text("Optional"))
                    Text("Field paths can use dot notation (data.usage.remaining) or JSON Pointer (/data/usage/remaining). Reset values can be ISO dates or Unix timestamps.")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Website cookie") {
                    SecureField("Paste the cookie header", text: $cookie)
                    Text("The cookie is sent only to the endpoint above and stored in macOS Keychain after a successful test.")
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
            if let selectedAccount {
                providerName = selectedAccount.provider
                accountName = selectedAccount.displayName
            } else {
                providerName = ""
                accountName = ""
            }
        }
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
            remainingField: remainingField.trimmingCharacters(in: .whitespacesAndNewlines),
            resetField: resetField.trimmingCharacters(in: .whitespacesAndNewlines),
            durationField: durationField.trimmingCharacters(in: .whitespacesAndNewlines),
            valueIsUsedPercentage: valueIsUsedPercentage,
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
