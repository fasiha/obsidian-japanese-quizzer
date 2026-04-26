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
the parent JMDict ID and the kanji character. Format:

```
{jmdictId}:{kanjiChar}
```

Example: `1588120:図` for 図 as learned via 図書館 (JMDict ID 1588120).

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

The iOS app will need kanjidic2.sqlite bundled alongside jmdict.sqlite, or its
data merged into jmdict.sqlite. **TBD: decide on bundling strategy.**

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
data. Suggested field name: `kanji_meanings`, a map from kanji character to
an array of active meaning strings from kanjidic2.

```jsonc
// in a vocab.json word entry
"kanji_meanings": {
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
- The reading used in this word (from the furigana array)
- The kanjidic2 meanings active in this word (from `kanji_meanings` in
  vocab.json, populated by the new LLM step)

**This kanji in general** (omit if identical to "this word" data):
- Top on-reading from kanjidic2, if different from the reading used here
- Top kun-reading from kanjidic2, if different from the reading used here
- Top 2 kanjidic2 meanings, if different from the active meanings shown above

**Optional disclosure** (future, not blocking):
- "Also learning this kanji in: 図形, 地図" — a list of other enrolled words
  that share this kanji, purely informational.

---

## Quiz architecture additions

### Facet: kanji-to-reading

- **Question stem**: the kanji character (large, centered), with the parent word
  shown small below as context ("as used in 図書館")
- **Expected answer**: the on-reading used in this word (e.g., "ズ")
- **Multiple choice distractors**: other on-readings of the same kanji (e.g.,
  "ト"), plus on-readings of visually similar kanji — sourced from kanjidic2
  without LLM
- **Graduation to free-answer**: same rule as other facets (≥ 3 reviews and
  halflife ≥ 48 hours)

### Facet: kanji-to-meaning

- **Question stem**: the kanji character, with parent word as context
- **Expected answer**: one or more of the active kanjidic2 meanings for this
  word (match any)
- **Multiple choice distractors**: other meanings from kanjidic2 for the same
  kanji, plus meanings from other kanji in the same word
- **Format**: always multiple choice (meanings are English words/phrases, not
  character production)

---

## Work plan

### Step 1 — kanjidic2 data available in app (prerequisite for everything)

- [ ] Decide: bundle `kanjidic2.sqlite` separately, or import its `kanji` table
  into `jmdict.sqlite` as a new table. Separate file keeps concerns separated;
  merged file reduces bundle count. Either works; pick one.
- [ ] Add the chosen data source to the Xcode target and document it in
  `docs/DATA-FORMATS.md`.

### Step 2 — kanji_meanings LLM step in prepare-publish.mjs

- [ ] Design the Haiku prompt: given a JMDict word (with definition and example
  sentence from corpus), and for each kanji in the word a list of kanjidic2
  meanings, ask Haiku to return the subset of meanings active in this word.
- [ ] Add the step to the prepare-publish.mjs pipeline, respecting `--no-llm`
  and `--dry-run`.
- [ ] Store results as `kanji_meanings` in `vocab.json`.
- [ ] Manually verify results on 5–10 words before wiring to UI.

### Step 3 — kanji info card UI

- [ ] Implement `KanjiInfoCard` view in SwiftUI, accepting a kanji character,
  its kanjidic2 row, the reading used in this word, and the active meanings.
- [ ] Replace `kanjiStateControl` + `kanjiCharPicker` in `WordDetailSheet` with
  a `ForEach` over the word's kanji producing `KanjiInfoCard` views.
- [ ] Wire the tap gesture to the existing `toggleKanjiChar` / `setKanjiState`
  logic.
- [ ] Replicate the same card layout in `PlantView` for the planting phase.

### Step 4 — kanji quiz facets

- [ ] Add `kanji-to-reading` and `kanji-to-meaning` to the quiz facet
  enumeration and to `docs/quiz-architecture.md`.
- [ ] Implement question-stem builders (no LLM needed; all data from kanjidic2
  and the furigana array).
- [ ] Implement distractor generation (sourced from kanjidic2, no LLM).
- [ ] Wire into the Ebisu scheduling loop using the `{jmdictId}:{kanjiChar}`
  word_id scheme.
- [ ] Add to `docs/DATA-FORMATS.md`: the new word_id format and the
  `kanji_meanings` vocab.json field.

### Step 5 — feature parity and docs

- [ ] Update `docs/feature-parity.md` with required behaviors for kanji quiz
  views and the kanji info card.
- [ ] Add kanji quiz facets to the TestHarness `--dump-prompts` sweep (or note
  that they have no LLM prompts and are excluded).
