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
pre-answer controls (Don't know, Inkling, Skip) and post-answer controls
(Details, chat input, Tutor me). Halflife adjustment lives in the detail sheet,
not the quiz view — the detail sheet's rescale UI also shows review count.

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
