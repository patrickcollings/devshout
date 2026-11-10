// The Settings window's content (PLAN §7.4 as amended by §0: no team glossary sync, no updates tab), hosted by
// `SettingsWindowController`. The window resizes to each tab's fixed frame.

import DevshoutCore
import SwiftUI

struct SettingsView: View {
    let models: DevshoutViewModels
    @State private var tab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $tab)
            Divider()
            StatusStrip(menuBar: models.menuBar, speech: models.speech)
            Divider()
            content
        }
        .frame(width: SettingsLayout.width)
        // A recording playing in History has its Stop button there: leaving the tab stops it.
        .onChange(of: tab) { _, shown in
            if shown != .history { models.history.stopPlayback() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general: GeneralSettingsTab(model: models.general, hotkeys: models.hotkeys)
        case .modes: ModesSettingsTab(model: models.modes, hotkeys: models.hotkeys)
        case .apps: AppsSettingsTab(model: models.apps)
        case .transcription: TranscriptionSettingsTab(speech: models.speech, microphone: models.microphone)
        case .claude: ClaudeSettingsTab(model: models.claude)
        case .glossary: GlossarySettingsTab(model: models.glossary)
        case .history: HistorySettingsTab(model: models.history)
        case .privacy: PrivacySettingsTab(model: models.privacy)
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, modes, apps, transcription, claude, glossary, history, privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .modes: "Modes"
        case .apps: "Apps"
        case .transcription: "Transcription"
        case .claude: "Claude"
        case .glossary: "Glossary"
        case .history: "History"
        case .privacy: "Privacy"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .modes: "slider.horizontal.3"
        case .apps: "square.grid.2x2"
        case .transcription: "waveform"
        case .claude: "sparkles"
        case .glossary: "text.book.closed"
        case .history: "clock.arrow.circlepath"
        case .privacy: "hand.raised"
        }
    }
}

/// The row of tabs across the top, in the style of a preferences toolbar. Drawn here rather than with `TabView`:
/// outside a `Settings` scene a TabView becomes a segmented control, which can't fit eight tabs in this width
/// and silently drops the ones that don't fit.
private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbolName)
                            .font(.system(size: 17))
                            .frame(height: 22)
                        Text(tab.title)
                            .font(.caption)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selection == tab ? Color.primary.opacity(0.08) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// The width every tab uses, so the window doesn't jump sideways between tabs.
enum SettingsLayout {
    static let width: CGFloat = 600
}

#Preview("Settings") {
    SettingsView(models: PreviewData.models(account: PreviewData.expiringAccount))
}
