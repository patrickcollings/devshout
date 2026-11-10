# Ramble outline

One natural, unscripted ramble of about five minutes: you are talking a coding agent through a piece of work in
the Abatable app. Do not read it. Look at one point at a time, say it in your own words (ums and tangents are
welcome, they are the point of the test), then move on. About 30–40 seconds per point gets you to five minutes.

Record it as `audio/ramble.wav`. Afterwards write what you *meant* as `references/ramble.txt` (your hand-corrected
transcript: keep the speaker's words, fix mishearings, and keep only the corrected version of any self-correction).

The format is read by `RambleOutlineParser`. Each point is a `### N. Label` heading followed by bullets:

- `say:` guidance for you (not scored).
- `keywords:` what a text must contain to count as covering the point. Groups are separated by `;` and every
  group must be matched. Alternatives inside a group are separated by `|` and any one will do. Matching ignores
  case and punctuation, so `AB-1234` also matches "ab 1234".
- `retracted:` (optional) what you say and then correct. A Tidy or Structure result should not contain it.

Say the numbers and IDs exactly as written below, or edit both the `say:` line and the keywords together.

## Points

### 1. Goal and context
- say: Introduce the job. We are adding a CORSIA eligibility column and a filter to the My Supply table so buyers can see at a glance which projects qualify. Mention it needs to be ready by Friday, then correct yourself: no, Thursday, because of the buyer demo.
- keywords: CORSIA ; My Supply ; filter | column ; Thursday
- retracted: by Friday | on Friday

### 2. Where the code lives
- say: Point the agent at the file path src/features/my-supply/SupplyTable.tsx for the table, and say the filter state should live next to it rather than in a global store.
- keywords: src/features/my-supply/SupplyTable.tsx | SupplyTable.tsx | SupplyTable | supply table ; filter | state

### 3. The buffer pool figure
- say: The table also shows the buffer pool contribution for ARR projects. The default should be ten percent, no, sorry, twelve percent, and it must come from config rather than being hard coded.
- keywords: buffer pool ; 12 | twelve ; config | configuration
- retracted: ten percent | 10 percent

### 4. The first ticket
- say: This is AB-1243, no, AB-1234. The retirements endpoint returns a 500 when a project has no vintage. Ask the agent to reproduce it first with a failing test, then fix it.
- keywords: AB-1234 ; retirements ; vintage | 500 | failing test
- retracted: AB-1243

### 5. The second ticket
- say: AB-2210 is the follow-up: the Article 6 authorisation letter should be shown as a link on the project row. Tell the agent not to touch the upload flow, that is a separate piece of work.
- keywords: AB-2210 ; Article 6 ; link | row

### 6. Database and constraints
- say: Any schema change goes through a Supabase migration, one file, reversible. Do not change the existing columns on the retirements table, only add new ones. Mention it has to run against the staging database first.
- keywords: Supabase ; migration ; retirements ; staging | reversible

### 7. Tests and checks
- say: Ask for at least three new unit tests: eligible, not eligible, and no data. Tell it to run pnpm test and the type check before it says it is done, and to keep the pull request under 400 lines.
- keywords: 3 | three ; tests | test ; pnpm ; 400

### 8. Open question
- say: Finish with a question you want it to raise back with you rather than guess: should a proponent without a signed ERPA be excluded from the CORSIA filter, or only flagged with a warning? Say you lean towards flagging, but want to hear its view.
- keywords: ERPA ; proponent ; exclude | excluded | flag | flagged | warning
