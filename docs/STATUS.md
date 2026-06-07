# docs/ Feature Status

My current (2026-04-13) workflow involves wanting a new feature, discussing and hammering scope with Claude Sonnet, which results in a Claude-generated Markdown TODO file in `docs/`. The TODO file contains problem statements, design decisions, and most importantly a work plan that other Claude sessions (Sonnet or Haiku) can execute.

| File | Status | Notes | Row Last Updated |
|------|--------|-------|------------------|
| [TODO-html-reader.md](TODO-html-reader.md) | **done** | Enhancements to the `annotate-vocab-inline.mjs \| pandoc` HTML reading workflow to add furigana output | 2026-06-07 |
| [TODO-annotate-file-improvements.md](TODO-annotate-file-improvements.md) | **Parts 1, 1.5, 2 done** | Part 1: `annotate-novel.mjs` orchestrator + range-only `annotate-file.md` skill + WAL-mode work DB. Part 1.5: homophone disambiguation instruction (tested: わく→湧く correctly chosen over 沸く in yams story). Part 2: `annotate-file-with-senses.md` skill stores `{form, wordId, sense_indices}` objects; `annotate-harness.mjs done --senses` emits `<basename>.vocab-inline-data.json` sidecar next to annotated output; `annotate-vocab-inline.mjs` and `prepare-publish.mjs` both fall back to sidecar, skipping Haiku calls for words already sense-classified. Workflow documented in `ANNOTATING.md`. | 2026-06-06 |
| [TODO-greedy-annotator.md](TODO-greedy-annotator.md) | **done** | `start` now pre-computes a `hits` array per sentence: all JMDict entries found via exhaustive single-morpheme exact + multi-morpheme FTS5 prefix search (2–5 morpheme spans, cartesian product of lemma/literal forms, plus particle-stripped variants). Sorted longest-span-first. LLM selects coverage from `hits` without calling `lookup.mjs`. | 2026-05-24 |
| [TODO-fuzzing.md](TODO-fuzzing.md) | **iter. 1+2 done; 4 latent bugs found; iter. 3 (iOS) planned** | Dan Luu LLM-assisted fuzzing experiment. 6 Swift areas + 9 Node.js areas. **611k Swift items checked → 0 failures**. **4 bugs found, all in [`shared.mjs`](../.claude/scripts/shared.mjs) parsing**, all latent: BUG #1 `extractDetailsBlocks` mispairs nested `<details>`; BUG #2 `isFuriganaParent` returns true for empty arrays; BUG #3 `extractContextBefore` loses prose with nested `<details>`; BUG #4 `extractDetailsBlocks` matches `<details>` inside inline code spans / fences (found by J fuzzer scanning real corpus). Three share root cause: regex doesn't understand Markdown context. Full-corpus J run: 1,866 vocab bullets across 277 files, zero new bugs from real data (author has used canonical patterns). Iter. 3 plan: iOS quiz logic — K word commitment progression, L kanjidic2 cross-DB consistency, M counter pronunciation completeness, N transitive-pair distractors, O vocab.json structural invariants. | 2026-05-02 |
| [TODO-kanji-top-usage.md](TODO-kanji-top-usage.md) | **done** | For each kanji in the corpus vocabulary, show the top-50 BCCWJ long-unit-word entries (by pmw) containing that kanji, with total match count and JMDict IDs. Fills the gap in standard dictionary apps that list all words for a kanji but give no sense of frequency. Data generated at publish time into `kanji-top-usage.json`; iOS shows 10 rows at a time with a proportional frequency bar and furigana rendering. Also warns when a JMDict-common word has no BCCWJ match (possible UniDic canonicalization mismatch). Entry point: `>` chevron beside KanjiInfoCard in WordDetailSheet opens KanjiDetailSheet. | 2026-04-29 |
| [TODO-counters.md](TODO-counters.md) | **done** | Counters and numbers quiz. Counters enrolled as normal vocab words; `counters.json` maps JMDict IDs to 1–10 pronunciation tables (sourced from Tofugu TSV). New `counter-pronunciation` facet (kanji-gated). Wago drilled via a plain Markdown reading file. Scope: top 66 counters (must-know + common tiers). | 2026-04-19 |
| [TODO-persist-chats.md](TODO-persist-chats.md) | **done** | Persist every Haiku chat turn (user and assistant) to a new `chat.sqlite`. Separate from `quiz.sqlite` due to different value profile and faster growth. Shown in quiz history and word/grammar/transitive-pair detail sheets. | 2026-04-18 |
| [TODO-screenshots.md](TODO-screenshots.md) | **in-progress** | Hero screenshot tour for README. Unblocked now we know idb can let us progrmmatically tap iOS simulators. | 2026-04-18 |
| [TODO-dispute-ui.md](TODO-dispute-ui.md) | **not started** | Button to void a mis-graded multiple-choice score and restore the pre-quiz Ebisu model. Root generation bug (Haiku mis-tracking correctIndex during shuffle) fixed 2026-04-18 by shuffling app-side; dispute UI deferred pending evidence that the fix is insufficient. | 2026-04-18 |
| [TODO-dashboard.md](TODO-dashboard.md) | **done** | Racecar-style speedometer gauges (Vocab/Grammar) with rotating needles: upper 300° arc (weekly quizzes), lower 60° arc (new items). This week vs last week vs all-time max. Pace needle (dashed) shows on-track progress. Red overflow wedge when exceeding all-time max. Tap to toggle compact table view. | 2026-04-17 |
| [TODO-appliesToKanji.md](TODO-appliesToKanji.md) | **done** | All tasks ✅ including stretch goal (appliesToKana) and bonus (secondary kana readings). Status header says COMPLETE 2026-03-29. | 2026-04-13 |
| [TODO-audio-lyrics.md](TODO-audio-lyrics.md) | **done** | All phases implemented and end-to-end tested in simulator per the Done section. | 2026-04-13 |
| [TODO-classical-japanese.md](TODO-classical-japanese.md) | **done** | Confirmed: `classicalJapanese` field present in GrammarSync.swift, GrammarDetailSheet.swift, GrammarQuizContext.swift, and TestHarness. | 2026-04-13 |
| [TODO-compound-verbs.md](TODO-compound-verbs.md) | **data pipeline mostly done, iOS not started** | Phase 1 scripts all written; Pass 2c (apply-validation) and validate.mjs not yet written. Only 5 of 470 suffixes have meanings files — remaining Pass 1 runs are the main bottleneck (Haiku/Gemini spend). Phase 2 (iOS Swift) not started. | 2026-04-13 |
| [TODO-definitions-hover.md](TODO-definitions-hover.md) | **done** | Plugin exists at `.obsidian/plugins/obsidian-vocab-hover/main.js`. Personal workflow tool; not published to GitHub. Used for Markdown editing; Pug's document reader is preferred for reading. | 2026-04-13 |
| [TODO-furigana-for-quiz.md](TODO-furigana-for-quiz.md) | **done (steps 1–6)** | Steps 1–6 all marked ✅. Step 7 (NLTagger-based furigana for conjugated forms) is future work, explicitly deferred. | 2026-04-13 |
| [TODO-grammar-tier-2.md](TODO-grammar-tier-2.md) | **on hiatus** | Chronological research log of two-pass extraction architectures. Tier 2 declared out of scope in TODO-grammar.md. Kept as research record. | 2026-04-13 |
| [TODO-grammar.md](TODO-grammar.md) | **done (tier 1)** | Tier 1 (multiple choice) shipped. Tier 2 (fill-in-the-blank) explicitly deferred; see TODO-grammar-tier-2.md. Grammar databases: Genki, Bunpro, DBJG, Kanshudo enrolled. | 2026-04-13 |
| [TODO-history-browser.md](TODO-history-browser.md) | **partial** | History moved to ··· menu (done per TODO-reader.md Phase 3). Detail sheet design decided. Multiple-choice notes fix (storing all 4 choices) and persisted chat history are open TODOs. | 2026-04-13 |
| [TODO-homophones.md](TODO-homophones.md) | **not started** | Detection query + system prompt injection + free-text stem disambiguation. No evidence of implementation in recent commits. | 2026-04-13 |
| [TODO-images.md](TODO-images.md) | **done** | All items in Done section, end-to-end tested. Images appear inline in DocumentReaderView. | 2026-04-13 |
| [TODO-lm-studio.md](TODO-lm-studio.md) | **closed/reference** | Research log for local model furigana correction experiments. Concluded Ministral 3B insufficient; decision to use Haiku directly. No further work planned. | 2026-04-13 |
| [TODO-new-grammar-db.md](TODO-new-grammar-db.md) | **standing checklist** | Not a feature to complete — it's the enrollment checklist for any future grammar database. IMABI is the candidate; blocked on IMABI site remodel stabilizing. | 2026-04-13 |
| [TODO-planting.md](TODO-planting.md) | **done** | Fully implemented per recent commits (1ba5d38–07d3248). Session recovery, already-known skipping, SRS integration, watering integration all implemented. | 2026-04-13 |
| [TODO-reader.md](TODO-reader.md) | **done** | Working beautifully, my favorite part of the app. | 2026-04-13 |
| [TODO-sense.md](TODO-sense.md) | **done** | All steps including Step 5 (in-app sense enrollment) done as of 2026-04-08. | 2026-04-13 |
| [TODO-swift6.md](TODO-swift6.md) | **not started** | Migration guide. Low urgency. | 2026-04-13 |
| [TODO-transitive-intransitive-pairs.md](TODO-transitive-intransitive-pairs.md) | **done** | Completed in iOS. Future work is curating our small ~55 corpus of pedagogically-powerful pairs. | 2026-04-13 |

