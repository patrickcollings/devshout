# devshout: notes for coding agents

devshout is a native macOS menu bar dictation app, for Apple silicon Macs on macOS 14+ (developed on an M1 Pro). Press a hotkey and talk. Local speech-to-text runs (Parakeet via FluidAudio, or Whisper via WhisperKit), then optional clean-up through the Claude Code CLI (`claude -p`) on the user's own Claude subscription. The result is pasted into the focused app and left on the clipboard.

**Read `docs/PLAN.md` first. Its §0 lists the decisions that override the rest of it.**

## Layout

| Path | What | Builds on |
|---|---|---|
| `Core/` | Swift package `DevshoutCore`: all pure logic (chunk planning, stitching, prompts, Claude invocation, glossary, pipeline state machine, settings, history, bench metrics) | **Linux + macOS** (Foundation only) |
| `Core/Sources/DevshoutCore/Foundation/` | Shared models + protocols (the seams between modules) | |
| `Mac/` | Swift package `DevshoutMac` (audio, engines, hotkeys, paste, permissions, Keychain, PTY) + `devshout-cli` (spike/bench tool) | macOS only |
| `App/` + `project.yml` | SwiftUI app target, generated with XcodeGen | macOS only |
| `bench/` | Benchmark corpus (jargon sentences, ramble outline, sample glossary) and results | |
| `scripts/` | Helper scripts (e.g. `fake-claude.sh` for tests) | |

## Commands

```bash
swift test --package-path Core               # Core tests (works on Linux; run these before every push)
swift build --package-path Mac               # macOS only
swift run --package-path Mac devshout-cli --help
scripts/build-app.sh                         # builds and signs the app; prints the .app path (build/ is git-ignored)
open "$(scripts/build-app.sh)"               # build and launch
swift scripts/make-app-icon.swift            # redraws the app icon PNGs in App/Resources (the artwork lives in the script)
scripts/make-release.sh [--publish]           # Release build → build/devshout.zip; --publish makes the GitHub release install.sh downloads
./install.sh                                 # what users run: installs the latest release into /Applications (INSTALL.md)
```

CI:
- `.github/workflows/core.yml` runs Core tests on Linux for PRs touching `Core/`.
- `.github/workflows/macos.yml` is **manual only** (`gh workflow run macos.yml --ref <branch>`). macOS minutes count 10× against a small free allowance, so **don't trigger it from feature work.** Build and test locally instead.

## Building and running locally

