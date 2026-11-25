# devshout

**Talk. devshout writes it down, tidies it up, and pastes it.**

devshout is a native macOS menu bar dictation app for developers. Press a hotkey and talk, even for a five-minute ramble of instructions to a coding agent. An accurate, cleaned-up transcript is then pasted into whatever app has focus, and left on the clipboard too.

- **Local, free transcription.** Parakeet TDT 0.6B v3 (FluidAudio, Neural Engine) or Whisper large-v3-turbo (WhisperKit). Audio never leaves your Mac.
- **Clean-up with your own Claude plan.** It runs through the Claude Code CLI (`claude -p`), and only text is sent.
- **Modes:** Raw, Tidy (fix terms and punctuation, keep your words) and Structure (a ramble becomes clear, ordered instructions for an agent). Each has its own hotkey and can be set as an app's default.
- **A team glossary** so the jargon comes out right: CORSIA, NDC, My Supply, proponent, people's names, AB-1234.
- **History** of every recording, with raw and cleaned text, re-runs and "Add correction to glossary".

## Status

**v0.1, for local testing.** Menu bar app, onboarding, hotkeys (tap to toggle, hold to talk, Esc to
cancel), local transcription after you stop, Tidy and Structure through Claude with a raw fallback, paste, a
recording pill, and Settings with a History tab. The plan is in
[`docs/PLAN.md`](docs/PLAN.md) and the test checklist in [`docs/MANUAL_TESTS.md`](docs/MANUAL_TESTS.md).

## Install

You need an Apple silicon Mac on macOS 14 or later. Xcode is not needed.

```bash
curl -fsSL https://raw.githubusercontent.com/patrickcollings/devshout/main/install.sh | bash
```

That downloads the latest release into `/Applications` and opens it. Run it again to update.

**Or ask Claude Code to do it:** point it at this repo and say "install devshout". The steps for an agent are in
[`INSTALL.md`](INSTALL.md).

**What you still do by hand, once.** The set-up window walks you through it:

1. Allow the **Microphone** (a macOS prompt).
2. Allow **Accessibility** in System Settings, so devshout can paste for you. macOS does not let a script or an
   agent grant these two.
3. Wait for the speech model to download.
4. Connect your Claude plan (for Tidy and Structure; Raw works without it).

Then press **⌥Space** to dictate.

**After an update** macOS may stop pasting until you re-add devshout under **System Settings → Privacy &
Security → Accessibility** (remove it with **−**, add it again with **+**), and may ask once for your login
password to read the Claude token ("Always Allow").

**Build it yourself instead:** clone the repo, `brew install xcodegen`, then `scripts/install-from-source.sh`.
Needs Xcode 26. `scripts/build-app.sh` signs with a self-signed `devshout-dev` certificate when your login keychain
has one, which keeps the permissions across rebuilds (`CLAUDE.md` says how to make it).

## Requirements

- macOS 14 Sonoma or later, Apple Silicon
- [Claude Code](https://code.claude.com/docs/en/setup) and a Claude Pro, Max, Team or Enterprise plan for Tidy and Structure (Raw works without it)

## Credits

[cjpais/Handy](https://github.com/cjpais/Handy) (MIT) is a design reference. devshout is written from scratch.

## Licence

MIT. See [`LICENSE`](LICENSE).
