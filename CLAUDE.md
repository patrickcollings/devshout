# devshout: notes for coding agents

devshout is a native macOS menu bar dictation app, built for one user (Patrick, MacBook Pro M1 Pro, macOS 14+). Press a hotkey and talk. Local speech-to-text runs (Parakeet via FluidAudio, or Whisper via WhisperKit), then optional clean-up through the Claude Code CLI (`claude -p`) on Patrick's own Claude subscription. The result is pasted into the focused app and left on the clipboard.

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
brew install xcodegen && xcodegen generate && open Devshout.xcodeproj   # the app (macOS)
```

CI:
- `.github/workflows/core.yml` runs Core tests on Linux for PRs touching `Core/`.
- `.github/workflows/macos.yml` is **manual only** (`gh workflow run macos.yml --ref <branch>`). macOS minutes count 10× against a small free allowance, so **don't trigger it from feature work.** The integrator runs it at integration points.

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
