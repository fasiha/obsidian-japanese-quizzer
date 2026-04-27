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

### Kanji quiz scope is strictly per-word

A kanji quiz entry for 図 in 図書館 (toshokan) is completely separate from 図 in
図形 (zukei). They get independent Ebisu models, independent enrollment, and no
passive cross-word updating. This mirrors the existing behavior — there is no
cross-word kanji interaction in quiz.sqlite beyond mnemonics, which are also
per-`(word_type, word_id)`.

Rationale: kanji readings and relevant meanings differ by word. Sharing SRS
state across words would conflate distinct learning signals and make partial
commitment (committing to 図 in toshokan but not zukei) difficult to express (worth doing but for now this is left as future work).

A future informational affordance — "you are also learning this kanji in these
other words" shown in the kanji info card — is welcome but is purely display; it
does not affect scheduling.

### word_id encoding for kanji quiz entries

Since a kanji quiz is scoped to one parent word, `word_id` must encode both
the kanji character and the parent JMDict ID. Format:

```
{kanjiChar}:{jmdictId}
```

Example: `図:1588120` for 図 as learned via 図書館 (JMDict ID 1588120).

This format enables efficient lookups: `WHERE word_id LIKE '図:%'` returns all
enrolled words teaching the kanji 図, useful for the "also learning this kanji
in" disclosure and for detecting when a kanji has multiple readings across
enrolled words.

The specific reading used in each word is stored in `word_commitment.furigana`,
not encoded in `word_id`. This keeps the key simple and avoids redundancy —
the furigana array already records which reading is associated with each kanji
character in the committed form.

This keeps `word_type = "kanji"` entries distinguishable in all existing tables
(`reviews`, `ebisu_models`, `word_commitment`, `learned`, `mnemonics`) without
schema changes.

### Facets to ship in the first version

| Facet | Question | Answer |
|---|---|---|
| `kanji-to-reading` | Show the kanji character | The on-reading used in this word |
| `kanji-to-meaning` | Show the kanji character | The kanjidic2 meaning(s) active in this word |

The reverse facets (meaning-to-kanji, onyomi-to-kanji) are deferred. Producing
the kanji *character* as the answer makes for a harder question and a trickier
distractor pool. Ship the two forward-direction facets first and evaluate
difficulty in practice.

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

### Reading used in this word

The furigana array in `word_commitment.furigana` (a JSON array of
`FuriganaSegment`) already records which reading is used for each kanji run in
the committed form. For 図書館 read as としょかん, the segments map 図→と,
書→しょ, 館→かん. These readings are the "reading used in this word" shown in
the info card and tested by the `kanji-to-reading` facet.

### Meanings active in this word (new LLM step in prepare-publish.mjs)

kanjidic2 lists several meanings per kanji. Only a subset are active in a given
word. For example, 図 in 図書館 evokes "map / drawing / plan", not
"audacious". We need to identify the active subset.

This is analogous to the existing `llm_sense` step, which asks Haiku which
JMDict senses are used in a given corpus sentence. The new step asks Haiku which
kanjidic2 meanings for each kanji in the word are evinced by the word's JMDict
definition.

The result is stored per-word in `vocab.json` alongside the existing `llm_sense`
data. Suggested field name: `kanjiMeanings`, a map from kanji character to
an array of active meaning strings from kanjidic2.

```jsonc
// in a vocab.json word entry
"kanjiMeanings": {
  "図": ["map", "drawing", "plan"],
  "書": ["write"],
  "館": ["building", "large building"]
}
```

This is a bounded, cheap prompt (one word, 2–4 kanji, a few meanings each).
Haiku cost per word should be very low. The step must respect the existing
`--no-llm` and `--dry-run` flags — `--dry-run` must skip all LLM calls
entirely.

---

## UI changes

### Replace the two-step kanji picker with per-kanji info cards

**Current flow (WordDetailSheet and PlantView):**
1. Toggle "Kanji" picker to "learning".
2. A separate `kanjiCharPicker` section appears showing green boxes for each
   kanji character. Tap to select/deselect.

**Proposed flow:**
- Remove the `kanjiStateControl` Picker and `kanjiCharPicker` from both views.
- In their place, render one **kanji info card** per kanji character in the
  committed form.
- Each card is tappable to enroll (or unenroll) that kanji.
- Enrolled cards are visually highlighted (matching the existing green-box
  pattern or a refined version of it).

### Kanji info card contents

Each card shows two zones:

**This word** (what this kanji is doing here):
- The kanji character, large
- The reading used in this word, highlighted (from the furigana array)
- The kanjidic2 meanings active in this word (from `kanjiMeanings` in
  vocab.json, populated by the new LLM step)

**This kanji in general** (omit if all data is identical to "this word" data):
- Top on-reading from kanjidic2 (shown if different from the reading used in this word, or always shown for completeness if the reading used is kun)
- Top kun-reading from kanjidic2 (shown if different from the reading used in this word, or always shown for completeness if the reading used is on)
- Top 2 kanjidic2 meanings, if different from the active meanings shown above

**Extra disclosure**:
- "Also learning this kanji in: 図形, 地図" — a list of other enrolled words
  that share this kanji. Tapping on those will raise a new WordDetailSheet
  for that word (potentially with null origin, so the new sheet may show
  full-corpus senses, instead of the senses in any one document/sentence).

---

## Quiz architecture additions

### Facet: kanji-to-reading

