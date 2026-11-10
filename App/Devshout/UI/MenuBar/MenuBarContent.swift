// The MenuBarExtra menu (PLAN §7.1) and its label. Use from the App scene as:
//
//     MenuBarExtra {
//         MenuBarContent(model: models.menuBar)
//     } label: {
//         MenuBarLabel(model: models.menuBar)
//     }
//     // .menuBarExtraStyle(.menu) is the default.
//
// "Settings…" calls MenuBarViewModel.Actions.openSettings, which by default posts `.devshoutOpenSettings` for
// `SettingsOpenerView` (see SettingsOpener.swift: opening Settings from a menu bar menu needs a workaround).
//
// Unsure on macOS (not compiled here):
// - Whether `.symbolEffect` animates inside a MenuBarExtra label (it is rendered into the status item image; if it
//   doesn't animate, the icon simply stays still).
// - A `Picker` inside the menu renders as a submenu with ✓ on the selected mode (standard SwiftUI menu behaviour).

import AppKit
import DevshoutCore
import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var model: MenuBarViewModel

    var body: some View {
        dictationButton

        if model.isRecording || model.isWorking {
            Button("Cancel Dictation") { model.cancelDictation() }
        }

        Divider()

        Picker(selection: $model.defaultMode) {
            ForEach(ModeID.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        } label: {
            Text("Default Mode")
        }

        Divider()

        ForEach(model.statusLines) { line in
            // Disabled buttons render as grey informational menu items with their icon.
            Button {} label: {
                Label(line.text, systemImage: line.symbolName)
            }
            .disabled(true)
        }

        Divider()

        Button("Settings…") { model.openSettings() }
        .keyboardShortcut(",", modifiers: .command)

        Button("Set Up devshout…") { model.openOnboarding() }

        Divider()

        Button("Quit devshout") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    @ViewBuilder
    private var dictationButton: some View {
        if let shortcut = model.dictationHotkey?.keyboardShortcut {
            Button(model.dictationTitle) { model.toggleDictation() }
                .keyboardShortcut(shortcut)
        } else {
            Button(model.dictationTitle) { model.toggleDictation() }
        }
    }
}

/// The menu bar icon. A template image, so it follows the menu bar's appearance.
struct MenuBarLabel: View {
    @ObservedObject var model: MenuBarViewModel

    var body: some View {
        MenuBarIconImage(state: model.iconState)
    }
}

struct MenuBarIconImage: View {
    let state: MenuBarIconState

    var body: some View {
        Image(systemName: state.symbolName)
            .symbolRenderingMode(.monochrome)
            .symbolEffect(.pulse, options: .repeating, isActive: state == .recording || state == .working)
            .accessibilityLabel(state.accessibilityLabel)
    }
}

#Preview("Menu") {
    VStack(alignment: .leading) {
        MenuBarContent(model: PreviewData.models(speechStatus: PreviewData.downloading).menuBar)
    }
    .frame(width: 260)
    .padding()
}

#Preview("Icon states") {
    HStack(spacing: 16) {
        ForEach(MenuBarIconState.allCases, id: \.self) { state in
            VStack {
                MenuBarIconImage(state: state).font(.title2)
                Text(state.rawValue).font(.caption)
            }
        }
    }
    .padding()
}
