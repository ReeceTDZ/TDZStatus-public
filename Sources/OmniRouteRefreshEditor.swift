import SwiftUI

struct OmniRouteRefreshEditor: View {
    @ObservedObject var model: TDZStatusModel
    @Environment(\.dismiss) private var dismiss
    @State private var cookie = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connect OmniRoute refresh")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("Lets TDZStatus ask your local OmniRoute dashboard to fetch fresh provider limits.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Dashboard cookie")
                    .font(.system(size: 11, weight: .semibold))
                SecureField("Cookie-Editor header containing auth_token", text: $cookie)
                    .textFieldStyle(.roundedBorder)
                Text("In Cookie-Editor while on localhost:20128, copy the full Cookie header. TDZStatus keeps only auth_token in macOS Keychain and sends it only to localhost.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Remove connection") {
                    model.removeOmniRouteRefreshSession()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .disabled(!model.hasOmniRouteRefreshSession)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    save()
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Verify & Save")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        model.testAndSaveOmniRouteRefreshSession(cookie: cookie) { result in
            isSaving = false
            switch result {
            case .success:
                cookie = ""
                dismiss()
                model.refreshUsageNow()
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }
}
