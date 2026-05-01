# Kanji Quiz — Design Doc & Work Plan

## Motivation

The current kanji enrollment flow has two steps: toggle the "Kanji" picker to
"learning", then tap individual kanji characters in the green-box picker. This
is functional but opaque — the user is selecting characters with no context
about what those characters mean or how they behave in this word.

The proposal is to replace the picker with **per-kanji info cards** that are
directly tappable, and to introduce a new **`word_type = "kanji"` quiz** with
dedicated facets.

---

## Decisions

### Kanji quiz scope is global per-character

A kanji quiz entry for 図 is shared across all enrolled words that contain 図.
There is one set of Ebisu rows for 図 regardless of whether the learner first
encountered it in 図書館, 地図, or 図形. This means:

- Reviewing 図 from any context updates the same Ebisu models.
- Unenrolling 図 in one word does not remove the quiz rows if other words still
  sponsor it (see enrollment/unenrollment rules below).

Rationale: the on-readings, kun-readings, and meanings of a kanji are properties
of the character itself, not of any one word. Testing たべ (the reading of 食 in
食べる) versus しょく (the reading of 食 in 食堂) are distinct learning goals and
are already covered by the existing `word_type="jmdict"` kanji facets
(`kanji-to-reading`, `meaning-reading-to-kanji`). The new `word_type="kanji"`
quiz tests the character's top-level kanjidic2 data, which is word-independent.

### word_id encoding for kanji quiz entries

`word_id` is simply the kanji character:

```
{kanjiChar}
```

Example: `"図"` for the kanji 図, regardless of which word it was first enrolled from.

### Three facets per kanji

| Facet | Question | Correct answer |
|---|---|---|
| `kanji-to-on-reading` | Show the kanji character | Any one of the top-2 on-readings from kanjidic2 |
| `kanji-to-kun-reading` | Show the kanji character | Any one of the top-2 kun-readings from kanjidic2 |
| `kanji-to-meaning` | Show the kanji character | Any one of the top-2 meanings from kanjidic2 |

If a kanji has no on-readings (purely kun kanji), the `kanji-to-on-reading` row
is not planted. Same for no kun-readings.

All three facets start as multiple choice and graduate to free-answer using the
same thresholds as vocabulary facets: `freeAnswerMinReviews = 3` reviews **and**
`freeAnswerMinHalflife = 48` hours. `kanji-to-on-reading` and
`kanji-to-kun-reading` produce kana answers (same character class as
`meaning-to-reading`); `kanji-to-meaning` produces an English word (same
character class as `reading-to-meaning`). The `isFreeAnswer` computed property
in `QuizContext.swift` currently short-circuits to `false` for
`word_type="kanji"` — that guard should be removed so the standard graduation
logic applies.

The quiz accepts any one of the valid top-2 answers as correct. The review notes
record exactly which answer the student gave. The post-quiz answer bubble shows
the other valid top-2 choice(s) they did not say, so the learner sees the full
set over time.

### Enrollment and unenrollment

Enrollment for `word_type="kanji"` is sponsored by individual jmdict words. The
`word_commitment` table row for `word_type="kanji", word_id="{kanjiChar}"` gains
a `source_jmdicts` column storing a JSON array of jmdict IDs that currently
sponsor this kanji, e.g. `["1588120", "1234567"]`.

KanjiInfoCard shows **two independent checkboxes** — one per zone — so the two
enrollment types are controlled separately without either interfering with the
other:

- **Top zone checkbox** ("This word"): enrolls or unenrolls the word-context
  kanji facets (`kanji-to-reading`, `meaning-reading-to-kanji`) for this jmdict
  word. This is the existing behavior, unchanged.
- **Bottom zone checkbox** ("This kanji in general"): enrolls or unenrolls the
  global kanji quiz facets (`kanji-to-on-reading`, `kanji-to-kun-reading`,
  `kanji-to-meaning`) for the kanji character, sponsored by this word.

The two zones are separated by a horizontal divider. Tapping a zone only affects
that zone's enrollment. The whole card gets a green border when either checkbox
is checked; the green background tint appears only in the checked zone(s).

**Top zone checkbox — tapping ON for word W (jmdict ID J):**
- Update jmdict word's `kanji_chars` and plant the jmdict kanji facets
  (`kanji-to-reading`, `meaning-reading-to-kanji`) for that word (existing behavior).

**Top zone checkbox — tapping OFF for word W (jmdict ID J):**
- Update jmdict word's `kanji_chars` and remove the jmdict kanji facets for
  that word (existing behavior).

