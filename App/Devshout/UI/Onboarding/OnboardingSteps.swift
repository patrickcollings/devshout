// The onboarding steps. Each shows state from its view model and calls its actions; none decides anything.
//
// Unsure on macOS (not compiled here):
// - `@FocusState` + `.focused` on a TextEditor to put the cursor in the Try it box on appear.
// - `Grid`/`GridRow` (macOS 13+) for the hotkey table.

import DevshoutCore
import SwiftUI

// MARK: - Welcome

struct WelcomeStepView: View {
    var body: some View {
        OnboardingPage(symbol: "waveform", tint: .accentColor, title: "Welcome to devshout",
                       message: "Talk. devshout writes it down, tidies it up, and pastes it.") {
            VStack(alignment: .leading, spacing: 14) {
                PromiseRow(symbol: "lock.shield", title: "Audio never leaves your Mac",
                           detail: "Recordings are saved and transcribed on this Mac.")
                PromiseRow(symbol: "cpu", title: "Transcription is local and free",
                           detail: "Speech-to-text runs on the Neural Engine. No account needed.")
                PromiseRow(symbol: "sparkles", title: "Clean-up uses your own Claude plan",
                           detail: "Only the text goes to Anthropic, through Claude Code. Raw mode skips it.")
            }
            .frame(maxWidth: 420)
        }
    }
}

private struct PromiseRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Microphone

struct MicrophoneStepView: View {
    @ObservedObject var model: MicrophoneViewModel

    var body: some View {
        OnboardingPage(symbol: "mic.fill", tint: .red, title: "Microphone",
                       message: "devshout listens only while you dictate, and the audio stays on this Mac.") {
            switch model.permission {
            case .notDetermined:
                Button("Allow Microphone") { model.requestAccess() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            case .granted:
                VStack(spacing: 10) {
                    StatusLabel(text: "Microphone allowed", tone: .positive)
                    LevelMeter(level: model.level)
                        .frame(width: 280)
                    Text("Say something: you should see this move.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if model.devices.count > 1 {
                        InputDevicePicker(model: model)
                            .frame(width: 280)
                    }
                }
            case .denied:
                VStack(spacing: 10) {
                    StatusLabel(text: "Microphone access is turned off", tone: .critical)
                    Text("Turn on devshout in System Settings → Privacy & Security → Microphone, then come back here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                    Button("Open System Settings") { model.openPrivacySettings() }
                        .controlSize(.large)
                }
            }
        }
    }
}

/// The input device menu ("System default" first).
struct InputDevicePicker: View {
    @ObservedObject var model: MicrophoneViewModel

    var body: some View {
        Picker("Input", selection: $model.selectedDeviceID) {
            Text("System default").tag(String?.none)
            if !model.devices.isEmpty { Divider() }
            ForEach(model.devices) { device in
                Text(device.name).tag(String?.some(device.id))
            }
        }
    }
}

// MARK: - Accessibility

struct AccessibilityStepView: View {
    @ObservedObject var model: AccessibilityViewModel

    var body: some View {
        OnboardingPage(symbol: "keyboard", tint: .blue, title: "Accessibility",
                       message: "devshout pastes by pressing ⌘V for you, and macOS needs your OK for that.") {
            if model.isTrusted {
                StatusLabel(text: "devshout can paste", tone: .positive)
                    .font(.headline)
            } else {
                VStack(spacing: 14) {
                    Button("Open Accessibility Settings") { model.openSettings() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    ToggleHint()
                    if model.hasOpenedSettings {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for permission…").foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    if model.showsStaleEntryHint {
                        StaleEntryHint { model.revealAppInFinder() }
                    }
                }
            }
        }
    }
}

/// A small picture of the row to switch on in System Settings.
private struct ToggleHint: View {
    @State private var isOn = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.accentColor))
            Text("devshout")
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 280)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("In the list, switch on devshout")
        .task {
            // Flip the illustrated switch on and off so it's obvious what to do.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                withAnimation(.easeInOut(duration: 0.25)) { isOn.toggle() }
            }
        }
    }
}

private struct StaleEntryHint: View {
    let reveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Already switched on, but no tick here?").font(.callout.weight(.semibold))
            Text("macOS sometimes keeps an old entry after an update. Select devshout in the list, remove it with −, then add it again with + (or drag it in from Finder).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Show devshout in Finder") { reveal() }
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.1)))
    }
}

// MARK: - Speech model

struct SpeechModelStepView: View {
    @ObservedObject var model: SpeechEngineViewModel

