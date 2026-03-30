# Work plan: prefer kanji form consistent with corpus/user senses

## Problem statement

JMDict entries can have multiple kanji spellings where individual senses apply
only to specific spellings (encoded in `JMdictSense.appliesToKanji: string[]`).
The app currently always elevates `writtenForms[0]` / `kanjiTexts[0]` as the
primary display form and auto-commits it — ignoring the sense-to-kanji mapping.

Example: entry 1448820 (あて) has forms 当て / 宛 / 宛て. The corpus occurrence
uses sense 6 (addressee suffix), which has `appliesToKanji: ["宛", "宛て"]`. But
the app displays and commits 当て everywhere.

## Key decisions

**D1 — Compute preferred form at runtime, not at publish time.**
Baking a `preferredWrittenForm` into vocab.json would couple the decision to
corpus senses at publish time. The roadmap includes per-file sense enrollment
(users choosing to learn only the senses evinced in the specific file they are
studying), so the preferred form must be derived from whatever senses are
currently active, not frozen at publish time.

**D2 — `appliesToKanji` comes from jmdict.sqlite via `jmdictWordData()`, not vocab.json.**
All other sense metadata (glosses, part of speech, etc.) already comes from
jmdict.sqlite at corpus-load time. Adding `appliesToKanji` to `SenseExtra`
follows the same pattern and requires no pipeline change. `writtenForms` stays
in vocab.json — its co-location with per-file `llm_sense` data is an asset for
the upcoming enrollment feature, and removing it would trade that convenience
for an extra SQL query with no other benefit.

**D3 — Preferred form selection algorithm.**
```
activeKanji = union of appliesToKanji[i] for each i in activeSenseIndices
              where appliesToKanji[i] ≠ ["*"]  (["*"] = unrestricted, skip it)
preferredForm = first WrittenForm whose .text ∈ activeKanji
             ?? first WrittenForm whose .text ∈ appliesToKanji[i] for any i in activeSenseIndices
             ?? writtenForms.flatMap(\.forms).first   // last resort: no active sense has any
                                                       // kanji restriction at all
```
The second line handles the mutually-exclusive case: when no single form
satisfies all restricted active senses, at least pick a form that satisfies
one of them rather than falling all the way back to the JMDict-order first form
which may satisfy none.

"Active senses" today = `corpusSenseIndices` (union across all corpus
occurrences). Tomorrow = user's per-file enrolled senses. The algorithm is
identical in both cases — only the input changes.

**D4 — Keep `wordText: String` as a single string; do not make it plural.**
`wordText` is used in quiz stems, reader chips, history views, search, and LLM
system prompts — all of which require exactly one string. Pluralising it would
push a "pick one" decision into every caller. Instead, task 3 makes `wordText`
the right single form in the common case, and the detail sheet handles
edge cases through existing UI (furigana picker) plus new sense annotations
(task 5).

**D5 — Pathological case: mutually-exclusive active senses.**
If two active senses have disjoint `appliesToKanji` sets (e.g. sense A applies
only to form X and sense B applies only to form Y), the first-pass `activeKanji`
intersection is empty and no single form satisfies both. The algorithm's second
pass picks the first written form that satisfies any active restricted sense —
at least one sense is represented, which is better than falling back to the
JMDict-order first form which may satisfy neither. The detail sheet's furigana
picker already shows all forms, and the new sense annotations (task 5) make the
split visible so the user can pick deliberately.

**D6 — Forward compatibility with per-file sense enrollment.**
The data triangle needed for both features is already present in `VocabItem`:
- `writtenForms` — the actual form objects with furigana segments (from vocab.json)
- `senseExtras[i].appliesToKanji` — which forms sense i applies to (from jmdict.sqlite)
- `references[file].llm_sense.sense_indices` — which senses a given file uses (from vocab.json)

The enrollment feature will pass a file's sense indices as `activeSenseIndices`
to the same preferred-form function. No new plumbing needed when that feature lands.

---

## Sub-tasks

