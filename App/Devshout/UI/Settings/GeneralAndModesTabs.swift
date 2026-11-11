// Settings → General and Settings → Modes.
//
// Modes: a sidebar of the built-in modes and the user's own (add from a blank mode or a template, duplicate,
// delete, drag to reorder), and a form for the selected one. Not seen running when custom modes were added: check
// the screens listed in docs/MANUAL_TESTS.md ("Custom modes").

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
    /// The mode the delete confirmation is asking about.
    @State private var pendingDelete: ModeDescriptor?

    static let sidebarWidth: CGFloat = 180

    private var selection: Binding<ModeID?> {
        Binding(get: { model.selected.id },
                set: { if let mode = $0 { model.selectedMode = mode } })
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } })
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                modeList
                Divider()
                ModesBottomBar(model: model, onDelete: { pendingDelete = model.selected })
            }
            .frame(width: Self.sidebarWidth)

            Divider()

            Group {
                if model.customMode(model.selected.id) != nil {
                    CustomModeDetailForm(model: model, hotkeys: hotkeys, id: model.selected.id,
                                         onDelete: { pendingDelete = model.selected })
                } else {
                    ModeDetailForm(model: model, hotkeys: hotkeys, mode: model.selected)
                }
            }
            .id(model.selected.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: SettingsLayout.width, height: 500)
        .confirmationDialog(pendingDelete.map { ModesText.deleteTitle($0.name) } ?? "",
                            isPresented: isConfirmingDelete, presenting: pendingDelete) { mode in
            Button("Delete", role: .destructive) { model.delete(mode.id) }
        } message: { _ in
            Text(ModesText.deleteMessage)
        }
    }

    private var modeList: some View {
        List(selection: selection) {
            Section(ModesText.builtInSection) {
                ForEach(ModeDescriptor.builtIns) { mode in
                    ModeRow(mode: mode)
                        .tag(mode.id)
                        .contextMenu {
                            Button(ModesText.duplicate) { model.duplicate(mode.id) }
                                .disabled(!mode.usesClaude)
                        }
                }
            }
            if !model.customModes.isEmpty {
                Section(ModesText.customSection) {
                    ForEach(model.customModes) { mode in
                        ModeRow(mode: ModeDescriptor(mode))
                            .tag(mode.id)
                            .contextMenu {
                                Button(ModesText.duplicate) { model.duplicate(mode.id) }
                                Divider()
                                Button(ModesText.delete, role: .destructive) { pendingDelete = ModeDescriptor(mode) }
                            }
                    }
                    .onMove { source, destination in model.move(from: source, to: destination) }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct ModeRow: View {
    let mode: ModeDescriptor

    var body: some View {
        Label {
            Text(mode.name)
                .lineLimit(1)
                .truncationMode(.tail)
        } icon: {
            Image(systemName: mode.symbolName).foregroundStyle(mode.color)
        }
        .help(mode.name)
    }
}

/// Under the mode list: add (blank or from a template), duplicate and delete.
private struct ModesBottomBar: View {
    @ObservedObject var model: ModesSettingsViewModel
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                Button(ModesText.addBlank) { model.addBlank() }
                Section(ModesText.templatesSection) {
                    ForEach(model.templates) { template in
                        Button(template.name) { model.add(template) }
                    }
                }
                Divider()
                Button("\(ModesText.duplicate) “\(model.selected.name)”") { model.duplicate(model.selected.id) }
                    .disabled(!model.canDuplicateSelected)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 22, height: 18)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(ModesText.addHelp)
            .accessibilityLabel(ModesText.addHelp)

            Button {
                onDelete()
            } label: {
                Image(systemName: "minus")
                    .frame(width: 22, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(!model.canDeleteSelected)
            .help(model.canDeleteSelected ? ModesText.deleteHelp : ModesText.deleteBuiltInHelp)
            .accessibilityLabel(ModesText.deleteHelp)

            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

/// The form for Raw, Tidy and Structure.
private struct ModeDetailForm: View {
    @ObservedObject var model: ModesSettingsViewModel
    @ObservedObject var hotkeys: HotkeysViewModel
    let mode: ModeDescriptor
    @State private var showsInstructions = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    ModeChip(mode: mode)
                    Text(ModesText.summary(for: mode))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("Hotkey") { HotkeyField(hotkeys: hotkeys, slot: HotkeySlot(mode: mode.id)) }
            }

            if mode.usesClaude {
                ModeClaudeSection(model: model, mode: mode.id)
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

    private var instructionsSection: some View {
        Section {
            DisclosureGroup("Advanced: edit instructions", isExpanded: $showsInstructions) {
                VStack(alignment: .leading, spacing: 8) {
                    InstructionsEditor(text: model.instructionsBinding(for: mode.id), height: 150)
                    HStack {
                        Text(model.hasCustomInstructions(for: mode.id)
                             ? "Edited. The glossary and the safety rules are always added."
                             : "The built-in instructions. The glossary and the safety rules are always added.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset to Default") { model.resetInstructions(for: mode.id) }
                            .disabled(!model.hasCustomInstructions(for: mode.id))
                    }
                }
                .padding(.top, 6)
            }
        }
    }
}

/// The form for one of the user's modes: name, look, hotkey, Claude model, timeout and instructions.
private struct CustomModeDetailForm: View {
    @ObservedObject var model: ModesSettingsViewModel
    @ObservedObject var hotkeys: HotkeysViewModel
    let id: ModeID
    var onDelete: () -> Void

    var body: some View {
        let mode = model.modes.descriptor(for: id)
        let hasInstructions = model.customMode(id)?.hasInstructions ?? false
        Form {
            Section {
                // Stacked, not side by side as for the built-ins: a long name would leave the summary no room.
                VStack(alignment: .leading, spacing: 6) {
                    ModeChip(mode: mode)
                    Text(ModesText.summary(for: mode))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField(ModesText.namePlaceholder, text: model.nameBinding(for: id))
                Picker(ModesText.symbolLabel, selection: model.symbolBinding(for: id)) {
                    ForEach(ModeSymbol.allCases, id: \.self) { symbol in
                        Label(symbol.displayName, systemImage: symbol.symbolName).tag(symbol)
                    }
                }
                Picker(ModesText.colourLabel, selection: model.tintBinding(for: id)) {
                    ForEach(ModeTint.allCases, id: \.self) { tint in
                        Text(tint.displayName).tag(tint)
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    InstructionsEditor(text: model.customInstructionsBinding(for: id), height: 170)
                    if !hasInstructions {
                        StatusLabel(text: ModesText.noInstructions, tone: .warning)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text(ModesText.instructionsHeader)
            } footer: {
                Text(ModesText.instructionsFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ModeClaudeSection(model: model, mode: id)

            Section {
                LabeledContent("Hotkey") { HotkeyField(hotkeys: hotkeys, slot: .custom(id)) }
            } footer: {
                Text(ModesText.hotkeyFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    Button(ModesText.duplicate) { model.duplicate(id) }
                    Spacer()
                    Button("Delete Mode…", role: .destructive) { onDelete() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The Claude model and the timeout, for any mode that uses Claude.
private struct ModeClaudeSection: View {
    @ObservedObject var model: ModesSettingsViewModel
    let mode: ModeID

    var body: some View {
        let config = model.config(for: mode)
        let isCustomModel = ClaudeModelOption(alias: config.claudeModel) == nil && !config.claudeModel.isEmpty
        Section {
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
            Text(ModesText.customTimeoutFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A bordered multi-line editor for a mode's instructions.
private struct InstructionsEditor: View {
    @Binding var text: String
    let height: CGFloat

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.callout, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
    }
}

#Preview("General") {
    GeneralSettingsTab(model: GeneralSettingsViewModel(), hotkeys: HotkeysViewModel())
}

#Preview("Modes") {
    ModesSettingsTab(model: ModesSettingsViewModel(defaultInstructions: PreviewData.defaultInstructions),
                     hotkeys: HotkeysViewModel())
}

#Preview("Modes: a custom mode") {
    ModesSettingsTab(model: PreviewData.modes(selected: PreviewData.customModes[1].id), hotkeys: HotkeysViewModel())
}

#Preview("Modes: a long name") {
    ModesSettingsTab(model: PreviewData.modes(selected: PreviewData.customModes[0].id), hotkeys: HotkeysViewModel())
}

#Preview("Modes: a new blank mode") {
    let model = PreviewData.modes(selected: .tidy)
    model.addBlank()
    return ModesSettingsTab(model: model, hotkeys: HotkeysViewModel())
}