    var body: some View {
        OnboardingPage(symbol: "cpu", tint: .green, title: "Speech model",
                       message: "Transcription runs on this Mac. Pick a model to download; you can change it later.") {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    ForEach(EngineID.allCases, id: \.self) { engine in
                        EngineCard(info: model.info(for: engine), status: model.status(for: engine),
                                   isSelected: model.selectedEngine == engine) {
                            model.selectedEngine = engine
                        }
                    }
                }
                statusArea
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 44, alignment: .top)
            }
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        let status = model.selectedStatus
        switch status {
        case .notDownloaded, .failed:
            HStack {
                if case .failed = status { ModelProgressView(status: status) }
                Spacer()
                Button("Download \(model.selectedEngine.displayName)") { model.download(model.selectedEngine) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        case .downloading, .preparing:
            VStack(alignment: .leading, spacing: 6) {
                ModelProgressView(status: status)
                Text("You can carry on: the download continues in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ready:
            ModelProgressView(status: status)
        }
    }
}

// MARK: - Claude

struct ClaudeStepView: View {
    @ObservedObject var model: ClaudeViewModel

    var body: some View {
        OnboardingPage(symbol: "sparkles", tint: .orange, title: "Claude",
                       message: "Tidy and Structure use Claude Code with your own Claude plan. Raw mode works without it.") {
            VStack(alignment: .leading, spacing: 14) {
                installRow
                if model.install.installation != nil {
                    Divider()
                    accountArea
                }
            }
            .frame(maxWidth: 460, alignment: .leading)
        }
        .sheet(isPresented: $model.isInstallSheetPresented) {
            ClaudeInstallSheet(model: model)
        }
    }

    @ViewBuilder
    private var installRow: some View {
        switch model.install {
        case .detecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(model.install.summary).foregroundStyle(.secondary)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.install.summary).foregroundStyle(.secondary)
                Spacer()
                Button("Show Progress") { model.showInstallSheet() }
            }
        case .found(let installation) where installation.meetsMinimum:
            StatusLabel(text: "\(model.install.summary) found", tone: .positive)
        case .found, .notFound, .installFailed:
            HStack {
                StatusLabel(text: model.install.summary, tone: model.install.tone)
                Spacer()
                Button(model.install.installation == nil ? "Install Claude Code…" : "Update Claude Code…") {
                    model.showInstallSheet()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var accountArea: some View {
        switch model.account {
        case .unknown, .notConnected:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Connect your Claude account. You'll approve access in your browser.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Connect Claude") { model.connect() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                PasteTokenDisclosure(model: model)
            }
        case .signingIn(let progress):
            ClaudeSignInPanel(model: model, progress: progress)
        case .connected:
            HStack {
                StatusLabel(text: "Connected", tone: .positive)
                Spacer()
                ClaudeTestResultLabel(test: model.test)
                if case .failed = model.test {
                    Button("Try Again") { model.runTest() }
                }
            }
        case .needsReconnect(let reason):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    StatusLabel(text: reason, tone: .critical)
                    Spacer()
                    Button("Reconnect") { model.connect() }
                        .buttonStyle(.borderedProminent)
                }
                PasteTokenDisclosure(model: model)
            }
        }
    }
}

// MARK: - Hotkeys

struct HotkeysStepView: View {
    @ObservedObject var hotkeys: HotkeysViewModel

    private let slots: [HotkeySlot] = [.appDefault, .structure, .raw]

    var body: some View {
        OnboardingPage(symbol: "command", tint: .indigo, title: "Hotkeys",
                       message: "Dictate into any app. These are the defaults; change them any time in Settings.") {
            VStack(spacing: 18) {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                    ForEach(slots) { slot in
                        GridRow {
                            HotkeyField(hotkeys: hotkeys, slot: slot)
                                .gridColumnAlignment(.trailing)
                            Text(slot.title)
                        }
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(.yellow)
                    Text("**Tap** to start, and tap again to stop. **Hold** to talk, and let go to stop. **Esc** cancels.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: 440, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
        }
    }
}

// MARK: - Try it

struct TryItStepView: View {
    @ObservedObject var model: OnboardingViewModel
    @FocusState private var isEditorFocused: Bool

    private var hotkeyText: String { model.hotkeys.hotkey(for: .appDefault)?.text ?? "your hotkey" }

    var body: some View {
        OnboardingPage(symbol: "text.cursor", tint: .pink, title: "Try it",
                       message: "Press \(hotkeyText) and say: “Check the CORSIA flag on AB-1234 in My Supply.”") {
            VStack(spacing: 10) {
                TextEditor(text: $model.tryItText)
                    .font(.body)
                    .focused($isEditorFocused)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: model.tryItResult == nil ? 110 : 60)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isEditorFocused ? Color.accentColor : Color.primary.opacity(0.15),
                                          lineWidth: isEditorFocused ? 2 : 1)
                    )
                if let result = model.tryItResult {
                    HStack(alignment: .top, spacing: 12) {
                        ResultColumn(title: "Raw", text: result.raw)
                        ResultColumn(title: "Tidied", text: result.cleaned ?? "Claude isn't connected, so only the raw text was pasted.")
                    }
                }
            }
            .frame(maxWidth: 520)
        }
        .onAppear { isEditorFocused = true }
    }
}

private struct ResultColumn: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

#Preview("Microphone") {
    MicrophoneStepView(model: PreviewData.microphone(.granted)).frame(width: 540, height: 360)
}

#Preview("Accessibility") {
    AccessibilityStepView(model: AccessibilityViewModel(isTrusted: false)).frame(width: 540, height: 380)
}

#Preview("Speech model") {
    SpeechModelStepView(model: PreviewData.speech(PreviewData.downloading)).frame(width: 540, height: 380)
}

#Preview("Claude: signing in") {
    ClaudeStepView(model: PreviewData.claude(PreviewData.signingIn)).frame(width: 540, height: 420)
}

#Preview("Hotkeys") {
    HotkeysStepView(hotkeys: HotkeysViewModel()).frame(width: 540, height: 360)
}

#Preview("Try it") {
    OnboardingView(model: PreviewData.onboarding(at: .tryIt))
}