- [x] **1. Add `appliesToKanji` to `SenseExtra`.**
  In `QuizContext.swift`, add `appliesToKanji: [String]` to `SenseExtra`.
  In `jmdictWordData()`, parse `sense["appliesToKanji"] as? [String] ?? []`
  for each sense and populate the new field.
  Convention: empty array and `["*"]` both mean "no restriction"; the
  preferred-form algorithm skips both.

- [x] **2. Add `preferredWrittenForm(senseExtras:activeSenseIndices:writtenForms:)` helper.**
  A free function (or static method) that implements the D3 algorithm.
  Inputs: `[SenseExtra]`, `[Int]` (active sense indices), `[WrittenFormGroup]`.
  Returns: `WrittenForm?` — the first form satisfying the D3 priority order,
  or `nil` when no active sense has any kanji restriction (pure unrestricted
  case), signalling the caller to use its own default.
  Keep it pure (no side effects) so it is easy to test and reuse for enrollment.

- [x] **3. Fix `wordText` in `VocabCorpus.load()`.**
  Replace `wordText: jd.text` (always `kanjiTexts.first`) with
  `preferredWrittenForm(...) ?.text ?? jd.text`.
  `jd.text` must still be computed the same way for the `writtenTexts` /
  `kanaTexts` fields used elsewhere (search, etc.).
  This fixes: `VocabRowView` headline, reader vocab chip
  (`DocumentReaderView.swift:198`), and any other view that reads
  `item.wordText`.

- [x] **4. Fix `QuizItem.wordText` in `QuizContext.swift`.**
  `QuizItem` has its own `wordText: String` field (line 53) populated from
  `entry.text` (= `jd.text`) at quiz-context build time — separate from
  `VocabItem.wordText`. This is the string that ends up in reading-to-meaning
  and meaning-to-reading quiz stems (and logging). Apply the same
  `preferredWrittenForm` lookup here using `corpusSenseIndices`.
  Note: kanji-to-reading and meaning-reading-to-kanji stems are built from
  `word_commitment.furigana` (via `partialKanjiTemplate` / `committedReading`),
  so those are fixed by task 6 (autoCommitFirstForm) rather than here.

- [x] **5. Fix the `WordDetailSheet` heading.**
  `wordHeading` (lines 192–193) reads `item.writtenForms.first` directly,
  bypassing `wordText`. Change it to use the preferred form: pass
  `item.corpusSenseIndices` to the helper and fall back to
  `writtenForms.first` as before.

- [x] **6. Fix all auto-commit / default-form sites.**
  Replace `writtenForms.flatMap(\.forms).first` (or `writtenForms.first`) with a
  call to the same helper, passing `item.corpusSenseIndices`. Three sites:
  - `autoCommitFirstForm` in `WordDetailSheet.swift` ✓
  - `defaultFuriganaJSON` in `VocabCorpus.swift` (used by the swipe-to-learn path)
  - `swipeButtons` in `VocabBrowserView.swift` (kanji chars for "Learn kanji" swipe)

- [x] **7. Annotate `JMDictSenseListView` with `appliesToKanji`.**
  Render a secondary line beneath each gloss showing which written forms the
  sense applies to:
  - Restricted senses (`appliesToKanji` ≠ `["*"]`): list the specific forms,
    e.g. "applies to: 宛, 宛て".
  - Unrestricted senses (`appliesToKanji` == `["*"]`): enumerate all written
    forms for the word, e.g. "applies to: 当て, 宛, 宛て". This makes it
    immediately clear that unrestricted ≠ no kanji — it means all of them.
  `JMDictSenseListView` will need the word's full `writtenTexts: [String]`
  passed in so it can substitute real form names for `["*"]`. No model change —
  data is already in `SenseExtra` (after task 1) and `VocabItem.writtenTexts`.

- [ ] **8. Smoke-test with the あて example.**
  Confirm via `TestHarness --dump-prompts` that quiz stems now show 宛 or 宛て
  (not 当て) for entry 1448820. `VocabRowView` gets the fix for free via
  `item.wordText`; no code change expected there.
