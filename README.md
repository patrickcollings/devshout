# devshout

**Talk. devshout writes it down, tidies it up, and pastes it.**

devshout is a native macOS menu bar dictation app for the Abatable team. Press a hotkey and talk, even for a five-minute ramble of instructions to a coding agent. An accurate, cleaned-up transcript is then pasted into whatever app has focus, and left on the clipboard too.

- **Local, free transcription.** Parakeet TDT 0.6B v3 (FluidAudio, Neural Engine) or Whisper large-v3-turbo (WhisperKit). Audio never leaves your Mac.
- **Clean-up with your own Claude plan.** It runs through the Claude Code CLI (`claude -p`), and only text is sent.
- **Modes:** Raw, Tidy (fix terms and punctuation, keep your words) and Structure (a ramble becomes clear, ordered instructions for an agent). Each has its own hotkey and can be set as an app's default.
- **A team glossary** so the jargon comes out right: CORSIA, NDC, My Supply, proponent, people's names, AB-1234.
- **History** of every recording, with raw and cleaned text, re-runs and "Add correction to glossary".

## Status

**Planning.** Nothing is built yet. Read [`docs/PLAN.md`](docs/PLAN.md) for the architecture, UX, phases, testing strategy, risks and open questions.

## Requirements (planned)

- macOS 14 Sonoma or later, Apple Silicon
- [Claude Code](https://code.claude.com/docs/en/setup) and a Claude Pro, Max, Team or Enterprise plan for Tidy and Structure (Raw works without it)

## Credits

[cjpais/Handy](https://github.com/cjpais/Handy) (MIT) is a design reference. devshout is written from scratch.