**Bottom zone checkbox — tapping ON for word W (jmdict ID J):**
1. Check if J is in this kanji's `source_jmdicts` array and add if not (create
   the `word_type="kanji"` commitment row if absent).
2. If `source_jmdicts` was empty before this tap, plant the `word_type="kanji"`
   Ebisu rows (up to 3 facets).
3. If `source_jmdicts` was already non-empty, verify the Ebisu rows exist and
   leave them untouched — do not overwrite progress.

**Bottom zone checkbox — tapping OFF for word W (jmdict ID J):**
1. Remove J from this kanji's `source_jmdicts` array.
2. If `source_jmdicts` is now empty, delete the `word_type="kanji"` Ebisu rows.
3. If `source_jmdicts` still has other IDs, leave the Ebisu rows untouched.

### KanjiInfoCard checkbox state on open

- **Top zone checkbox**: checked when this word's `kanji_chars` includes this
  kanji character (same as before).
- **Bottom zone checkbox**: checked when this word's jmdict ID appears in this
  kanji's `source_jmdicts`. Opens unchecked for any word whose ID is not already
  in `source_jmdicts`, even if the kanji has active Ebisu rows from other words.

The "also learning in: 地図, 図形" rows below the card remain the only indicator
that the kanji already has active Ebisu rows from other words.

### Facets to NOT change

The existing `word_type="jmdict"` kanji facets (`kanji-to-reading`,
`meaning-reading-to-kanji`) are unchanged. The new `word_type="kanji"` facets
are parallel and independent. No changes to jmdict quiz logic.

### kanjiMeanings LLM step