## Appendix: Ichiran

[Ichiran](https://github.com/tshatrov/ichiran) is a JMdict-based Japanese segmenter and dictionary lookup tool. Rather than doing NLP morphological analysis (like MeCab/UniDic), it works by greedily finding the best sequence of JMdict entries to cover a sentence. It runs as a Common Lisp process inside Docker, and a Node.js wrapper that calls it lives in the [tabito](https://github.com/fasiha/tabito) repo:

- [`src/nlp-wrappers/ichiran.ts`](https://github.com/fasiha/tabito/blob/main/src/nlp-wrappers/ichiran.ts) — core wrapper: spawns `docker exec ichiran-main-1 ichiran-cli -f <text>`, parses the JSON output, and resolves Ichiran-internal conjugation sequence numbers back to JMdict-native root sequences via a second PostgreSQL query against `ichiran-pg-1`
- [`src/nlp-wrappers/demo-ichiran.ts`](https://github.com/fasiha/tabito/blob/main/src/nlp-wrappers/demo-ichiran.ts) — usage demo
- [`src/nlp-wrappers/ichiran-types.ts`](https://github.com/fasiha/tabito/blob/main/src/nlp-wrappers/ichiran-types.ts) — TypeScript types for the deeply nested JSON output structure

**Strengths:**

- Returns JMdict `seq` numbers directly for each token — no secondary dictionary lookup needed
- Handles conjugation explicitly: the JSON output includes a `conj` array describing the inflection chain (part of speech, type such as "Past (~ta)", and the dictionary-form reading), so you get both the surface form and the root entry in one call; however in practice, I usually get much more extensive deconjugation info via https://github.com/fasiha/kamiya-codec
- Often identifies compound expressions as single entries (e.g., もう一度, お腹が減る), but sometimes misses them
- Recognizes counter values: e.g., 五回 is tagged with `counter: { value: "Value: 5" }` and the correct JMdict counter entry
- Handles reading disambiguation: ambiguous single-kanji words (e.g., 音 as おと/おん/ね) are returned as an `alternative` array ranked by score, rather than silently picking one
- Handles formal suru-verb compounds: e.g., 予約した is returned as a compound of 予約 + した with the した traced back to する via conjugation

**Weaknesses and limitations:**

- Fails or degrades on colloquial, informal, and manga-style text — text that deviates from standard written Japanese often produces zero results or wrong segmentations; MeCab can often handle such text
- Requires Docker with two running containers
- Misses some multi-morpheme compounds that span particles when the particle-stripped form isn't in JMdict (e.g., いきおいよく is split into いきおい + よく rather than recognized as a unit)
- Unknown words (proper nouns, mimetics, non-standard kana strings) get score 0 and no `seq` — they appear in the output but are essentially unrecognized
- The sequence numbers Ichiran returns for conjugated forms are sometimes Ichiran-internal IDs (above 1,000,000), not JMdict-native; the `getRootJmdictSeqs` helper in the tabito wrapper handles remapping these via the PostgreSQL `conjugation` table
