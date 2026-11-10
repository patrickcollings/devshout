# Phase 0 benchmark: step by step

This folder holds the corpus for the Phase 0 spike (PLAN §9): ten jargon sentences and one five-minute ramble.
You record them once (about 20 minutes), run the same audio through superwhisper, write down what each recording
*should* say, and let `devshout-cli bench` score everything. The metrics:

| Metric | What it tells you |
|---|---|
| **WER** | Word error rate against your reference (case and punctuation ignored) |
| **Terms** | Of the glossary terms in the reference, how many are spelled exactly right (case-sensitive: `CORSIA`, `My Supply`, `AB-1234`) |
| **Points** | Ramble only: how many of the 8 outline points the final text covers (x/8) |
| **Timings** | Model load, transcribe, tail latency, Claude spawn → first byte, Claude total |

## What is in here

```
bench/
  sentences.md          the 10 sentences (s01–s10), one "- s01: text" per line
  ramble-outline.md     the 8 ramble points, with the keywords used for the Points score
  glossary.sample.md    glossary for the jargon in both files (edit it, or add glossary.md to override it)
  audio/                your recordings: s01.wav … s10.wav, ramble.wav  (git-ignored: audio stays on your Mac)
  references/           what each recording should say: s01.txt … s10.txt, ramble.txt
  superwhisper/         superwhisper's output text for the same recordings: s01.txt … ramble.txt
  results/              written by `devshout-cli bench` (<date>.md and <date>.csv)
```

## Before you start

1. Build the CLI on your Mac (macOS 14+, Xcode command line tools):
   ```bash
   swift build --package-path Mac -c release
   alias devshout-cli="$PWD/Mac/.build/release/devshout-cli"   # or use: swift run --package-path Mac devshout-cli …
   ```
2. Use the microphone you will really dictate with. `devshout-cli record --list-devices` lists the inputs; pass one
   with `--device <uid>`, or leave it out for the system default. The first `record` asks for microphone access on
   behalf of the app you run it in (Terminal, iTerm…): allow it. If you said no earlier, turn it on in System
   Settings → Privacy & Security → Microphone and reopen Terminal.
3. Open `bench/sentences.md` and replace each `⟨teammate⟩` with a real colleague's first name. Add the same names
   under `## People` in `bench/glossary.sample.md`. Change any sentence you want to make more like your day.
4. Find a quiet room. Record everything in the same session so the conditions match.

> `devshout-cli <command> --help` lists every option of each command.

## 1. Record the sentences (about 10 minutes)

One WAV per sentence, 16 kHz mono. `record` shows a level meter and the time, and stops when you press Enter
(or after `--seconds N`). Ctrl-C also stops it and keeps the file.

```bash
devshout-cli record bench/audio/s01.wav     # read sentence s01, then press Enter
devshout-cli record bench/audio/s02.wav
# … through s10
```

Read at your normal dictation pace. If you stumble, press Enter and record the file again (it is overwritten).

## 2. Record the ramble (about 5–7 minutes)

```bash
devshout-cli record bench/audio/ramble.wav
```

Open `bench/ramble-outline.md` beside you. **Do not read the `say:` lines out.** Look at one point, say it in your
own words, move on. Include the self-corrections, the numbers, both ticket IDs and the file path it asks for, and
feel free to um, ah, wander off and come back. It is meant to sound like you thinking aloud to Claude Code. Aim for
about five minutes.

## 3. Write the references (about 15 minutes)

For every recording, write `bench/references/<id>.txt`: the text you *meant* to dictate.

