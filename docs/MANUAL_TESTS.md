# Manual tests: v0.1

The checklist for Patrick's Mac (MacBook Pro M1 Pro, macOS 14+), adapted from PLAN §10.4 to what v0.1 does.
CI can't test any of this: there is no microphone, Neural Engine, Accessibility or Claude subscription on the runners.

Tick what works, and note anything odd next to the item (timings especially). Getting the app is in the README's
"First run" section.

**What v0.1 does:** menu bar app, onboarding, ⌥Space (and the other mode hotkeys) to dictate, tap to toggle or hold
to talk, Esc to cancel, the whole recording transcribed after you stop (Parakeet or Whisper), glossary fixes, Tidy or
Structure through `claude -p` with a raw fallback, paste with ⌘V and leave the text on the clipboard, a recording
pill, history on disk (no History window yet), Settings.

**Not in v0.1 (don't test):** transcribing while recording and the live transcript line, the History window, re-runs,
"Add correction", Claude pre-warm, team glossary sync, DMG/updates.

Useful places:
- App data: `~/Library/Application Support/devshout/` (`settings.json`, `glossary.md`, `Recordings/YYYY/MM/<id>/`
  with `audio.wav` and `record.json`, `Models/`, `claude/`, `claude-cwd/`).
- Logs: Console.app, filter on `devshout` (subsystem `com.patrickcollings.devshout`).

## Install and first launch

- [ ] Download the `devshout-<sha>` artefact, unzip, move `devshout.app` to /Applications, open it: Gatekeeper blocks
      it → System Settings → Privacy & Security → **Open Anyway** works (or `xattr -dr com.apple.quarantine
      /Applications/devshout.app`)
- [ ] No Dock icon; a waveform icon appears in the menu bar
- [ ] The onboarding window opens by itself on first launch, in front of other apps
- [ ] Quit and reopen before finishing onboarding: it opens again. After **Done** it doesn't
- [ ] Menu → **Set Up devshout…** and Settings → General → **Show Onboarding Again…** reopen it at step 1

## Onboarding

- [ ] **Microphone:** "Allow Microphone" shows the system prompt; after allowing, the level meter moves when you
      talk, and the step moves on by itself
- [ ] Deny the mic (or turn it off in System Settings): the step offers "Open System Settings", and the menu shows
      "Microphone access needed" with the attention icon
- [ ] **Accessibility:** the button adds devshout to the list and opens the right pane; switching it on is picked up
      within about a second without restarting (✓ and auto-advance)
- [ ] If the toggle is on but devshout still isn't trusted (a new build: see the README), the "remove and re-add"
      hint appears and "Show devshout in Finder" works
- [ ] **Speech model:** pick Parakeet, Download: progress, size, speed and time left show; "Continue While It
      Downloads" works and the download carries on (watch the menu's status line)
- [ ] **Claude**, not installed: "Install for me" shows the installer's log and ends with "Claude Code 2.x" found;
      "Open in Terminal" also works
- [ ] **Claude**, installed: found (also when it's only in `~/.local/bin`, or only via Homebrew, launched from
      Finder); **Connect Claude** opens the browser; after approving, ✓ Connected and the test runs by itself
      ("Tidy works, 2.1 s")
- [ ] If the browser shows a code, the code field takes it and connecting finishes
- [ ] "Use Raw Mode Only for Now" skips the step, and the menu doesn't nag about Claude afterwards
- [ ] **Hotkeys:** the recorders show ⌥Space / ⌥⇧Space / ⌥⌘Space; changing one works straight away
- [ ] **Try it:** with the onboarding window in front, press ⌥Space, say "Check the CORSIA flag on AB-1234 in My
      Supply", press ⌥Space: the text lands in the box, with Raw and Tidied side by side; the pill says "Pasted into
      the Try it box"

## Dictation

- [ ] **Toggle:** tap ⌥Space, talk 10 s, tap → pasted (Tidy) in: TextEdit, Notes, Slack, Chrome (a Google Doc),
      VS Code editor, VS Code terminal, Terminal, iTerm/Ghostty, Claude Code TUI, a Linear comment
- [ ] **Hold to talk:** hold ⌥Space, talk, let go → pasted
- [ ] Settings → General → Hotkey behaviour "Toggle only" and "Hold to talk only" behave as named
- [ ] The pill: red dot, mode chip, waveform that follows your voice, timer; hover shows Stop and Cancel, and both work
- [ ] After stopping: "Transcribing…", then "Tidying with Haiku…" with **Paste raw now**; pressing it pastes the raw
      text straight away ("Pasted raw: You chose to paste the raw text")
- [ ] Done: "✓ Pasted into <app>", fades after about a second
- [ ] **Esc** while recording cancels (cancel sound, pill disappears); the folder in `Recordings/` has `audio.wav`
      and a `record.json` with `"status" : "cancelled"`
- [ ] Esc does nothing special when not recording (it still works normally in other apps)
- [ ] Press ⌥Space again while it's still transcribing or tidying: nothing new starts, and the pill says "Still
      finishing the last dictation"
- [ ] The text is still on the clipboard after the paste; the previous clipboard is **not** restored
- [ ] Password field focused (e.g. a login page) → no keystroke, the pill says "Copied: press ⌘V" with the reason
- [ ] No text field focused (e.g. Finder) → "Copied: press ⌘V"
- [ ] Focus another app during clean-up → it pastes into the new app, and the pill names it
- [ ] A non-US layout (Dvorak, or another you have) → ⌘V still pastes
- [ ] Mode hotkeys: ⌥⇧Space gives Structure (Markdown brief), ⌥⌘Space gives Raw (no Claude call, fastest). If
      macOS keeps ⌥⌘Space for Finder search, change it in Settings → Modes
- [ ] Pressing another mode's hotkey while recording switches the mode (the chip changes) and it finishes in that mode
- [ ] Settings → Apps: add Terminal → Structure and Slack → Tidy; ⌥Space in each uses that mode; "Add Suggested Apps"
      and adding from running apps / "Choose from Applications…" work
- [ ] Menu → Default Mode changes the mode ⌥Space uses elsewhere
- [ ] Menu → Start Dictation / Stop Dictation / Cancel Dictation work like the hotkey
- [ ] **A 5-minute ramble in Structure:** note the time from stop to paste (Parakeet), and check the brief keeps every
      point
- [ ] Silence only (start, say nothing, stop) → "No speech detected"; nothing is pasted, and history keeps the audio
- [ ] Both engines: switch to Whisper in Settings → Transcription (download it), dictate → `record.json` says
      `whisper-large-v3-turbo`; switch back

## Claude failures (the raw text must always be pasted)

- [ ] Wi-Fi off during clean-up → raw text pasted within the mode's timeout (20 s for Tidy), pill says why
- [ ] Settings → Modes → Tidy timeout 5 s and a long dictation → "Pasted raw: Claude timed out after 5 s"
- [ ] Settings → Claude → Disconnect → ✗ Not connected; Tidy now pastes raw with "Connect Claude to tidy"; the
      terminal `claude` sign-in is unaffected (`claude -p hi` in Terminal still works)
- [ ] Paste a token: run `claude setup-token` in Terminal, paste the token in "Paste a token instead" → Connected
- [ ] A bad token pasted (edit one character) → the next Tidy pastes raw, Claude shows "Needs reconnecting", the
      menu bar icon shows attention; **Reconnect…** fixes it
- [ ] Test Connection shows the round-trip time
- [ ] Settings → Claude: picking a `claude` binary by hand ("Change…" next to Location, or "Choose…" when not found) works

## Permissions while running

- [ ] Revoke Accessibility while running → the menu bar shows attention within a second or two, and dictation falls
      back to "Copied: press ⌘V"
- [ ] Revoke the microphone → ⌥Space shows "Microphone access is off" in the pill
- [ ] Delete the model (Settings → Transcription → Delete) → the menu shows attention and "Speech model not
      downloaded"; ⌥Space says "No speech model yet"; Download fetches it again
- [ ] The model download survives a Wi-Fi drop (fails with a message; "Try Again" resumes or restarts it)

## Settings, history and glossary

- [ ] Settings opens from the menu (⌘,) in front of other apps, and the Dock icon goes away when it closes
- [ ] Settings → Transcription: the input picker lists your devices; AirPods work as input (lower quality); the level
      meter follows the chosen device
- [ ] Settings → Glossary: paste the real glossary, Save; the counts update; a mishearing ("core sea") is fixed to
      CORSIA in the next dictation, in Raw mode too
- [ ] With Whisper, a glossary term Whisper usually gets wrong comes out right more often (rough check)
- [ ] Settings → Privacy: recording count and size; **Show in Finder** opens the devshout folder; **Delete All
      History** empties `Recordings/`; audio retention 7 days applies at the next launch
- [ ] Force-quit (Activity Monitor) while recording → on relaunch the folder gets a `record.json` with
      `"status" : "recovered"` and the audio is intact
- [ ] Launch at login: switch on, log out and in → devshout is in the menu bar

## Polish

- [ ] Light and dark mode; the menu bar icon follows the menu bar's appearance
- [ ] The pill shows over full-screen apps and on every Space, on the screen with the mouse
- [ ] Idle CPU ≈ 0% (Activity Monitor); memory with the Parakeet model loaded: ______ MB
- [ ] Note any British English slips in the UI or the tidied text