The `kanjiMeanings` field in vocab.json (identifying which kanjidic2 meanings are
active in a specific word's JMDict definition) is retained for display in
KanjiInfoCard's "This word" zone. It is no longer quiz-relevant — the quiz uses
kanjidic2 top-2 data directly.

---

## Available data

### kanjidic2.sqlite (already present)

```sql
CREATE TABLE kanji (
  literal      TEXT PRIMARY KEY,
  strokes      INTEGER,
  grade        INTEGER,
  jlpt         INTEGER,   -- old JLPT scale: 4=N5, 3=N4, 2=N3, 1=N2
  on_readings  TEXT,      -- JSON array
  kun_readings TEXT,      -- JSON array
  meanings     TEXT,      -- JSON array (English only)
  radicals     TEXT
);
```

Sample rows:

```
図|7|2|3|["ズ","ト"]|["え","はか.る"]|["map","drawing","plan","extraordinary","audacious"]|["斗","囗"]
書|10|2|4|["ショ"]|["か.く","-が.き","-がき"]|["write"]|["日","聿"]
館|16|3|3|["カン"]|["やかた","たて"]|["building","mansion","large building","palace"]|["口","食","宀","｜"]
```

The iOS app already has kanjidic2.sqlite bundled alongside jmdict.sqlite.

### Top-2 on/kun/meanings

The quiz uses the first two entries of `on_readings`, `kun_readings`, and
`meanings` from kanjidic2 for the target kanji. If an array has fewer than two
entries, all available entries are used. Kun-readings are stripped at the
okurigana marker ("はか.る" → "はか") before display and comparison.
On-readings are stored as katakana in kanjidic2 and converted to hiragana for
quiz answer matching (Unicode scalar shift U+30A1–U+30F6 → U+3041–U+3096).

### Meanings active in this word (kanjiMeanings, display only)

kanjidic2 lists several meanings per kanji. For display in the KanjiInfoCard
"This word" zone, `kanjiMeanings` in vocab.json records which kanjidic2 meanings
are active in a specific word. This is populated by the existing LLM step in
prepare-publish.mjs and is used for display only — not for quiz grading.

---

## UI changes

### KanjiInfoCard contents

Each card has two tappable zones separated by a horizontal divider. Each zone
has its own independent checkbox on the right.

**Top zone — "This word"** (tapping controls word-context kanji facets):
- Large kanji character
- The reading used in this word, highlighted green when enrolled (from furigana)
- The kanjidic2 meanings active in this word (from `kanjiMeanings` in vocab.json)
- Checkbox top-right: filled green when enrolled, empty ring when not

**Bottom zone — "This kanji in general"** (tapping controls global kanji quiz):
- Three left-aligned rows: 音 on-readings, 訓 kun-readings, meanings
- Readings matching the word's reading are shown at primary brightness; others
  at secondary. Meaning words active in this word are shown at primary brightness.
- Checkbox right-aligned (vertically centered with the three rows): filled green
  when enrolled, empty ring when not
- Font is `.subheadline` — these are secondary content, not footnotes

The entire card gets a green border when either checkbox is checked. The green
background tint appears only inside the zone(s) whose checkbox is checked.

**Also learning in** (below the card, not inside it):
- "Also in: 地図" — tappable rows for other words that sponsor this kanji
  (words whose jmdict ID appears in `source_jmdicts`). Tapping opens
  WordDetailSheet for that word.
- This list is the only indicator that the kanji has active Ebisu rows from
  other words.

---

## Quiz architecture additions

### Facet: kanji-to-on-reading

- **Question stem**: "What is an on-reading of {kanji}?" — no parent word
- **Expected answer**: any one of the top-2 on-readings (katakana converted to
  hiragana for matching). Both are equally correct.
- **Review notes**: record which specific on-reading the student gave, and
  whether it was correct
- **Post-quiz bubble**: show the other valid on-reading(s) from the top-2 set
  so the learner sees the full picture over time
- **Multiple choice distractors**: on-readings of other kanji with similar stroke
  counts (from kanjidic2); all on-readings of the test kanji are excluded from
  the distractor pool
- **Free-answer grading**: fast-path kana string match only — on-readings are
  unambiguous kana strings; no LLM fallback needed
- **Post-quiz coaching prompt** (both multiple choice and free-answer):
  - Tell Claude: the kanji character, all top-2 on-readings, whether the student
    got it right or wrong, and which reading they gave (or "tapped don't know")
  - On **success**: coach should briefly confirm the reading, mention the other
    top-2 on-reading if one exists, and give 1–2 common example words that use
    this on-reading in context
  - On **failure**: coach should name the correct on-reading(s), explain the
    on-yomi origin (Chinese-derived reading), and give 1–2 example words to make
    the reading memorable
  - Claude has access to the full toolset and should use `lookup_kanjidic` and
    `lookup_jmdict` to ground example words in the actual database rather than
    relying on training-data recall

### Facet: kanji-to-kun-reading

- **Question stem**: "What is a kun-reading of {kanji}?" — no parent word
- **Expected answer**: any one of the top-2 kun-readings, with okurigana stripped
  at the "." marker (e.g. "はか.る" → accepted as "はか"). Both are equally correct.
- **Okurigana leniency** (free-answer only): if the student types the full verb or
  adjective form including okurigana (e.g. "はかる" when the stem is "はか"), check
  whether their answer starts with the stripped stem and the suffix matches the
  stored okurigana portion. If so, accept as correct and note "included okurigana"
  in the review notes. This rewards students who know the full word form.
  Implementation: for each top-2 kun-reading that has a "." in the kanjidic2 entry,
  store both the stripped stem ("はか") and the full form ("はかる") as valid answers.
- **Review notes**: record which kun-reading stem the student gave and whether they
  included okurigana
- **Post-quiz bubble**: show the other valid kun-reading(s), displayed as full
  forms with okurigana (e.g. "はか.る" rendered as "はか**る**") so the learner
  sees the complete word shape
- **Multiple choice distractors**: kun-readings of stroke-count-similar kanji;
  all kun-readings of the test kanji excluded; choices shown as stripped stems
  (okurigana removed) so options are comparable
- **Free-answer grading**: fast-path kana string match with okurigana leniency
  as above — no LLM fallback needed
- **Post-quiz coaching prompt**:
  - Tell Claude: the kanji, all top-2 kun-readings (full kanjidic2 forms with
    okurigana markers), whether correct/wrong, what the student gave
  - On **success**: confirm the kun-reading, mention the other top-2 kun-reading
    if one exists, give 1–2 example words. If they included okurigana correctly,
    optionally note that
  - On **failure**: name the correct kun-reading(s) with okurigana, explain that
    kun-readings are native Japanese readings (as opposed to Chinese-derived
    on-readings), and give 1–2 example words to anchor the reading

### Facet: kanji-to-meaning

- **Question stem**: "What does {kanji} mean?" — no parent word
- **Expected answer**: any one of the top-2 meanings from kanjidic2. Both are
  equally correct.
- **Review notes**: record which meaning the student gave and correct/wrong verdict
- **Post-quiz bubble**: show the other valid meaning(s) from the top-2 set
- **Multiple choice distractors**: meanings from stroke-count-similar kanji; all
  kanjidic2 meanings of the test kanji excluded
- **Free-answer grading**: fast-path exact string match first; if no match,
  slow-path LLM grading (same two-tier pattern as transitive-pair single-leg
  facets) to handle near-misses like "drawing" vs "a drawing", "map" vs "mapping",
  "audacious" vs "bold". The LLM grades 0.0–1.0 and emits `SCORE: X.X`.
- **Post-quiz coaching prompt**:
  - Tell Claude: the kanji, all top-2 meanings (and optionally all kanjidic2
    meanings for context), whether correct/wrong, what the student gave (or
    "tapped don't know")
  - On **success**: briefly confirm, mention the other top-2 meaning if one
    exists, and optionally note any nuance between the two meanings. Give 1–2
    example words that illustrate this meaning.
  - On **failure**: name the correct top-2 meanings with a short explanation of
    what distinguishes them from the student's wrong answer if it was a plausible
    guess. Give 1–2 example words. Avoid just listing all kanjidic2 meanings —
    keep focus on the top-2 the student is responsible for.
  - On **partial** (LLM score > 0 but < 1): acknowledge the near-miss, explain
    the difference between what they said and the canonical answer.

---

## Work plan

### ✅ Step 1 — kanjidic2 data available in app

- [x] Confirm kanjidic2.sqlite is bundled in the app and accessible
- [x] Verify `lookup_kanjidic` tool is already implemented in ToolHandler.swift

### ✅ Step 2 — kanjiMeanings LLM step in prepare-publish.mjs

- [x] Implement `buildKanjiMeaningsPrompt` and `analyzeKanjiMeanings`
- [x] Add kanjiMeanings analysis to prepare-publish.mjs pipeline
- [x] Store results as `kanjiMeanings` in vocab.json (display use only)

### ✅ Step 3 — KanjiInfoCard UI (partially done; needs updates below)

- [x] Create `KanjiInfoCard` SwiftUI view component
- [x] Wire to kanjidic2 database for reading/meaning lookups
- [x] Split into two independent zones, each with its own checkbox:
  - Top zone controls word-context kanji facets (`isWordEnrolled` / `onToggleWord`)
  - Bottom zone controls global kanji quiz (`isKanjiEnrolled` / `onToggleKanji`)
- [x] Green border on whole card when either zone is enrolled; green tint only
      in the enrolled zone(s)
- [x] Bottom zone uses 3-row left-aligned layout (音, 訓, meanings) with checkbox
      right-aligned
- [ ] "Also learning in" list reflects `source_jmdicts` (new column) instead of
      `WHERE word_id LIKE '{char}:%'` query against old word_id format

### ✅ Step 4 — Update WordDetailSheet & PlantView

- [x] Add `@State private var kanjiQuizEnrolled: [String: Bool]` to WordDetailSheet
- [x] Populate `kanjiQuizEnrolled` in `loadEbisuModels` from `source_jmdicts` check
- [x] Split `toggleKanjiChar` (word-context only) from new `toggleKanjiQuiz`
      (global kanji quiz only) — the old single toggle did both
- [x] PlantView passes `isKanjiEnrolled: false` and `onToggleKanji: {}` — global
      kanji quiz enrollment is not available during initial planting; use
      WordDetailSheet afterward

### 🔄 Step 5 — Rework kanji quiz facets and enrollment (replaces old Step 5)

- [ ] Add `source_jmdicts TEXT` column to `word_commitment` table via a new DB
      migration (since no users have this feature, simulator reset is acceptable
      instead of a migration; add the column in the schema definition)
- [ ] Update `QuizDB.setKanjiQuizLearning` to:
  - Use `word_id = "{kanjiChar}"` (not `"{kanjiChar}:{jmdictId}"`)
  - Append the jmdict ID to `source_jmdicts` JSON array in `word_commitment`
  - Plant up to 3 Ebisu rows (on-reading, kun-reading, meaning) only if
    `source_jmdicts` was empty before this call; otherwise verify rows exist
    without overwriting
  - Facet names: `kanji-to-on-reading`, `kanji-to-kun-reading`, `kanji-to-meaning`
- [ ] Update `QuizDB.setKanjiQuizUnknown` to:
  - Remove the jmdict ID from `source_jmdicts`
  - Delete Ebisu rows only if `source_jmdicts` is now empty
- [ ] Update `KanjiQuizData` struct to carry:
  - Top-2 on-readings (hiragana), top-2 kun-readings, top-2 meanings
  - No parent word text (word_id is just the character)
- [ ] Update `buildKanjiMultipleChoice` to generate questions for three facets:
  - `kanji-to-on-reading`: stem "What is an on-reading of {kanji}?", 4 choices
    (hiragana), correct = any top-2 on-reading
  - `kanji-to-kun-reading`: stem "What is a kun-reading of {kanji}?", 4 choices
    (hiragana), correct = any top-2 kun-reading
  - `kanji-to-meaning`: stem "What does {kanji} mean?", 4 choices (English),
    correct = any top-2 meaning
  - Distractor pool: stroke-count-similar kanji from kanjidic2 (existing fallback
    query); exclude ALL readings/meanings of the test kanji from the pool
- [ ] Update review notes format to record which specific answer the student gave
      (e.g. "gave: はか; correct: はか or え" so history is self-contained)
- [ ] Update post-quiz answer bubble to show the other valid top-2 choice(s)
- [ ] Update `QuizContext.build()` to load `word_type="kanji"` records with the
      new facet names
- [ ] Remove `if wordType == "kanji" { return false }` guard in `QuizItem.isFreeAnswer`
      so all three kanji facets graduate to free-answer using the standard
      `freeAnswerMinReviews` / `freeAnswerMinHalflife` thresholds
- [ ] Add `kanji-to-on-reading`, `kanji-to-kun-reading`, `kanji-to-meaning` cases
      to `freeAnswerStem()` in `QuizSession.swift`
      (e.g. "Type an on-reading of 図:", "Type a kun-reading of 図:", "What does 図 mean?")
- [ ] Free-answer grading:
  - `kanji-to-on-reading`: fast-path exact kana match against top-2 on-readings
    (hiragana); no LLM fallback needed
  - `kanji-to-kun-reading`: fast-path with okurigana leniency — for each top-2
    kun-reading, accept both the stripped stem ("はか") and the full form with
    okurigana appended ("はかる"). Store both in `KanjiQuizData` at load time so
    Swift grading is a simple set membership check, no string manipulation at
    grade time
  - `kanji-to-meaning`: fast-path exact string match first; if no match,
    slow-path LLM grading emitting `SCORE: X.X` (same pattern as transitive-pair
    single-leg facets) to handle near-misses like "drawing" vs "a drawing"
- [ ] **Post-quiz coaching system prompts** — write one `systemPrompt` variant per
      facet that includes: the kanji character, the top-2 valid answers for that
      facet, whether the student got it right/wrong/partial, and what they gave.
      The system prompt injects the top-2 data for the tested facet, but Claude
      should have access to the full toolset (`lookup_kanjidic`, `lookup_jmdict`,
      etc.) so it can pull the complete kanjidic2 entry (all readings, all
      meanings, radicals, JLPT level) and look up real JMDict example words that
      use this kanji with the specific reading being tested, rather than relying
      on training-data recall.
  - `kanji-to-on-reading` success: confirm reading, name the other top-2 on-reading,
    give 1–2 example words using this on-reading
  - `kanji-to-on-reading` failure: name correct on-reading(s), explain on-yomi as
    Chinese-derived, give 1–2 example words
  - `kanji-to-kun-reading` success: confirm reading, name the other top-2 kun-reading,
    note if they included okurigana correctly, give 1–2 example words
  - `kanji-to-kun-reading` failure: name correct kun-reading(s) with full form,
    explain kun-yomi as native Japanese, give 1–2 example words
  - `kanji-to-meaning` success: confirm meaning, name the other top-2 meaning,
    briefly note nuance between the two if they differ meaningfully
  - `kanji-to-meaning` failure/partial: name correct top-2 meanings, explain why
    the student's answer was wrong or close, give 1–2 example words; do NOT
    dump the full kanjidic2 meanings list
- [ ] **Prefetching** — `prefetchQuestion()` must mirror `generateQuestion()` exactly
      per the rules in `docs/quiz-architecture.md`:
  - Kanji items must be dispatched before the `isFreeAnswer` check (same as
    current order) for the multiple-choice path
  - Once kanji facets can graduate to free-answer, graduated kanji items will
    fall through to the `isFreeAnswer` branch naturally — verify this path works
  - Any random state used to build a kanji question stem (e.g. which of the top-2
    answers to highlight as "primary") must be stored in the `prefetched` tuple
    and restored in the consume block inside `generateQuestion()`, not re-derived
    from session-level mutable state
  - After implementing, check: does a prefetched kanji item show the same question
    the prefetch built, or does it regenerate? Regression test: enroll one kanji,
    force two kanji items into the queue back-to-back, verify both show distinct
    correct questions
- [ ] Update `facetDisplayName` for the three new facet names
- [ ] Update `WordDetailSheet.loadEbisuModels` to fetch `word_type="kanji"` rows
      with new facet names
- [ ] Verify `QuizFilter.vocabOnly` still includes `word_type="kanji"`
- [ ] Remove old `{kanjiChar}:{jmdictId}` word_id logic everywhere

### ⏳ Step 6 — Documentation & refinement

- [ ] Update docs/DATA-FORMATS.md
  - Document `kanjiMeanings` field (display only, not quiz-relevant)
  - Document `word_id` format for kanji quiz entries (just `{kanjiChar}`)
  - Document `source_jmdicts` column in `word_commitment`
  - Document the three kanji quiz facets
- [ ] Update docs/quiz-architecture.md with revised kanji facet specs
- [ ] Update docs/feature-parity.md with kanji quiz requirements

### Smoke test plan (Step 5)

1. **Top zone only — word-context kanji enrollment:**
   - Open WordDetailSheet for 図書館. Tap the **top zone** of the 図 card. Verify:
     - `kanji_chars` updated for 図書館's jmdict commitment
     - `word_type="jmdict"` facets planted (`kanji-to-reading`,
       `meaning-reading-to-kanji`) for 図書館
     - No `word_type="kanji"` rows created — bottom zone was not tapped
     - Bottom zone checkbox remains unchecked

2. **Bottom zone only — global kanji quiz enrollment, first word:**
   - Tap the **bottom zone** of the 図 card in 図書館. Verify:
     - `source_jmdicts` = `["1588120"]` in `word_commitment` for `word_id="図"`
     - Three Ebisu rows planted: `kanji-to-on-reading`, `kanji-to-kun-reading`,
       `kanji-to-meaning` with `word_id="図"`
     - Top zone enrollment state is unaffected

3. **Bottom zone enrollment — second word sharing same kanji:**
   - Open WordDetailSheet for 地図. Tap its **bottom zone** for 図. Verify:
     - `source_jmdicts` = `["1588120", "jmdictIdOf地図"]`
     - Existing Ebisu rows for `word_id="図"` are unchanged (not overwritten)

4. **Bottom zone unenrollment — one sponsor remains:**
   - Tap the **bottom zone** of 図 off in 地図. Verify:
     - `source_jmdicts` = `["1588120"]` (地図's ID removed)
     - Ebisu rows for `word_id="図"` still present

5. **Bottom zone unenrollment — last sponsor:**
   - Tap the **bottom zone** of 図 off in 図書館. Verify:
     - `source_jmdicts` = `[]` or row deleted
     - Ebisu rows for `word_id="図"` deleted

6. **Independent zones — mixed state:**
   - Enroll top zone only for one kanji. Verify card has green border, green
     tint only in top zone, bottom zone checkbox empty.
   - Then enroll bottom zone too. Verify both zones show green tint.
   - Unenroll top zone. Verify green border remains (bottom still enrolled),
     only bottom zone shows green tint.

7. **Quiz session — kanji-to-on-reading:**
   - Enroll bottom zone for 図. Force urgency (rescale halflife). Start vocab quiz.
   - Question: "What is an on-reading of 図?" with four hiragana choices.
   - Correct answer is ず or と (top-2 on-readings, converted from ズ/ト).
   - Post-quiz bubble shows the other valid on-reading.

8. **Quiz session — kanji-to-kun-reading:**
   - Question: "What is a kun-reading of 図?" with four hiragana choices.
   - Correct answer is え or はか (top-2 kun-readings, okurigana stripped).

9. **Quiz session — kanji-to-meaning:**
   - Question: "What does 図 mean?" with four English choices.
   - Correct answer is "map" or "drawing" (top-2 meanings).
   - Post-quiz bubble shows the other valid meaning.

10. **No on-readings kanji:**
    - Enroll bottom zone for a kanji with no on-readings. Verify only two Ebisu
      rows are planted (kun-reading and meaning; no on-reading row).

11. **Regression — jmdict kanji facets unchanged:**
    - Verify that `word_type="jmdict"` `kanji-to-reading` and
      `meaning-reading-to-kanji` facets still work correctly after top zone
      toggle, independent of bottom zone state.