- `s01.txt` … `s10.txt`: the sentence as it should be pasted, with the same names you read out.
- `ramble.txt`: type out (or paste from any transcript and then fix) what you said, with correct spelling of the
  jargon, normal punctuation, and **only the corrected version of each self-correction** ("Thursday", not "Friday,
  no, Thursday"). Keep your own words and order: this is the reference for WER, so don't rewrite it as a brief.

Mistakes in the reference count against whichever engine is right, so read it through once.

## 4. Run the same files through superwhisper (about 20 minutes)

You want superwhisper's text for each recording, to compare like for like.

1. If superwhisper has **file transcription** (open a file or drag the WAV onto it, depending on your version), use
   that for each file in `bench/audio/`. Use its mode closest to plain transcription for the sentences and the
   ramble, with the same language. Note which mode and model you used.
2. If your version has no file transcription, **dictate live** instead: play the WAV through the speakers, or read
   the sentence again, with superwhisper's hotkey and a plain text editor focused. The result is then not exactly
   the same audio, which is fine for a rough comparison. Say so in your notes.
3. Save each result as plain text, with no edits, in `bench/superwhisper/<id>.txt` (`s01.txt` … `ramble.txt`).
4. Note the time it took for the ramble (stop to text on screen).

## 5. Try each piece on its own (optional, but it makes problems easier to find)

```bash
# Check the glossary: what was parsed, what Claude sees, and Whisper's prompt with its token count.
devshout-cli glossary bench/glossary.sample.md --try "the core sea flag on my supplies"

# Transcribe one file. The first run of each engine downloads its model (about 480 MB and 650 MB).
devshout-cli transcribe bench/audio/s01.wav --engine parakeet --glossary bench/glossary.sample.md
# --mode live times it as if transcribed while you talked and reports the tail latency (the wait after you stop);
# --chunks lists every chunk; --json prints everything machine-readably.
devshout-cli transcribe bench/audio/ramble.wav --engine whisper --glossary bench/glossary.sample.md --mode live --chunks
# Does Whisper's vocabulary prompt help? The same file without it:
devshout-cli transcribe bench/audio/ramble.wav --engine whisper --glossary bench/glossary.sample.md --no-vocabulary-prompt

# Connect Claude once (see below), then clean up a transcript exactly as the app will.
devshout-cli connect
devshout-cli transcribe bench/audio/ramble.wav --engine parakeet --glossary bench/glossary.sample.md > /tmp/raw.txt
devshout-cli cleanup --mode structure --model sonnet --glossary bench/glossary.sample.md < /tmp/raw.txt

# Where is claude, how quickly does it start, and does pre-warming it help? (10 runs of each by default)
devshout-cli claude-probe
```

Claude clean-up uses your subscription through `claude setup-token`. Run `devshout-cli connect`: it asks you to run
`claude setup-token` in another Terminal window and paste the token it prints (it isn't shown as you paste). The
token goes in this Mac's Keychain, in the same item the app uses; `devshout-cli connect --status` shows it and when
it expires, and `--delete` removes it. A `CLAUDE_CODE_OAUTH_TOKEN` environment variable, when set, is used instead.
There is no API-key option.

## 6. Run the benchmark (about 20–40 minutes, mostly waiting)

```bash
devshout-cli bench --dir bench --engines parakeet,whisper --modes raw,tidy,structure
# To see whether Whisper's vocabulary prompt helps, add both Whisper rows (engines whisper and whisper-noprompt):
devshout-cli bench --whisper-prompt both
```

For each sample with a recording and a reference it runs every engine and mode, scores the result, and writes
`bench/results/<yyyy-mm-dd-hhmm>.md` (the table, a summary per engine and mode, notes on anything skipped or failed,
and the text and errors behind every row) and `.csv`. If `bench/superwhisper/` has text for a sample, superwhisper
is scored in the same table (engine "superwhisper", mode "saved") so you can compare. Other options:
`--runs N`, `--samples s01,ramble`, `--glossary <file>`, `--tidy-model`, `--structure-model`, `--timeout`,
`--chunk-config <json>` (try other chunking thresholds); see `devshout-cli bench --help`.

Notes:

- Each engine transcribes a sample once, in live mode: that gives both the transcription time (Transcribe) and
  the tail latency (Tail), because live mode uses exactly the same chunks in the same order. Raw runs never call
  Claude. Tidy and Structure clean up that text and add Claude's time (spawn to exit) to the row. "Claude 1st
  byte" stays empty: `claude -p --output-format json` writes its whole answer at the end. `claude-probe` measures
  start-up and pre-warming.
- Missing recordings or references are skipped with a note, so you can run the bench before recording everything.
- The first Whisper or Parakeet run downloads and compiles the model, so its "Load" time is far larger than later
  runs. Run `bench` twice and keep the second set of numbers.
- Points (x/8) are only scored for the ramble. For Tidy and Structure it checks the *cleaned* text.

## 7. Read the result

Open `bench/results/<date>.md` and note the decisions the exit criteria need (PLAN §9, Phase 0):

- Which engine is the default?
- Does the Whisper vocabulary prompt help? (Compare the whisper and whisper-noprompt rows from `--whisper-prompt both`.)
- Are Tidy and Structure good enough: better than superwhisper on jargon, Structure missing 0 of the 8 points?
- Did any ramble result keep a corrected-away phrase ("ten percent", "AB-1243", "by Friday")? Tidy and Structure
  should drop them.
- Claude timings: is a 20 s Tidy and a 45 s Structure timeout right? Does pre-warming help (`claude-probe`)?

Commit the results file and your references (`git add bench/references bench/superwhisper bench/results`). The WAV
files are git-ignored on purpose.

## Editing the corpus

The files are plain Markdown read by parsers in `Core/Sources/DevshoutCore/Bench/`, with tests that run on the real
files (`swift test --package-path Core`). Keep these formats:

- `sentences.md`: one sentence per line as `- s01: text`. Anything else is ignored. Ids are `s` plus two digits.
- `ramble-outline.md`: each point is a heading `### 1. Label` (numbered 1, 2, 3 … in order), followed by
  `- say:` (guidance for you), `- keywords:` (groups separated by `;`, every group must match; alternatives within a
  group separated by `|`, any one will do) and optionally `- retracted:` (phrases that should be gone after
  clean-up, alternatives separated by `|`). Keyword matching ignores case and punctuation, so `AB-1234` matches
  "ab 1234", and it matches whole words only.
- `glossary.sample.md`: the format in PLAN §6.1. The bench reads the bold names under `## Terms` and `## People`.