- **Question stem**: the kanji character (large, centered), by itself — NO parent word context
- **Expected answer**: the reading used in this word (on or kun, depending on `word_commitment.furigana`). For example, 食 in 食べる tests the kun-reading たべ; 食 in 食堂 tests the on-reading しょく. These are independent Ebisu entries.
- **Multiple choice distractors** (from kanjidic2, no LLM):
  - On/kun readings of visually or linguistically similar kanji (use kanjidic2 radicals to find candidates)
  - Readings of other kanji in the same word (realistic confusion)
  - **CRITICAL: DO NOT include other valid readings of the kanji under test.** For example, if testing 食's kun-reading たべ, do not offer しょく (the on-reading) as a distractor, even though it's a valid reading of 食. The Ebisu entry is for *this specific reading in this specific word*, not the kanji in general.
- **Format**: always multiple choice (like vocab `reading-to-meaning`). Free-text kanji readings are deferred to future work.
- **Multi-reading ambiguity handling**: If the learner is enrolled in the same kanji with different readings (e.g., 食 via 食べる and 食 via 食堂), the quiz always tests the reading for the specific `word_id`. If the learner enters a reading that's valid for the kanji but not for this entry, the app can offer smart feedback: "That's a valid reading of 食, but in 食べる we're learning たべ. Try again?" This prevents false positives without penalizing near-misses.

### Facet: kanji-to-meaning

- **Question stem**: the kanji character, large and centered — NO parent word context
- **Expected answer**: one or more of the active kanjidic2 meanings for this word (match any). For example, 図 in 図書館 accepts "map", "drawing", or "plan" as correct, but not "audacious".
- **Multiple choice distractors** (from kanjidic2, no LLM):
  - Meanings from other kanji in the same word (realistic confusion)
  - Meanings from visually or linguistically similar kanji (found via radicals or manual curation)
  - **DO NOT use other meanings from the same kanji.** The Ebisu entry is for the active meanings in this specific word, not the full kanjidic2 inventory. Using all kanjidic2 meanings as distractors would make the question answerable even without enrolling.
- **Format**: always multiple choice (meanings are English words/phrases, not character production). The task is similar to grading vocab `reading-to-meaning` quizzes, which Haiku already handles well in the tutor chat, so app-side grading should be straightforward.

---

## Work plan

### ✅ Step 1 — kanjidic2 data available in app

- [x] Confirm kanjidic2.sqlite is bundled in the app and accessible
- [x] Verify `lookup_kanjidic` tool is already implemented in ToolHandler.swift

### ✅ Step 2 — kanjiMeanings LLM step in prepare-publish.mjs

- [x] Design Haiku prompt to identify active kanjidic2 meanings per word
- [x] Implement `buildKanjiMeaningsPrompt` function
- [x] Implement `analyzeKanjiMeanings` function with Haiku API call
- [x] Add kanjiMeanings analysis section to prepare-publish.mjs pipeline
- [x] Load/cache existing kanjiMeanings from vocab.json
- [x] Add `--dry-run` flag support (skips all LLM calls and file writes)
- [x] Respect `--no-llm` flag for cached results only
- [x] Store results as `kanjiMeanings` in vocab.json
- [x] Code tested and compiles without errors
- [x] Run analysis on full corpus and verify Haiku output quality

### ✅ Step 3 — Implement KanjiInfoCard UI

- [x] Create `KanjiInfoCard` SwiftUI view component
  - Display: kanji character (large), reading used in this word, active meanings
  - Display: top on/kun readings if different, top 2 meanings if different
  - Display: "Also learning in: [other words]" disclosure (tappable)
- [x] Wire to kanjidic2 database for reading/meaning lookups
- [x] Implement tap gesture for enrollment toggle
- [x] Connect to existing `toggleKanjiChar` / `setKanjiState` logic

### ✅ Step 4 — Update WordDetailSheet & PlantView

- [x] Replace `kanjiStateControl` Picker + `kanjiCharPicker` in WordDetailSheet
  - Remove the two-step flow
  - Render `KanjiInfoCard` per kanji character in committed form
  - Make cards directly tappable to enroll/unenroll
- [x] Replicate same UI in PlantView for planting phase
- [x] Verify no regression in other word detail features (build succeeds)

### ⏳ Step 5 — Implement kanji quiz facets

- [ ] Add `kanji-to-reading` and `kanji-to-meaning` to quiz facet enum
  - word_type: `"kanji"`, word_id: `{kanjiChar}:{jmdictId}`
  - Both facets: always multiple choice
- [ ] Implement question stems (no LLM needed)
  - `kanji-to-reading`: kanji character alone, no parent word
  - `kanji-to-meaning`: kanji character alone, no parent word
- [ ] Implement distractor generation (from kanjidic2, no LLM)
  - `kanji-to-reading`: on/kun of similar kanji + other kanji in word; exclude other readings of test kanji
  - `kanji-to-meaning`: meanings from other kanji in word + visually similar kanji
- [ ] Wire into Ebisu scheduling with `{kanjiChar}:{jmdictId}` word_id
- [ ] Add multi-reading ambiguity detection and smart grading

### ⏳ Step 6 — Documentation & refinement

- [ ] Update docs/DATA-FORMATS.md
  - Document `kanjiMeanings` field in vocab.json entry
  - Document `word_id` format for kanji quiz entries (`{kanjiChar}:{jmdictId}`)
  - Document kanji quiz facets in reviews/ebisu_models schema
- [ ] Update docs/quiz-architecture.md with kanji facet specs
- [ ] Update docs/feature-parity.md with kanji quiz requirements
- [ ] Add kanji quiz to TestHarness (or note they have no LLM prompts)
