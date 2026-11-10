// Settings → General and Settings → Modes.
//
// Unsure on macOS (not compiled here): `List(selection:)` with an optional single-value binding for the mode list.

import DevshoutCore
import SwiftUI

// MARK: - General

struct GeneralSettingsTab: View {
    @ObservedObject var model: GeneralSettingsViewModel
    @ObservedObject var hotkeys: HotkeysViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Launch devshout at login", isOn: $model.preferences.launchAtLogin)
            }

            Section("Dictation") {
                LabeledContent("Dictation hotkey") {
                    HotkeyField(hotkeys: hotkeys, slot: .appDefault)
                }
                Picker("Hotkey behaviour", selection: $model.preferences.hotkeyBehaviour) {
                    ForEach(GeneralPreferences.HotkeyBehaviour.allCases) { behaviour in
                        Text(behaviour.title).tag(behaviour)
                    }
                }
                Toggle("Play start and stop sounds", isOn: $model.preferences.playsSounds)
                Toggle("Show the live transcript under the recording pill", isOn: $model.preferences.showsLivePreview)
            }

            Section {
                Picker("Paste method", selection: $model.preferences.pasteMethod) {
                    ForEach(GeneralPreferences.PasteMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
            } footer: {
                Text("The text is always left on the clipboard too. If an app ignores ⌘V, try typing via Accessibility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Set-up guide") {
                    Button("Show Onboarding Again…") { model.reopenOnboarding() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.width, height: 440)
    }
}

// MARK: - Modes

struct ModesSettingsTab: View {
    @ObservedObject var model: ModesSettingsViewModel
    @ObservedObject var hotkeys: HotkeysViewModel

    private var selection: Binding<ModeID?> {
        Binding(get: { model.selectedMode },
                set: { if let mode = $0 { model.selectedMode = mode } })
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: selection) {
                ForEach(ModeID.allCases, id: \.self) { mode in
                    Label {
                        Text(mode.displayName)
                    } icon: {
                        Image(systemName: mode.symbolName).foregroundStyle(mode.tint)
                    }
                    .tag(mode)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 160)

            Divider()

            ModeDetailForm(model: model, hotkeys: hotkeys, mode: model.selectedMode)
                .id(model.selectedMode)
        }
        .frame(width: SettingsLayout.width, height: 500)
    }
}

private struct ModeDetailForm: View {
    @ObservedObject var model: ModesSettingsViewModel
    @ObservedObject var hotkeys: HotkeysViewModel
    let mode: ModeID
    @State private var showsInstructions = false

    private var hotkeySlot: HotkeySlot? { HotkeySlot.allCases.first { $0.mode == mode } }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    ModeChip(mode: mode)
                    Text(mode.summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let slot = hotkeySlot {
                    LabeledContent("Hotkey") { HotkeyField(hotkeys: hotkeys, slot: slot) }
                }
            }

            if mode.usesClaude {
                claudeSection
                instructionsSection
            } else {
                Section {
                    Text("Raw pastes exactly what was transcribed, with your glossary's known mishearings fixed. Claude is never used, so it is instant and works offline.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var claudeSection: some View {
        let config = model.config(for: mode)
        let isCustomModel = ClaudeModelOption(alias: config.claudeModel) == nil && !config.claudeModel.isEmpty
        return Section {
            Picker("Claude model", selection: model.modelBinding(for: mode)) {
                ForEach(ClaudeModelOption.allCases) { option in
                    Text("\(option.title): \(option.detail)").tag(option.rawValue)
                }
                if isCustomModel {
                    Divider()
                    Text(config.claudeModel).tag(config.claudeModel)
                }
            }
            LabeledContent("Timeout") {
                Stepper(value: model.timeoutBinding(for: mode), in: ModesSettingsViewModel.timeoutRange,
                        step: ModesSettingsViewModel.timeoutStep) {
                    Text("\(Int(config.timeout)) s").monospacedDigit()
                }
            }
        } header: {
            Text("Claude")
        } footer: {
            Text("If Claude takes longer than this, devshout pastes the raw text instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var instructionsSection: some View {
        Section {
            DisclosureGroup("Advanced: edit instructions", isExpanded: $showsInstructions) {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: model.instructionsBinding(for: mode))
                        .font(.system(.callout, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(height: 150)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                    HStack {
                        Text(model.hasCustomInstructions(for: mode)
                             ? "Edited. The glossary and the safety rules are always added."
                             : "The built-in instructions. The glossary and the safety rules are always added.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset to Default") { model.resetInstructions(for: mode) }
                            .disabled(!model.hasCustomInstructions(for: mode))
                    }
                }
                .padding(.top, 6)
            }
        }
    }
}

#Preview("General") {
    GeneralSettingsTab(model: GeneralSettingsViewModel(), hotkeys: HotkeysViewModel())
}

#Preview("Modes") {
    ModesSettingsTab(model: ModesSettingsViewModel(defaultInstructions: PreviewData.defaultInstructions),
                     hotkeys: HotkeysViewModel())
}
