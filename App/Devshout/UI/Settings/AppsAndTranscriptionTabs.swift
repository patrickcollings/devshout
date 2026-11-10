// Settings → Apps (per-app default modes) and Settings → Transcription (engine, models, microphone).
//
// Unsure on macOS (not compiled here):
// - `Table` with a `Picker` in a cell (standard macOS 12+ API; cells are kept as small separate views so the
//   column builder type-checks quickly).
// - `.menuStyle(.button)` + `.buttonStyle(.borderless)` for the "+" menu under the table (macOS 13+).
// - `ContentUnavailableView` (macOS 14+).

import DevshoutCore
import SwiftUI

// MARK: - Apps

struct AppsSettingsTab: View {
    @ObservedObject var model: AppsSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("When you use the default dictation hotkey, devshout uses the app's mode here. Other apps use the default mode from the menu.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                if model.rules.isEmpty {
                    ContentUnavailableView {
                        Label("No apps yet", systemImage: "square.grid.2x2")
                    } description: {
                        Text("Give terminals and editors Structure, and chat apps Tidy.")
                    } actions: {
                        Button("Add Suggested Apps") { model.addSuggestions() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    AppRulesTable(model: model)
                }
                Divider()
                AppsBottomBar(model: model)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
        .padding(20)
        .frame(width: SettingsLayout.width, height: 420)
    }
}

private struct AppRulesTable: View {
    @ObservedObject var model: AppsSettingsViewModel

    var body: some View {
        Table(model.rules, selection: $model.selection) {
            TableColumn("App") { rule in
                AppNameCell(rule: rule)
            }
            TableColumn("Mode") { rule in
                AppModeCell(model: model, bundleID: rule.bundleID)
            }
            .width(160)
        }
        .onDeleteCommand { model.removeSelected() }
    }
}

private struct AppNameCell: View {
    let rule: AppModeRule

    var body: some View {
        HStack(spacing: 8) {
            AppIconView(bundleID: rule.bundleID)
            Text(rule.name)
        }
    }
}

private struct AppModeCell: View {
    @ObservedObject var model: AppsSettingsViewModel
    let bundleID: String

    var body: some View {
        Picker("Mode", selection: model.modeBinding(for: bundleID)) {
            ForEach(ModeID.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .labelsHidden()
    }
}

private struct AppsBottomBar: View {
    @ObservedObject var model: AppsSettingsViewModel

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                let running = model.addableRunningApps()
                if !running.isEmpty {
                    Section("Running apps") {
                        ForEach(running) { app in
                            Button(app.name) { model.add(app) }
                        }
                    }
                }
                Button("Choose from Applications…") {
                    if let url = OpenPanels.chooseApplication() { model.addApp(at: url) }
                }
                if !model.missingSuggestions.isEmpty {
                    Divider()
                    Button("Add Suggested Apps") { model.addSuggestions() }
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 22, height: 18)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add an app")

            Button {
                model.removeSelected()
            } label: {
                Image(systemName: "minus")
                    .frame(width: 22, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(model.selection.isEmpty)
            .help("Remove the selected apps")

            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

// MARK: - Transcription

struct TranscriptionSettingsTab: View {
    @ObservedObject var speech: SpeechEngineViewModel
    @ObservedObject var microphone: MicrophoneViewModel

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $speech.selectedEngine) {
                    ForEach(EngineID.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                let info = speech.info(for: speech.selectedEngine)
                Text("\(info.summary) \(info.detail)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !speech.selectedStatus.isReady && !speech.selectedStatus.isBusy {
                    StatusLabel(text: "Download this model to use it.", tone: .warning)
                }
            } header: {
                Text("Speech-to-text")
            }

            Section("Models") {
                ForEach(EngineID.allCases, id: \.self) { engine in
                    ModelRow(model: speech, engine: engine)
                }
            }

            Section("Microphone") {
                if microphone.permission == .granted {
                    InputDevicePicker(model: microphone)
                    LabeledContent("Input level") {
                        LevelMeter(level: microphone.level).frame(width: 200)
                    }
                } else {
                    HStack {
                        StatusLabel(text: "Microphone access is needed", tone: .critical)
                        Spacer()
                        if microphone.permission == .notDetermined {
                            Button("Allow…") { microphone.requestAccess() }
                        } else {
                            Button("Open System Settings") { microphone.openPrivacySettings() }
                        }
                    }
                }
                LabeledContent("Language", value: "English")
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.width, height: 470)
        .onAppear { microphone.startLevelMonitoring() }
        .onDisappear { microphone.stopLevelMonitoring() }
    }
}

private struct ModelRow: View {
    @ObservedObject var model: SpeechEngineViewModel
    let engine: EngineID

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(engine.displayName)
                    if model.selectedEngine == engine {
                        Text("In use")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .foregroundStyle(Color.accentColor)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
                ModelProgressView(status: model.status(for: engine), since: model.preparingSince[engine])
                    .font(.callout)
            }
            Spacer()
            ModelActionButtons(model: model, engine: engine)
        }
        .padding(.vertical, 2)
    }
}

#Preview("Apps") {
    AppsSettingsTab(model: PreviewData.models().apps)
}

#Preview("Apps: empty") {
    AppsSettingsTab(model: AppsSettingsViewModel())
}

#Preview("Transcription") {
    TranscriptionSettingsTab(speech: PreviewData.speech(PreviewData.downloading), microphone: PreviewData.microphone())
}
