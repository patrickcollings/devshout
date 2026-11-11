# App/Devshout/UI

The v0.1 SwiftUI screens (PLAN §7.1–§7.4 as amended by §0). Views are dumb: they show state from `@MainActor`
`ObservableObject` view models and call closures that the wiring step supplies. Nothing here imports DevshoutMac.

## Wiring in five steps

1. Build every view model once: `let models = DevshoutViewModels(microphone: …, claude: …, …)` (anything left out
   gets defaults with no-op actions). Shared models (`microphone`, `accessibility`, `speech`, `claude`, `hotkeys`)
   are the same instances in onboarding, Settings and the menu.
2. Give each model its `Actions` (closures) and keep its `@Published` state current from the real modules.
   To set a user-editable value from outside without it calling back, wrap it: `models.speech.sync { … }`.
3. Scenes:
   ```swift
   MenuBarExtra { MenuBarContent(model: models.menuBar) } label: { MenuBarLabel(model: models.menuBar) }
   ```
   Onboarding and Settings are AppKit windows (`OnboardingWindowController`, `SettingsWindowController`) hosting
   `OnboardingView` and `SettingsView`: a menu bar app can't reliably open SwiftUI `Window`/`Settings` scenes.
4. The overlay: `let panel = OverlayPanel(model: models.pill)`; `models.pill.begin(mode:)` + `panel.present()`
   when recording starts; set `models.pill.phase` as the pipeline moves; `panel.dismiss(after: 1.2)` when done.
   Feed `models.microphone.level.push(_:)` (0…1, ~25 Hz) during recording and while a meter is showing.
5. Reopening onboarding ("Set Up devshout…", "Show Onboarding Again…"): call `models.onboarding.restart()` before
   showing the window. `OnboardingView` starts and stops its step hooks (e.g. the level meter) on appear/disappear,
   so closing the window never leaves the microphone running.
6. Hotkey recorders: `models.hotkeys.recorder = { slot in AnyView(KeyboardShortcuts.Recorder(for: …)) }`, and keep
   `models.hotkeys.hotkeys` current for display.

## Files

| Folder | What |
|---|---|
| `ViewModels/UIState.swift` | Plain state enums/structs (Foundation + DevshoutCore only) |
| `ViewModels/*ViewModels.swift` | The view models and their `Actions` |
| `ViewModels/PreviewData.swift` | Sample models for `#Preview`s |
| `Support/Presentation.swift` | All status wording (Foundation only) |
| `Components/` | Keycaps, level meter, waveform, status label, mode chip, open panels, visual effect |
| `MenuBar/` | Menu, icon, Settings-opening workaround |
| `Onboarding/` | The seven-step onboarding window |
| `Calibration/` | The "Calibrate Your Voice" window: introduction, script, analysis, results (`CalibrationViewModel`; wording in `CalibrationCopy`) |
| `Settings/` | The seven Settings tabs |
| `Shared/` | Claude install / sign-in and speech model views used by onboarding and Settings |
| `Overlay/` | `RecordingPill` and `OverlayPanel` |

`UIState.swift`, `Presentation.swift` and the view models were type-checked on Linux (the view models against
stub Combine/SwiftUI modules). The views themselves have not been compiled yet.
