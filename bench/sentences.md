# Jargon sentences

Ten sentences to read aloud, one WAV each (`audio/s01.wav` … `audio/s10.wav`). They are packed with the jargon
that general-purpose dictation gets wrong. Read them naturally, at your normal pace.

Replace every `⟨teammate⟩` with a real colleague's first name before you record, and write the same name in the
reference file. Swap in your own projects and tickets too if you like. The sentences are free to edit, but keep the
`- sNN: text` format: one sentence per line, ids `s01` … `s10`. Everything else in this file is ignored by the
parser.

- s01: Can you check whether the CORSIA eligibility flag is set on every project in My Supply before Friday?
- s02: The proponent sent an updated PDD, so re-run the procurement scoring on AB-1234.
- s03: Map each NDC target to its host country and show the corresponding adjustment status.
- s04: Ask ⟨teammate⟩ to review the Article 6 authorisation letter attached to AB-2210.
- s05: In the My Supply table, sort by vintage, then by registry: Verra first, Gold Standard second.
- s06: The buffer pool contribution for the ARR project is twenty percent, not twelve.
- s07: Move AB-987 back to In Progress; the CORSIA first-phase cut-off is the thirty-first of December.
- s08: Our procurement pipeline should exclude any proponent without a signed ERPA.
- s09: ⟨teammate⟩ and ⟨teammate⟩ are pairing on the Supabase migration for the retirements endpoint.
- s10: Rename the NDC field to "nationally determined contribution" and add a tooltip linking to the UNFCCC page.

## Writing the references

`references/sNN.txt` is what the transcript should say, not what you happened to say. Write it as the text you
would want pasted: normal punctuation, digits or words exactly as you want them, and the jargon spelled correctly
(`CORSIA`, `My Supply`, `AB-1234`). Scoring ignores case and punctuation for WER, but the jargon hit rate checks
spelling and capitalisation exactly.
