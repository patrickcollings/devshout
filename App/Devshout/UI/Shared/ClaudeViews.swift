// Claude Code install sheet, sign-in panel and paste-a-token disclosure, shared by onboarding and Settings → Claude.
// Auth is a `claude setup-token` OAuth token kept in the Keychain. There is deliberately no API-key option.
//
// Unsure on macOS (not compiled here):
// - `ScrollViewReader.scrollTo` inside `.onChange(of:)` for the live install log.
// - Inline Markdown (`code`) in string-literal `Text` (standard LocalizedStringKey behaviour).

import DevshoutCore
import SwiftUI

// MARK: - Install sheet

struct ClaudeInstallSheet: View {
    @ObservedObject var model: ClaudeViewModel
    @Environment(\.dismiss) private var dismiss

    private var isInstalling: Bool { model.install == .installing }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                SymbolTile(systemName: "terminal.fill", tint: .orange, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Install Claude Code").font(.title2.bold())
                    Text("devshout tidies your dictation with Claude Code, Anthropic's command-line tool, using your own Claude plan.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Anthropic's official installer:").font(.callout.weight(.medium))
                CopyableCommand(command: ClaudeViewModel.installCommand)
                Text("Or with Homebrew (this version doesn't update itself):")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                CopyableCommand(command: ClaudeViewModel.homebrewCommand)
            }

            if isInstalling || !model.installLog.isEmpty {
                InstallLogView(log: model.installLog)
            }

            if case .installFailed(let message) = model.install {
                StatusLabel(text: message, tone: .critical)
            }

            HStack {
                Button("Check Again") { model.detect() }
                    .disabled(isInstalling)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open in Terminal") { model.openInstallerInTerminal() }
                    .disabled(isInstalling)
                Button {
                    model.installForMe()
                } label: {
                    if isInstalling {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Installing…")
                        }
                    } else {
                        Text("Install for Me")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isInstalling)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}

private struct InstallLogView: View {
    let log: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(log.isEmpty ? "Starting…" : log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(8)
            }
            .frame(height: 130)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .onChange(of: log) { _, _ in
                proxy.scrollTo("end", anchor: .bottom)
            }
        }
    }
}

// MARK: - Sign-in

/// Shown while `claude setup-token` runs: browser approval, an optional sign-in link and code field, and the
/// paste-a-token fallback.
struct ClaudeSignInPanel: View {
    @ObservedObject var model: ClaudeViewModel
    let progress: ClaudeSignInProgress
    @Environment(\.openURL) private var openURL
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finish in your browser…").font(.headline)
            }
            Text("Approve access on Claude's sign-in page. devshout keeps the token it gets in this Mac's Keychain, and only uses it to tidy your dictation.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if let url = progress.signInURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Open Sign-in Page", systemImage: "safari")
                    }
                }
                Button("Cancel") { model.cancelSignIn() }
            }

            if progress.needsCode {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Paste the code shown in your browser:").font(.callout)
                    HStack(spacing: 8) {
                        TextField("Code", text: $code)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onSubmit { model.submitCode(code) }
                        Button("Submit") { model.submitCode(code) }
                            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || progress.isSubmittingCode)
                    }
                }
            }

            if let message = progress.message {
                StatusLabel(text: message, tone: .warning)
            }

            PasteTokenDisclosure(model: model)
        }
    }
}

/// "Paste a token instead": for when the in-app flow fails and the token was made in Terminal.
struct PasteTokenDisclosure: View {
    @ObservedObject var model: ClaudeViewModel
    @State private var isExpanded = false
    @State private var token = ""

    var body: some View {
        DisclosureGroup("Paste a token instead", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("In Terminal, run this, approve access in your browser, then paste the token it prints:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                CopyableCommand(command: ClaudeViewModel.setupTokenCommand)
                HStack(spacing: 8) {
                    SecureField("Token", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { useToken() }
                    Button("Use Token") { useToken() }
                        .disabled(token.isEmpty)
                }
                if let error = model.pasteTokenError {
                    StatusLabel(text: error, tone: .warning)
                }
            }
            .padding(.top, 6)
        }
    }

    private func useToken() {
        if model.useToken(token) { token = "" }
    }
}

// MARK: - Test result

struct ClaudeTestResultLabel: View {
    let test: ClaudeTestStatus

    var body: some View {
        switch test {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").foregroundStyle(.secondary)
            }
        case .succeeded(let elapsed, _):
            StatusLabel(text: "Tidy works, \(UIFormat.seconds(elapsed))", tone: .positive)
        case .failed(let message):
            StatusLabel(text: message, tone: .critical)
        }
    }
}

#Preview("Install sheet") {
    ClaudeInstallSheet(model: PreviewData.claude(.notConnected, install: .installing,
                                                 installLog: PreviewData.installLog))
}

#Preview("Signing in") {
    ClaudeSignInPanel(model: PreviewData.claude(PreviewData.signingIn),
                      progress: PreviewData.signingIn.signIn ?? ClaudeSignInProgress())
        .padding()
        .frame(width: 460)
}
