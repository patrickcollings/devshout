// Settings → Claude, Settings → Glossary and Settings → Privacy & Storage.
//
// Unsure on macOS (not compiled here):
// - The sign-in sheet's isPresented binding: SwiftUI should only call its setter on a user dismissal (Esc), which
//   cancels the flow; wiring's cancel must be a no-op when nothing is running, in case it is also called after a
//   successful sign-in closes the sheet.
// - `TextEditor` smart quotes/dashes can't be turned off from SwiftUI on macOS 14; `.autocorrectionDisabled()`
//   only stops spelling correction. Fine for glossary.md (it uses — anyway), but worth knowing.

import DevshoutCore
import SwiftUI

// MARK: - Claude

struct ClaudeSettingsTab: View {
    @ObservedObject var model: ClaudeViewModel
    @State private var confirmingDisconnect = false

    private var signInSheetBinding: Binding<Bool> {
        Binding(get: { model.account.signIn != nil },
                set: { isPresented in if !isPresented, model.account.signIn != nil { model.cancelSignIn() } })
    }

    var body: some View {
        Form {
            installSection
            accountSection
            testSection
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.width, height: 480)
        .sheet(isPresented: $model.isInstallSheetPresented) {
            ClaudeInstallSheet(model: model)
        }
        .sheet(isPresented: signInSheetBinding) {
            ClaudeSignInSheet(model: model)
        }
        .confirmationDialog("Disconnect Claude?", isPresented: $confirmingDisconnect) {
            Button("Disconnect", role: .destructive) { model.disconnect() }
        } message: {
            Text("devshout deletes its token from the Keychain. Tidy and Structure will paste the raw text until you connect again.")
        }
    }

    // MARK: Claude Code

    private var installSection: some View {
        Section {
            LabeledContent("Status") {
                StatusLabel(text: model.install.summary, tone: model.install.tone)
            }
            if let installation = model.install.installation {
                LabeledContent("Location") {
                    HStack(spacing: 8) {
                        Text(installation.path)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(installation.path)
                        Button("Change…") { chooseClaude() }
                    }
                }
                if !installation.meetsMinimum {
                    HStack {
                        Spacer()
                        Button("Update Claude Code…") { model.showInstallSheet() }
                    }
                }
            } else {
                HStack {
                    Button("Check Again") { model.detect() }
                    Spacer()
                    Button("Choose…") { chooseClaude() }
                    Button("Install Claude Code…") { model.showInstallSheet() }
                        .buttonStyle(.borderedProminent)
                }
            }
        } header: {
            Text("Claude Code")
        }
    }

    private func chooseClaude() {
        if let url = OpenPanels.chooseClaudeBinary() { model.setClaudePath(url) }
    }

    // MARK: Account

