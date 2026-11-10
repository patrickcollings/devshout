# devshout

**Talk. devshout writes it down, tidies it up, and pastes it.**

devshout is a native macOS menu bar dictation app for the Abatable team. Press a hotkey and talk, even for a five-minute ramble of instructions to a coding agent. An accurate, cleaned-up transcript is then pasted into whatever app has focus, and left on the clipboard too.

- **Local, free transcription.** Parakeet TDT 0.6B v3 (FluidAudio, Neural Engine) or Whisper large-v3-turbo (WhisperKit). Audio never leaves your Mac.
- **Clean-up with your own Claude plan.** It runs through the Claude Code CLI (`claude -p`), and only text is sent.
- **Modes:** Raw, Tidy (fix terms and punctuation, keep your words) and Structure (a ramble becomes clear, ordered instructions for an agent). Each has its own hotkey and can be set as an app's default.
- **A team glossary** so the jargon comes out right: CORSIA, NDC, My Supply, proponent, people's names, AB-1234.
- **History** of every recording, with raw and cleaned text, re-runs and "Add correction to glossary".

## Status

**v0.1, for testing on Patrick's Mac.** Menu bar app, onboarding, hotkeys (tap to toggle, hold to talk, Esc to
cancel), local transcription after you stop, Tidy and Structure through Claude with a raw fallback, paste, a
recording pill, and Settings with a History tab. The plan is in
[`docs/PLAN.md`](docs/PLAN.md) and the test checklist in [`docs/MANUAL_TESTS.md`](docs/MANUAL_TESTS.md).

## First run

**Get the app**, either way:

- **From CI:** open the latest run of the *macOS build* workflow (Actions tab), download the `devshout-<sha>`
  artefact, unzip it, then unzip `devshout-app.zip` inside and move `devshout.app` to /Applications. The first time
  you open it macOS blocks it: go to **System Settings → Privacy & Security**, scroll to "devshout was blocked…" and
  click **Open Anyway**. Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/devshout.app`
- **Build it yourself:** `brew install xcodegen`, then `open "$(scripts/build-app.sh)"`. Needs Xcode 26.

Onboarding then walks you through the microphone, Accessibility, the speech model download, Claude and the hotkeys.
Press **⌥Space** to dictate.

**Permissions after a new build:** `scripts/build-app.sh` signs the app with a self-signed `devshout-dev`
certificate when your login keychain has one, so macOS keeps the Microphone and Accessibility grants across builds
(`CLAUDE.md` says how to make the certificate). Without it, or with a CI build, the app is ad-hoc signed and macOS
sees each new build as a different app: open **System Settings → Privacy & Security → Accessibility**, select
devshout, remove it with **−**, then add it again with **+**.

## Requirements

- macOS 14 Sonoma or later, Apple Silicon
- [Claude Code](https://code.claude.com/docs/en/setup) and a Claude Pro, Max, Team or Enterprise plan for Tidy and Structure (Raw works without it)

## Credits

[cjpais/Handy](https://github.com/cjpais/Handy) (MIT) is a design reference. devshout is written from scratch.
