// The Settings window's content (PLAN §7.4 as amended by §0: no team glossary sync, no updates tab), hosted by
// `SettingsWindowController`. The window resizes to each tab's fixed frame.

import DevshoutCore
import SwiftUI

struct SettingsView: View {
    let models: DevshoutViewModels

    var body: some View {
        TabView {
            GeneralSettingsTab(model: models.general, hotkeys: models.hotkeys)
                .tabItem { Label("General", systemImage: "gearshape") }
            ModesSettingsTab(model: models.modes, hotkeys: models.hotkeys)
                .tabItem { Label("Modes", systemImage: "slider.horizontal.3") }
            AppsSettingsTab(model: models.apps)
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            TranscriptionSettingsTab(speech: models.speech, microphone: models.microphone)
                .tabItem { Label("Transcription", systemImage: "waveform") }
            ClaudeSettingsTab(model: models.claude)
                .tabItem { Label("Claude", systemImage: "sparkles") }
            GlossarySettingsTab(model: models.glossary)
                .tabItem { Label("Glossary", systemImage: "text.book.closed") }
            PrivacySettingsTab(model: models.privacy)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
    }
}

/// The width every tab uses, so the window doesn't jump sideways between tabs.
enum SettingsLayout {
    static let width: CGFloat = 600
}

#Preview("Settings") {
    SettingsView(models: PreviewData.models(account: PreviewData.expiringAccount))
}
