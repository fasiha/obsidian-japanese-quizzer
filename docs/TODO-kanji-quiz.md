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
- Top 2 on-reading from kanjidic2 in katakana (highlight one if it's equivalent to this word's on reading)
- Top 2 kun-reading from kanjidic2 (highlight one if equal to this word's kun reading)
- Top 2 kanjidic2 meanings (highlight those that are also in this word's meaning)

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
  - Display: top 2 on-readings (katakana) + top 2 kun-readings (hiragana); the one used
    in this word shown at full brightness, others at secondary color
  - "Also learning in" rows rendered below the card as individual tappable rows;
    each opens a WordDetailSheet for that word (no origin, so all corpus senses highlighted)
- [x] Wire to kanjidic2 database for reading/meaning lookups
- [x] Implement tap gesture for enrollment toggle
  - Deselecting the last enrolled kanji in WordDetailSheet calls `setKanjiState(.unknown)`,
    equivalent to "don't know kanji"
- [x] Connect to existing `toggleKanjiChar` / `setKanjiState` logic

### ✅ Step 4 — Update WordDetailSheet & PlantView

- [x] Replace `kanjiStateControl` Picker + `kanjiCharPicker` in WordDetailSheet
  - Remove the two-step flow; deselect-all is now the "don't know" path
  - Render `KanjiInfoCard` per kanji character in committed form
  - Make cards directly tappable to enroll/unenroll
- [x] PlantView: remove "Learn the kanji spelling too" toggle
  - Cards shown with all deselected by default; tap to enroll, deselect-all = no kanji
  - Commit path uses `!currentIntroSelectedKanji.isEmpty` (not the removed toggle flag)
  - `currentIntroSelectedKanji` is passed as `kanjiChars` to `setKanjiState` so only
    the tapped subset is enrolled, not automatically all kanji in the form
- [x] Verify no regression in other word detail features (build succeeds)

### Decisions: KanjiInfoCard readings display

- On-readings shown as katakana, kun-readings shown as hiragana (kanjidic2 native format).
- Always show top 2 on-readings and top 2 kun-readings in the general section.
- The reading that matches the word's committed form is highlighted at full brightness;
  others shown at secondary color. This lets the learner see at a glance whether the
  word uses the common on/kun reading or an uncommon one.
- Future: a dedicated KanjiDetailSheet will be reachable via a ">" affordance on the
  right edge of the card (not yet implemented).

### ✅ Step 5 — Implement kanji quiz facets

- [x] Add `kanji-to-reading` and `kanji-to-meaning` to quiz facet enum
  - word_type: `"kanji"`, word_id: `{kanjiChar}:{jmdictId}`
  - Both facets: always multiple choice
- [x] Implement question stems (no LLM needed)
  - Stems name the parent word: "What is the reading of 図 in 図書館?"
  - **Decision:** stems include the parent word for context, contrary to the original design
    doc which said "no parent word context". Rationale: without the word, the correct reading
    is ambiguous to the student (e.g., 食 alone could be tested for たべ or しょく depending
    on which word is enrolled). Including the parent word removes that ambiguity without
    revealing the answer.
- [x] Implement distractor generation (from kanjidic2, no LLM)
  - `kanji-to-reading`: readings of other kanji in the parent word (from kanjidic2);
    falls back to kanji with similar stroke counts when the word has only one kanji.
    All valid readings of the test kanji (on + kun) are excluded from the distractor pool.
    Katakana on-readings are converted to hiragana via Unicode scalar arithmetic
    (U+30A1–U+30F6 → U+3041–U+3096). Kun-readings are stripped at the okurigana marker
    ("はか.る" → "はか").
  - `kanji-to-meaning`: meanings from other kanji in the parent word; falls back to
    stroke-count-similar kanji. All kanjidic2 meanings of the test kanji are excluded.
  - Distractor fallback: `loadKanjidicRows` issues one extra SQL query fetching up to 20
    kanji with stroke count ±2 of the test kanji (`ORDER BY RANDOM() LIMIT 20`).
    This ensures 4 choices even for single-kanji words (e.g., 食べる).
- [x] Wire into Ebisu scheduling with `{kanjiChar}:{jmdictId}` word_id
  - `QuizDB.setKanjiQuizLearning/Unknown` plant and remove both facet rows.
  - `QuizContext.build()` loads word_type="kanji" records and constructs `QuizItem`s.
  - `KanjiQuizData` struct (in QuizContext.swift) carries the reading, parent word text,
    and active meanings so `QuizSession` can build questions without additional DB calls.
  - `QuizItem.isFreeAnswer` always returns false for word_type="kanji".
- [x] Kanji quiz items flow through the vocab quiz session alongside counters and
  transitive pairs — no new quiz section or UI needed.
  - `QuizFilter.vocabOnly` naturally includes word_type="kanji" (only excludes
    "transitive-pair" and "counter").
  - `documentScope` filter correctly scopes kanji quiz items via the parent jmdictId.
- [x] `WordDetailSheet.toggleKanjiChar` plants/removes kanji quiz Ebisu rows in sync with
  kanji_chars commitment. `loadEbisuModels` loads word_type="kanji" records so they appear
  in the halflives section. `facetDisplayName` shows human-readable labels.
- [x] `systemPrompt` returns a compact coaching prompt for kanji quiz items (post-answer
  discussion only; question generation is fully app-side).
- [x] TestHarness builds cleanly (`kanjiQuizData: nil` added to its two `QuizItem` call sites).
- [ ] Multi-reading ambiguity detection and smart grading — **deferred**. The design doc
  described showing feedback like "that's a valid reading of 食, but in 食べる we're learning
  たべ." Since questions now include the parent word in the stem, ambiguity is already
  substantially reduced. Smart feedback can be added in a follow-up once real confusion
  cases are observed in practice.

#### Decisions and surprises from Step 5

**Kanji quiz is in the vocab quiz session, not a separate section.** The user confirmed
this is the right call — same architecture as counters and transitive pairs.

**Enrollment is wired in `WordDetailSheet.toggleKanjiChar`, not `VocabCorpus.setKanjiState`.**
The kanji quiz Ebisu rows (word_type="kanji") are planted/removed alongside the
word_commitment kanji_chars update. This keeps the two concerns collocated in one function
rather than buried inside the corpus model.

**The passiveMap has no entry for "kanji-to-meaning".** The `?? []` fallback already
handles it — no passive cross-updates between the two kanji facets. This is deliberate:
knowing the meaning doesn't tell you the reading and vice versa in a way that justifies
a passive 0.5 update.

**`applyMeaningBonus` is a harmless no-op for kanji quiz.** That function looks for
word_type="kanji" Ebisu records with facets "reading-to-meaning", "meaning-to-reading",
"meaning-reading-to-kanji" — none of which exist for kanji quiz — so it silently skips.
The meaning bonus does not propagate to "kanji-to-meaning". This is acceptable for now;
revisit if students seem frustrated that demonstrating meaning knowledge during a
kanji-to-reading review doesn't move the meaning facet.

**GRDB imported in QuizSession.swift.** The `loadKanjidicRows` method issues SQL directly
via the kanjidic2 `DatabaseReader`, which requires GRDB types (`Row`, `StatementArguments`).
Adding `import GRDB` to QuizSession was the simplest fix; the alternative (a helper on
`ToolHandler`) would have added an unnecessary layer.

**`StringTransform.katakanaToHiragana` does not exist** in the Foundation version
available here. Implemented as a Unicode scalar arithmetic function instead
(shifting U+30A1–U+30F6 by 0x60). This correctly converts full-width katakana only;
half-width katakana and special characters are passed through unchanged.

#### Smoke test plan for Step 5

1. **Enrollment — WordDetailSheet:**
   - Open a word detail sheet for a word with committed kanji (e.g., 図書館).
   - Tap a KanjiInfoCard to enroll 図. Verify the halflives section gains two new rows:
     "Kanji Quiz: Character → Reading" and "Kanji Quiz: Character → Meaning" with ~24 h.
   - Tap again to unenroll. Verify both rows disappear from the halflives section.

2. **Enrollment persistence — quiz.sqlite:**
   - After enrolling 図 in 図書館, inspect `ebisu_models` in quiz.sqlite. Expect two rows:
     `word_type="kanji", word_id="図:1588120", quiz_type="kanji-to-reading"` and
     `quiz_type="kanji-to-meaning"` (1588120 is 図書館's JMDict ID — verify the actual ID).

3. **Quiz session — kanji-to-reading:**
   - Start a vocab quiz. A kanji quiz item should appear in the session (urgency depends on
     Ebisu recall; new items start at 24 h and surface when recall drops enough).
   - To force it: rescale the kanji quiz Ebisu rows to a very short halflife via the halflives
     section in WordDetailSheet.
   - The question should read "What is the reading of 図 in 図書館?" with four hiragana choices.
   - The correct answer (と) must be one of the four choices.
   - Verify that neither ず nor any other valid reading of 図 appears as a distractor.

4. **Quiz session — kanji-to-meaning:**
   - Same setup. The question should read "What does 図 mean in 図書館?" with four English choices.
   - Correct answer must be one of the active meanings from kanjiMeanings (e.g., "map", "drawing",
     "plan").
   - Verify that "audacious" (a valid kanjidic2 meaning of 図 but not active in 図書館) does
     not appear as the correct answer.
   - Verify that meanings from 書 and 館 ("write", "building", etc.) appear as distractors.

5. **Single-kanji word (fallback distractor pool):**
   - Enroll a kanji from a single-kanji word (e.g., 食 in 食べる). Start a quiz.
   - Verify that 4 choices appear (fallback stroke-count kanji filled the pool).
   - Verify that the correct reading (たべ from the furigana) is one of the choices.

6. **Post-answer coaching:**
   - Answer a kanji quiz question and tap "Tutor me" (or let the post-answer chat appear).
   - Verify the system prompt names the kanji, the parent word, the reading, and the active meanings.
   - Verify Claude can discuss the answer without tool calls (no jmdict/kanjidic lookup needed).

7. **vocabOnly filter and documentScope:**
   - Set quiz filter to "vocab only". Verify kanji quiz items still appear in the session.
   - Open a document-scoped quiz. Verify kanji quiz items are included only if their parent
     word appears in that document.

8. **Regression — vocab kanji quiz unchanged:**
   - Verify that the existing "Kanji → Reading" (word_type="jmdict") and
     "Meaning+Reading → Kanji" facets still work correctly for enrolled vocabulary words.
   - The two quiz types share the facet name "kanji-to-reading" but use different word_types,
     so Ebisu records, reviews, and system prompts remain independent.

### ⏳ Step 6 — Documentation & refinement

- [ ] Update docs/DATA-FORMATS.md
  - Document `kanjiMeanings` field in vocab.json entry
  - Document `word_id` format for kanji quiz entries (`{kanjiChar}:{jmdictId}`)
  - Document kanji quiz facets in reviews/ebisu_models schema
- [ ] Update docs/quiz-architecture.md with kanji facet specs
- [ ] Update docs/feature-parity.md with kanji quiz requirements
- [ ] Add kanji quiz to TestHarness (or note they have no LLM prompts)
  - No LLM prompts to test — both facets are fully app-side. The TestHarness
    `--dump-prompts` path does not need a new prompt path; the coaching prompt is
    exercised only post-answer and has no generation variants to enumerate.
  - Consider adding a `--kanji` smoke-test mode that enrolls a test word, calls
    `buildKanjiMultipleChoice`, and prints the question + choices for visual inspection.