    private var accountSection: some View {
        let now = model.now
        return Section {
            LabeledContent("Account") {
                StatusLabel(text: model.account.summary(now: now), tone: model.account.tone(now: now))
            }
            if let expiry = model.expiry {
                LabeledContent("Token expires", value: UIFormat.day(expiry.expiresAt))
                if expiry.needsWarning(now: now) {
                    expiryWarning(expiry, now: now)
                }
            }
            if case .needsReconnect(let reason) = model.account {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                accountButtons
            }
            if showsPasteToken {
                PasteTokenDisclosure(model: model)
            }
        } header: {
            Text("Account")
        } footer: {
            Text("devshout keeps a token from `claude setup-token` in this Mac's Keychain and uses your own Claude plan. The token lasts a year.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The paste-a-token fallback stays reachable after the in-app flow failed (it is also inside the sign-in sheet).
    private var showsPasteToken: Bool {
        switch model.account {
        case .unknown, .notConnected, .needsReconnect: true
        case .signingIn, .connected: false
        }
    }

    private func expiryWarning(_ expiry: TokenExpiry, now: Date) -> some View {
        let days = max(expiry.daysRemaining(now: now), 0)
        let text = expiry.isExpired(now: now)
            ? "Your token has expired. Reconnect to keep Tidy and Structure working; until then they paste the raw text."
            : "Your token expires \(TokenExpiry.inDays(days)). Reconnect to keep Tidy and Structure working."
        return StatusLabel(text: text, tone: expiry.isExpired(now: now) ? .critical : .warning)
            .font(.callout)
    }

    @ViewBuilder
    private var accountButtons: some View {
        switch model.account {
        case .unknown, .notConnected:
            Button("Connect…") { model.connect() }
                .buttonStyle(.borderedProminent)
        case .signingIn:
            Button("Cancel Sign-in") { model.cancelSignIn() }
        case .connected:
            Button("Disconnect…") { confirmingDisconnect = true }
            Button("Reconnect…") { model.connect() }
        case .needsReconnect:
            Button("Disconnect…") { confirmingDisconnect = true }
            Button("Reconnect…") { model.connect() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Test

    private var testSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: 10) {
                    if let summary = model.test.summary {
                        Text(summary)
                            .foregroundStyle(testColor)
                            .monospacedDigit()
                    }
                    Button("Test Connection") { model.runTest() }
                        .disabled(!model.account.isConnected || model.test == .running)
                }
            } label: {
                Text("Connection")
                Text("Sends one short request to Haiku.")
            }
        }
    }

    private var testColor: Color {
        switch model.test {
        case .succeeded: .green
        case .failed: .red
        default: .secondary
        }
    }
}

/// The sign-in flow as a sheet (Settings). Onboarding shows `ClaudeSignInPanel` inline instead.
private struct ClaudeSignInSheet: View {
    @ObservedObject var model: ClaudeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect Claude").font(.title2.bold())
            if let progress = model.account.signIn {
                ClaudeSignInPanel(model: model, progress: progress)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

// MARK: - Glossary

struct GlossarySettingsTab: View {
    @ObservedObject var model: GlossaryViewModel
    @State private var showsHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("glossary.md").font(.headline)
                Button {
                    showsHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help("About the glossary format")
                .popover(isPresented: $showsHelp, arrowEdge: .bottom) {
                    GlossaryHelpView()
                }
                Spacer()
                Text(model.counts.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            TextEditor(text: $model.text)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )

            if let error = model.errorMessage {
                StatusLabel(text: error, tone: .critical)
            }

            HStack(spacing: 10) {
                if model.fileURL != nil {
                    Button("Show in Finder") { model.showInFinder() }
                }
                Spacer()
                if model.isDirty {
                    Text("Unsaved changes").font(.caption).foregroundStyle(.secondary)
                } else if let saved = model.lastSaved {
                    Text("Saved at \(UIFormat.time(saved))").font(.caption).foregroundStyle(.secondary)
                }
                Button("Revert") { model.revert() }
                    .disabled(!model.isDirty)
                Button("Save") { model.saveChanges() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.isDirty)
            }
        }
        .padding(20)
        .frame(width: SettingsLayout.width, height: 520)
    }
}

private struct GlossaryHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The glossary format").font(.headline)
            Text("Claude gets the whole file to get spellings, names and jargon right. Known mishearings are fixed in every mode, Raw included.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                HelpLine(symbol: "number", text: "`## Terms`, `## People` and `## Patterns` are sections. `## Style` is passed to Claude as written.")
                HelpLine(symbol: "list.bullet", text: "One entry per line: `- **Term** — what it means`.")
                HelpLine(symbol: "ear", text: "Add `- heard: a, b` underneath for mishearings to fix.")
                HelpLine(symbol: "textformat.123", text: "In Patterns, `{n}` stands for a number, as in `AB-{n}`.")
                HelpLine(symbol: "pin", text: "Start an entry with `!` (`- !**CORSIA**`) to put it first for Whisper.")
            }
            Text(GlossaryViewModel.formatExample)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
        .padding(16)
        .frame(width: 400)
    }
}

private struct HelpLine: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Privacy & Storage

struct PrivacySettingsTab: View {
    @ObservedObject var model: PrivacyViewModel
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            Section("Storage") {
                Picker("Keep audio for", selection: $model.audioRetention) {
                    ForEach(AudioRetention.allCases) { retention in
                        Text(retention.title).tag(retention)
                    }
                }
                LabeledContent("Keep text", value: "Until you delete it")
                if let summary = model.storageSummary {
                    LabeledContent("History", value: summary)
                }
                HStack {
                    Button("Show in Finder") { model.showInFinder() }
                    Spacer()
                    Button("Delete All History…", role: .destructive) { confirmingDelete = true }
                }
            }

            Section("What goes where") {
                WhereRow(symbol: "mic", title: "Audio",
                         detail: "Stays on this Mac. It is recorded, saved and transcribed here.")
                WhereRow(symbol: "text.bubble", title: "Text",
                         detail: "For Tidy and Structure, the transcript and your glossary go to Anthropic through Claude Code, on your own Claude plan. Raw sends nothing.")
                WhereRow(symbol: "key", title: "Claude token",
                         detail: "Kept in this Mac's Keychain.")
                WhereRow(symbol: "icloud.slash", title: "Accounts and the cloud",
                         detail: "None. devshout has no account of its own and stores nothing online.")
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.width, height: 470)
        .confirmationDialog("Delete all history?", isPresented: $confirmingDelete) {
            Button("Delete All History", role: .destructive) { model.deleteAllHistory() }
        } message: {
            Text("This deletes every recording, its audio and its text. It can't be undone.")
        }
    }
}

private struct WhereRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview("Claude") {
    ClaudeSettingsTab(model: PreviewData.claude(PreviewData.expiringAccount,
                                                test: .succeeded(elapsed: 2.1, at: Date())))
}

#Preview("Claude: not installed") {
    ClaudeSettingsTab(model: PreviewData.claude(.notConnected, install: .notFound))
}

#Preview("Glossary") {
    GlossarySettingsTab(model: GlossaryViewModel(text: PreviewData.glossaryText,
                                                 fileURL: URL(fileURLWithPath: "/tmp/glossary.md"),
                                                 parse: PreviewData.countTerms))
}

#Preview("Privacy") {
    PrivacySettingsTab(model: PrivacyViewModel(storageUsed: 182_000_000, recordingCount: 64))
}
