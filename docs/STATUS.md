# docs/ Feature Status

My current (2026-04-13) workflow involves wanting a new feature, discussing and hammering scope with Claude Sonnet, which results in a Claude-generated Markdown TODO file in `docs/`. The TODO file contains problem statements, design decisions, and most importantly a work plan that other Claude sessions (Sonnet or Haiku) can execute.

| File | Status | Notes | Row Last Updated |
|------|--------|-------|------------------|
| [TODO-persist-chats.md](TODO-persist-chats.md) | **in-progress** | Persist every Haiku chat turn (user and assistant) to a new `chat.sqlite`. Separate from `quiz.sqlite` due to different value profile and faster growth. Schema: `turns` table with `context`, `role`, `content`, `template_id`. | 2026-04-18 |
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
