import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vm: TranscriberViewModel
    @State private var apiKey: String = ""
    @State private var showKey: Bool = false
    @State private var feedback: (text: String, isError: Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 18))
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.system(size: 14, weight: .semibold))
                    Text(statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(statusColor.opacity(0.10))
            )

            Divider()

            Text("OpenAI API Key")
                .font(.headline)

            HStack(spacing: 8) {
                Group {
                    if showKey {
                        TextField("sk-…", text: $apiKey)
                    } else {
                        SecureField("sk-…", text: $apiKey)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

                Button {
                    showKey.toggle()
                } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(showKey ? "Hide key" : "Show key")
            }

            HStack(spacing: 8) {
                Button("Save to Keychain") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Remove") {
                    remove()
                }
                .disabled(!KeychainStore.hasAPIKey() && apiKey.isEmpty)

                Spacer()

                if let fb = feedback {
                    Text(fb.text)
                        .font(.caption)
                        .foregroundStyle(fb.isError ? .red : .green)
                        .transition(.opacity)
                }
            }

            Divider().padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 6) {
                Text("How it's stored")
                    .font(.subheadline.bold())
                Text("Your key is saved in the macOS Keychain (service `com.harnit.LanguageTranscriber`). It's never written to disk in plain text. If no key is set here, the app falls back to `config.json` next to the app, then to the `OPENAI_API_KEY` environment variable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { apiKey = KeychainStore.loadAPIKey() ?? "" }
    }

    private func save() {
        if KeychainStore.saveAPIKey(apiKey) {
            feedback = ("Saved", false)
            vm.loadConfig()
        } else {
            feedback = ("Save failed", true)
        }
        dismissFeedbackAfterDelay()
    }

    private func remove() {
        KeychainStore.deleteAPIKey()
        apiKey = ""
        feedback = ("Removed", false)
        vm.loadConfig()
        dismissFeedbackAfterDelay()
    }

    private func dismissFeedbackAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation { feedback = nil }
        }
    }

    // MARK: - Status helpers (read directly from the live view model)

    private var statusSymbol: String {
        switch vm.apiKeySource {
        case .keychain, .configFile, .envVar: return "checkmark.seal.fill"
        case .none: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch vm.apiKeySource {
        case .keychain: return .green
        case .configFile, .envVar: return .blue
        case .none: return .orange
        }
    }

    private var statusTitle: String {
        switch vm.apiKeySource {
        case .keychain:   return "API key is set"
        case .configFile: return "API key is set"
        case .envVar:     return "API key is set"
        case .none:       return "No API key configured"
        }
    }

    private var statusSubtitle: String {
        switch vm.apiKeySource {
        case .keychain:   return "Source: macOS Keychain (recommended)"
        case .configFile: return "Source: config.json — consider moving to Keychain for security"
        case .envVar:     return "Source: OPENAI_API_KEY environment variable"
        case .none:       return "Paste your key below and click Save to store it in the Keychain."
        }
    }
}