- **Toolchain:** Xcode 26 in `/Applications` (Swift 6.3). If `xcode-select` points at the Command Line Tools, they can't build this (no Swift Testing, no SwiftUI macros, no `xcodebuild`). `scripts/build-app.sh` handles it; for `swift` commands run `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` first. XcodeGen comes from Homebrew.
- **Keychain prompts:** without an Apple Developer team ID, macOS ties the token's Keychain item to the build's code hash, so each new build asks once for permission to read it. The app reads the Keychain once per launch (`CachedCredentialStore`) to keep that to a single prompt. Don't add further direct `KeychainCredentialStore().load()` calls in the app.
- **Signing:** the script re-signs the app with the self-signed `devshout-dev` certificate in the login keychain. That keeps the Microphone and Accessibility grants across rebuilds; an ad-hoc build is a new app to macOS each time. To recreate the certificate: Keychain Access → Certificate Assistant → Create a Certificate, name `devshout-dev`, Self-Signed Root, Code Signing.
- **State outside the repo:** `~/Library/Application Support/devshout/` (models, recordings, `settings.json`, `glossary.md`, Claude's empty config folder) and the Claude token in the Keychain. Don't touch anything else outside the repo without asking the user.
- **First model load is slow, once.** Core ML converts each model for the Neural Engine the first time an app loads it: about 10–20 minutes for Whisper, seconds for Parakeet. Rebuilding does not repeat it, but quitting the app mid-way restarts it, so check before `pkill`.
- **Only one copy of the app can run** (global hotkeys, shared state). Quit it (`pkill -x devshout`) before launching a new build, and never while the user is mid-dictation.
- **Look at UI changes before calling them done.** List devshout's windows with `CGWindowListCopyWindowInfo` and capture one with `screencapture -x -o -l <window id> <file>`. Capture only devshout's windows. To land on a Settings tab at launch: `open "$(scripts/build-app.sh)" --args -openSettingsTab history` (any `SettingsTab` name). Add `-openCalibration YES` for the calibration window. **Always add `-skipClaudeToken YES` to these launches**: the Claude token's Keychain item is tied to the exact build, so a fresh build reading it shows the user a Keychain password prompt. With the flag the app never touches the Keychain and shows Claude as not connected. Relaunch without it when you are done, and tell the user to expect one prompt ("Always Allow").
- **Speech without a microphone:** `say -o file.wav --data-format=LEI16@16000 "…"` then `devshout-cli transcribe file.wav --engine parakeet|whisper --glossary bench/glossary.sample.md --chunks`. `devshout-cli calibrate <folder> --glossary …` runs the app's voice calibration analysis on a folder of such files (`--help` shows how). `devshout-cli dictate-file file.wav --engine parakeet --realtime --compare` plays a file into the app's own `DictationSession` at the pace of a microphone (the other commands use `SpikeTranscriber`) and reports the wait between stop and the text, live against transcribing after stop.

## Rules

- **Core must stay Linux-buildable.** No AppKit, AVFoundation, Security, CoreML, Combine or os.log in `Core/`. Use Foundation, and Swift Regex or `NSRegularExpression`.
- Core uses the Swift 6 language mode (strict concurrency). `Mac/` and `App/` use Swift 5 mode to keep the AppKit/AVFoundation glue simple, but still mark types `Sendable` where they cross actors.
- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`). Fixtures go in `Core/Tests/DevshoutCoreTests/Fixtures/` (loaded via `Bundle.module`).
- Change a protocol in `Foundation/` only together with every implementation of it.
- **British English** everywhere: clean-up output and all UI copy.
- Claude auth: a `claude setup-token` token kept in the Keychain and passed as `CLAUDE_CODE_OAUTH_TOKEN`. **Never add an API-key option.** Never use `--bare` (it ignores OAuth tokens).
- Clipboard: paste with ⌘V and leave the text on the clipboard. **Never restore the previous clipboard.**
- Audio is written to disk before anything else touches it. Audio never leaves the Mac.
- Keep dependencies to the ones in `Mac/Package.swift` unless there is a strong reason.

## Conventions

- Follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/): clear names at the call site, `lowerCamelCase`, no abbreviations, doc comments (`///`) that say why, not what.
- **App structure:** views are dumb and read `ObservableObject` view models (`App/Devshout/UI/ViewModels/`); each view model has an `Actions` struct of closures that `App/Devshout/Wiring/` fills in. UI wording lives in `UI/Support/Presentation.swift`, not in views.
- **Windows are AppKit windows** hosting SwiftUI (`OnboardingWindowController`, `SettingsWindowController`). Don't use SwiftUI `Window`/`Settings` scenes or `TabView` for app chrome: in a menu bar (LSUIElement) app they can't be opened reliably, and a hidden helper window crashed the app at launch.
- **Don't rely on `onAppear`/`onDisappear` being balanced** for anything that holds a resource (the level meter keeps the microphone open). Make start/stop idempotent per owner and stop from the window controller's `windowWillClose`.
- **Never start work the user can't see or cancel.** A dictation is refused while the model isn't ready, and the pill always has a way out.
- Every change to `Core/` comes with tests. A bug found by running the app gets a test where one is possible.
- One topic per commit, with a message that says what was wrong and why the change fixes it. Work on a branch, open a PR, merge to `main` once Core tests pass and the app builds.
