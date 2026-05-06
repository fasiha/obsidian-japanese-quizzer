# Feature parity matrix (Pug app)

Every quiz type and every detail sheet should offer the same baseline features.
Use this matrix as the source of truth when adding a new quiz or detail sheet.

## Quiz views

`QuizView` handles both vocabulary and transitive-pair items (the Details button
opens `WordDetailSheet` or `TransitivePairDetailSheet` depending on `wordType`).
`GrammarQuizView` handles grammar items.

**Pre-answer phase** (shown while student is choosing/typing):

| Feature                      | `QuizView` | `GrammarQuizView` |
| ---------------------------- | ---------- | ----------------- |
| Don't know / Inkling buttons | yes        | yes               |
| Skip button                  | yes        | yes               |
| Report problem button        | yes        | yes               |

**Post-answer chatting phase** (shown after student answers):

| Feature                             | `QuizView` | `GrammarQuizView` |
| ----------------------------------- | ---------- | ----------------- |
| Details button (opens detail sheet) | yes        | yes               |
| Post-answer chat                    | yes        | yes               |
| Chat tools: `lookup_jmdict`         | yes        | yes               |
| Chat tools: `lookup_kanjidic`       | yes        | yes               |
| Chat tools: `get_mnemonic`          | yes        | yes               |
| Chat tools: `set_mnemonic`          | yes        | yes               |
| Tutor me button (wrong answers)     | yes        | yes               |

When adding a new quiz type, implement both phases from an existing quiz view:
pre-answer controls (Don't know, Inkling, Skip, Report problem) and post-answer controls
(Details, chat input, Tutor me, Report problem). The "Report problem" button appears
next to Skip in every phase. Use `ReportProblemButton` (pre-answer) and pass
`onReportProblem` to `PostAnswerChatView` (post-answer). See the Problem reporting
checklist in `docs/quiz-architecture.md`.

## Complete word-type × facet enumeration

This table is the authoritative list of every quiz path in the app. **Update it when
adding a new word type or facet.** The quiz-architecture checklist also requires
updating this table.

All `QuizView` paths share a single `PostAnswerChatView` for the post-answer phase.
All `GrammarQuizView` paths share a single `chattingView` for the post-answer phase.

| `wordType` | facet | pre-answer phase | pre-answer view | post-answer view |
| ---------- | ----- | ---------------- | --------------- | ---------------- |
| `jmdict` | `reading-to-meaning` | `.awaitingTap` or `.awaitingText` | `awaitingTapView` / `awaitingTextView` | `PostAnswerChatView` |
| `jmdict` | `meaning-to-reading` | `.awaitingTap` or `.awaitingText` | `awaitingTapView` / `awaitingTextView` | `PostAnswerChatView` |
| `jmdict` | `kanji-to-reading` | `.awaitingTap` | `awaitingTapView` | `PostAnswerChatView` |
| `jmdict` | `meaning-reading-to-kanji` | `.awaitingTap` | `awaitingTapView` | `PostAnswerChatView` |
| `counter` | `meaning-to-reading` | `.awaitingText` | `awaitingTextView` | `PostAnswerChatView` |
| `counter` | `counter-number-to-reading` | `.awaitingText` | `awaitingTextView` | `PostAnswerChatView` |
| `transitive-pair` | `pair-discrimination` | `.awaitingPair` | `awaitingPairView` | `PostAnswerChatView` |
| `transitive-pair` | `transitive` | `.awaitingPair` | `awaitingPairView` | `PostAnswerChatView` |
| `transitive-pair` | `intransitive` | `.awaitingPair` | `awaitingPairView` | `PostAnswerChatView` |
| `kanji` | `kanji-to-on-reading` | `.awaitingTap` | `awaitingTapView` | `PostAnswerChatView` |
| `kanji` | `kanji-to-kun-reading` | `.awaitingTap` | `awaitingTapView` | `PostAnswerChatView` |
| `kanji` | `kanji-to-meaning` | `.awaitingTap` | `awaitingTapView` | `PostAnswerChatView` |
| `grammar` | `production` | `GrammarQuizView .awaitingTap` | `awaitingTapView` | `GrammarQuizView.chattingView` |
| `grammar` | `recognition` | `GrammarQuizView .awaitingTap` | `awaitingTapView` | `GrammarQuizView.chattingView` |

Notes:
- `jmdict` reading-to-meaning and meaning-to-reading use `.awaitingTap` at lower recall (multiple choice) and `.awaitingText` at higher recall (free answer), controlled by `QuizItem.isFreeAnswer`.
- `kanji` (wordType) is distinct from `jmdict` words that have committed kanji. It refers to standalone kanji quiz items sourced from kanjidic2, not JMDict entries.
- `planting` drills (`PlantView`) share `PostAnswerChatView` for the post-answer phase but have no pre-answer Skip button by design — skipping happens on the introduce card.

## Detail sheets

All detail sheets (`WordDetailSheet`, `TransitivePairDetailSheet`,
`GrammarDetailSheet`, and any future detail sheet) must present sections in
this top-to-bottom order:

| # | Section | Word | Transitive pair | Grammar |
| - | ------- | ---- | --------------- | ------- |
| 1 | Word/pair/grammar content (heading, JMDict senses via `JMDictSenseListView`, usage examples) | yes | yes | yes |
| 2 | Mnemonics display | yes | yes | yes |
| 3 | Learning status controls (don't know / learning / known, or enroll/unenroll) | yes | yes | yes |
| 4 | Ebisu halflives with rescale (RescaleSheet shows review count; only shown when the item is being learned) | yes | yes | yes |
| 5 | Ask Claude free chat (tools: `lookup_jmdict`, `lookup_kanjidic`, `get_mnemonic`, `set_mnemonic`) | yes | yes | yes |

When adding a new detail sheet, implement all applicable rows in this order.
JMDict senses use the shared `JMDictSenseListView` so improvements propagate
to all sheets automatically.
