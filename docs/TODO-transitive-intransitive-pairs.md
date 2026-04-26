# Transitive/Intransitive Verb Pairs Feature

## Problem

During conversation, the user reaches for the wrong member of a transitive/intransitive pair (e.g. 壊す/壊れる, 開ける/開く). The goal is systematic drilling that builds mnemonics distinguishing the two forms.

## Quiz design (chosen approach)

A dedicated pairs system that stands alone but integrates visually into the vocab browser. Key properties:

- A `transitive_pairs` data source (JSON file, parallel to `grammar-equivalences.json`) with curated pairs
- Explicit enrollment: user browses and enrolls pairs intentionally (no silent auto-enrollment)
- Per-pair Ebisu rows stored in the existing `ebisu_models` table — no schema changes required
- Quiz UI: two answer fields on one card (transitive and intransitive simultaneously, not sequential), using agency cues such as "I ___ it" → type 壊す, "it ___ed" → type 壊れる
- Pairs appear as the first section in the vocab browser
- Word detail sheets link to their pair partner (and vice versa)
- Reviewing a pair triggers a full Ebisu update on both individual JMDict word models (if enrolled as plain vocab)
- Reviewing an individual vocab word triggers a passive Ebisu update on the pair model, to avoid immediately re-asking the pair question after the user has just reviewed both individual words

## Data source

~56 core verb pairs in `transitive-intransitive/transitive-pairs.json` (Opus-selected for frequency and pedagogical value from a ~230-pair candidate pool in `all-transitive-pairs.json`). The candidate pool was assembled from [sljfaq.org](https://www.sljfaq.org/afaq/jitadoushi.html) (154 linguist-curated pairs) and a filtered [Anki deck](https://ankiweb.net/shared/info/92409330), enriched with JMDict IDs (verified against definitions at build time), and reviewed by Opus which classified each as VALID or AMBIGUOUS. 12 BAD_PAIRs were evicted; 18 AMBIGUOUS pairs are retained with `ambiguousReason` notes.

### Data invariants

1. **JMDict ID validity**: every `jmdictId` resolves to an entry in `jmdict.sqlite`.
2. **Kanji exists in JMDict**: every string in a verb's `kanji` array is present in the JMDict entry's `kanji[].text` list.
3. **Kana exists in JMDict**: every verb's `kana` string is present in the JMDict entry's `kana[].text` list.
4. **Kana applies to chosen kanji**: for each verb, the JMDict kana entry's `appliesToKanji` field either is `["*"]` or explicitly includes every kanji in the verb's `kanji` array. This guarantees the kana/kanji combination is a valid reading according to JMDict, not an unrelated homophone.
5. **One kanji per verb**: each verb has exactly one kanji form — the one that best represents the transitive/intransitive pairing (shared kanji stem with its partner, preferring common forms, filtering out irregular `iK`, rare `rK`, and search-only `sK` tagged forms).
6. **Shared kanji stem**: for most pairs, the chosen kanji forms share at least one CJK ideograph (e.g. 上がる/上げる both share 上). Pairs where the verbs use genuinely different kanji (e.g. 治る/直す, 腫れる/晴らす) are handled via manual overrides with explanatory comments.
7. **Manual overrides for ambiguous kanji**: 13 pairs where the algorithm can't pick the right kanji automatically (e.g. あらわれる could be 現れる or 表れる) have explicit overrides in the `OVERRIDES` table, each with a comment explaining the choice.

### JSON schema

Each entry in `transitive-pairs.json`:

```json
{
  "intransitive": { "kana": "あがる", "jmdictId": "1352290", "kanji": ["上がる"] },
  "transitive":   { "kana": "あげる", "jmdictId": "1352320", "kanji": ["上げる"] },
  "examples": {
    "intransitive": "気温が上がった。 — The temperature rose.",
    "transitive": "手を上げてください。 — Please raise your hand."
  },
  "ambiguousReason": null
}
```

`ambiguousReason` is a string explaining the ambiguity, or `null` for clean pairs. For the initial implementation, only pairs where `ambiguousReason` is `null` should be enrollable.

## Decisions made

1. **Data model**: ✅ `transitive-pairs.json` with JMDict IDs verified against definitions
2. **AMBIGUOUS pairs**: ✅ Ship with unambiguous pairs only; ambiguous pairs visible but not enrollable initially
3. **Enrollment UI**: implementation plan below

## Implementation plan: enrollment UI (step 3)

### 3a. TransitivePairSync.swift (new file)

Mirror `GrammarSync.swift`. URL derived from vocab URL by replacing `vocab.json` → `transitive-pairs.json`. Download + cache to `Documents/transitive-pairs.json`.

Codable types:

```swift
struct TransitivePairMember: Codable {
    let kana: String
    let jmdictId: String
    let kanji: [String]
}

struct TransitivePairExamples: Codable {
    let intransitive: String?
    let transitive: String?
}

struct TransitivePair: Codable, Identifiable {
    let intransitive: TransitivePairMember
    let transitive: TransitivePairMember
    let examples: TransitivePairExamples
    let ambiguousReason: String?

    var id: String { "\(intransitive.jmdictId)-\(transitive.jmdictId)" }
    var isAmbiguous: Bool { ambiguousReason != nil }
}
```

### 3b. TransitivePairCorpus.swift (new file)

Simplified version of `VocabCorpus`. `@Observable @MainActor final class TransitivePairCorpus`:

- `items: [TransitivePairItem]` — each wraps a `TransitivePair` plus a `FacetState` (unknown/learning/known)
- `load(db:download:)` — sync/cache, then query `ebisu_models` and `learned` tables for `word_type="transitive-pair"` to derive state per pair
- `setPairLearning(pairId:db:)` — inserts one `ebisu_models` row with `word_type="transitive-pair"`, `quiz_type="pair-discrimination"`
- `setPairKnown(pairId:db:)` and `clearPair(pairId:db:)` — analogous to vocab
- No `word_commitment` needed — pairs don't need furigana picker or kanji commitment; the pair is the enrollable unit

### 3c. VocabBrowserView.swift changes

Prepend a "Transitive-Intransitive Pairs" `DisclosureGroup` as the **first section** in `groupedWordList`, before the existing `ForEach(roots)` loop.

- Each row shows both verbs side by side (e.g. "上がる ↔ 上げる　あがる ↔ あげる") with a status badge
- Swipe actions: Learn / Know it / Undo — same pattern as vocab words, calling `pairCorpus` methods
- Search applies to pairs too (match kana/kanji of either member)
- State filter (Not yet learning / Learning / Learned) applies to pairs
- Ambiguous pairs shown but with enrollment disabled

### 3d. TransitivePairDetailSheet.swift (new file)

- Both verbs with all kanji forms
- Example sentences from JSON
- Ambiguous reason note if present
- Learn / Know / Undo buttons (disabled for ambiguous pairs)

### 3e. Wire up in PugApp.swift

Create `TransitivePairCorpus`, load it alongside vocab corpus during app startup, pass to `VocabBrowserView`.

### 3f. publish.mjs

Add `transitive-pairs.json` to the gist publish pipeline alongside vocab.json, grammar.json, and grammar-equivalences.json.

### 3g. Ebisu details

- `word_type = "transitive-pair"`
- `word_id = "{intransitive_jmdict_id}-{transitive_jmdict_id}"` (e.g. `"1352290-1352320"`)
- `quiz_type = "pair-discrimination"` (one facet per pair)
- No schema changes — reuses existing `ebisu_models` / `learned` tables

## Step 4: Implement the pair quiz card

### Design decisions

- **Pre-generated drills**: 3 drill sentence pairs per verb pair, baked into `transitive-pairs.json` at build time (no LLM call at quiz time)
- **Scoring**: 1.0 (both correct), 0.5 (one correct), 0.0 (neither correct)
- **Integration**: pairs mixed into the regular vocab quiz queue via QuizContext, not a separate quiz mode
- **No LLM calls** for question generation or grading — only for optional post-quiz coaching ("Tutor me")

### Drill data format

Each pair gains a `drills` array in `transitive-pairs.json`:

```json
{
  "intransitive": { "kana": "あく", "jmdictId": "...", "kanji": ["開く"] },
  "transitive": { "kana": "あける", "jmdictId": "...", "kanji": ["開ける"] },
  "examples": { ... },
  "ambiguousReason": null,
  "drills": [
    {
      "intransitive": { "en": "The door opened.", "ja": "ドアが開いた。" },
      "transitive": { "en": "I opened the door.", "ja": "私がドアを開けた。" }
    },
    { ... },
    { ... }
  ]
}
```

Generated via a batch Claude script that processes all unambiguous pairs, maintaining cross-pair variability by batching. Short, memorable, varied English cues; conjugated Japanese sentences for post-quiz audio playback.

### Quiz card UI

1. App picks one drill randomly from the 3
2. Shows two English sentences (agency cues), e.g. "The door opened." / "I opened the door."
3. Two input fields labeled "Dictionary form:" — student types kana, kanji, or romaji
4. Grading: pure string match against pair's `kana`, `kanji[]`, and romaji conversion
5. After grading, reveal:
   - Correct/incorrect indicator per field
   - The conjugated Japanese sentences with audio playback buttons (AVSpeechSynthesizer)
   - Chat interface available for follow-up questions
6. "Tutor me" button (on wrong answers) kicks off an LLM coaching turn explaining the distinction
7. "Don't know" row: scores 0.0, reveals answers + Japanese sentences immediately

### 4a. Generate drill sentences (batch script)

New script `.claude/scripts/generate-pair-drills.mjs` (or similar):

- Reads `transitive-pairs.json`
- Filters to unambiguous pairs (ambiguousReason === null)
- One LLM call per pair; generates 3 drill sets per pair, each using a **different scenario** (different nouns/settings)
- Each drill set is a **two-sentence mini story**: the intransitive sentence sets the scene, the transitive sentence continues the same scene with someone deliberately acting — never restating the same event, never switching to an unrelated topic
- Writes updated `transitive-pairs.json` with `drills` arrays added after each successful pair (progress is not lost on interruption)
- Validates: every unambiguous pair has exactly 3 drills, each with `en` and `ja` for both sides

### 4b. Integrate pairs into QuizContext

Modify `QuizContext.build()` to include `transitive-pair` word_type:

- Query `enrolledTransitivePairRecords()` (already exists in QuizDB)
- Build `QuizItem` entries with `wordType: "transitive-pair"`, `facet: "pair-discrimination"`
- Recall ranking works identically to vocab (same Ebisu math)
- Pair items interleave with vocab items in the sorted queue

### 4c. Extend QuizSession for pair quiz flow

Add pair-specific logic to `QuizSession` (or a small helper):

- Detect `wordType == "transitive-pair"` when advancing to next item
- Load the pair's data from `TransitivePairCorpus` by `wordId`
- Pick a random drill from the 3
- Set phase to a new pair-specific awaiting state (two text fields instead of one)
- On submit: string-match each field against accepted forms (kana, kanji[], romaji)
- Compute score: both correct → 1.0, one correct → 0.5, neither → 0.0
- Record review via existing `recordReview` with `wordType: "transitive-pair"`, `quizType: "pair-discrimination"`
- On "Tutor me": send pair context + student answers + correct answers to LLM for coaching

### 4d. PairQuizCard view

New SwiftUI view (used within QuizView or as a subview):

- Two labeled sections, each with: English cue sentence, text input field
- Submit button (enabled when both fields non-empty)
- Post-grading reveal: correct/wrong badges per field, Japanese sentences, audio buttons
- "Don't know" row at bottom
- "Tutor me" button (appears on wrong answers)
- Chat interface below (reuses existing chat components)

### 4e. Grading: string match fast path, LLM fallback

The quiz asks for dictionary forms, but students will naturally write conjugated forms (開けた, 開けて, …). Grading uses a two-phase approach:

**Fast path — pure string match:**
- Accept: kana (あける), any kanji form from the pair's `kanji` array (開ける), or a simple romaji conversion of the kana (akeru).
- If both fields match → score 1.0 instantly, no LLM call needed.
- If one or both fields fail the string match → proceed to LLM fallback for the failing field(s).

**Slow path — LLM fallback for unmatched fields:**

When the string match fails for a field, send both fields' student answers together to the LLM in a single call. The LLM grades each field independently (right verb or wrong verb — conjugation is irrelevant since the quiz tests transitive/intransitive discrimination, not conjugation).

Prompt structure (modelled on the existing vocab free-answer grading prompt in `QuizSession.swift`):

```
You are grading a transitive/intransitive verb pair quiz.
The student was shown two English cues and asked to type the dictionary form of each verb.

Pair: {intransitive.kanji[0]} ({intransitive.kana}) ↔ {transitive.kanji[0]} ({transitive.kana})
Cue for intransitive field: "{drill.intransitive.en}"
Cue for transitive field:   "{drill.transitive.en}"
Student's intransitive answer: "{studentIntransitive}"
Student's transitive answer:   "{studentTransitive}"

The quiz tests only whether the student knows which verb is transitive and which is intransitive — not conjugation accuracy. A conjugated form of the correct verb (e.g. 開けた for 開ける) is fully correct.

Emit exactly two lines, in this order:
SCORE_INTRANSITIVE: 1 or 0 — <one grading sentence>
SCORE_TRANSITIVE: 1 or 0 — <one grading sentence>

Use 1 if the student's answer is the correct verb (any conjugation, any kana/kanji/romaji surface), 0 if it is the wrong verb or blank. Do not emit partial credit.
```

App then computes the overall score:
- Both 1 → 1.0
- One 1, one 0 → 0.5
- Both 0 → 0.0

This eliminates the need for a romaji conversion utility — the LLM handles any surface form.

### 4f. Acceptance criteria

- [ ] All unambiguous pairs have 3 drill sentence pairs in JSON
- [ ] Pair items appear in vocab quiz queue ranked by Ebisu recall
- [ ] Quiz card shows two English cues, two input fields
- [ ] Grading fast path: exact string match on kana, kanji, or romaji accepts instantly without an LLM call
- [ ] Grading slow path: when fast path fails, LLM grades both fields in one call, accepting any conjugation of the correct verb; overall score is 1.0 / 0.5 / 0.0
- [ ] Post-grading shows Japanese sentences with audio playback
- [ ] "Don't know" reveals answers and scores 0.0
- [ ] "Tutor me" triggers LLM coaching on wrong/partial answers
- [ ] "Tutor me" prompt passes actual student answers + per-field results so coaching is targeted (revisit `startPairTutorSession` after 4e grading is wired up)
- [ ] Chat works after pair quiz just like vocab quiz

### Work order

4a → 4b → 4c → 4d → 4e (can be done alongside 4d)

## Future steps (after pair quiz card)

5. **Wire up Ebisu cross-updates**: on pair review, passive Ebisu update on both individual word models if enrolled; on individual word review, passive Ebisu update on any associated pair model
6. **Cross-link word detail sheets**: show pair partner info (and a tap target to it) on each word's detail sheet

---

## Step 7: Single-leg facets (`transitive` and `intransitive`)

### Motivation

The `pair-discrimination` quiz shows both English cues simultaneously, which provides scaffolding: the contrasting sentences make it easier to sort the two verbs. A single-leg quiz removes that scaffolding — the student sees one English cue and must cold-produce the correct verb, with the other verb implicitly lurking as the natural wrong answer. This is a different cognitive skill (production under isolation) and arguably more naturalistic (in real conversation you need one verb, not both at once). It is not strictly harder in all dimensions, but it exercises a distinct ability.

### Decisions

1. **All three Ebisu rows planted at enrollment**: when a pair is enrolled (or on migration for existing pairs), three rows are created in `ebisu_models`: `pair-discrimination`, `transitive`, `intransitive`. The single-leg rows use the default alpha/beta but inherit the pair-discrimination halflife so the scheduler doesn't immediately over-schedule them relative to the pair.

2. **Scheduler-level facet suppression (unlock/graduation)**: the single-leg facets exist in the database from day one but `QuizContext.build()` suppresses them from the candidate queue until `pair-discrimination` halflife ≥ `singleLegUnlockHalflife` (72 hours, ~3 days). This is different from the existing multiple-choice → free-answer graduation, which is a question-format switch within a single Ebisu model checked at generation time. Here the suppression is cross-facet, enforced at scheduling time. The threshold is intentionally low and can be tuned after real-world usage.

3. **After unlock, all three facets compete normally**: the scheduler picks the most-urgent facet among the three for each enrolled pair. There is no retirement of `pair-discrimination` after unlock.

4. **Passive cross-updates**: after any pair facet review, the other pair facets receive passive Ebisu updates (score = 0.5) via the existing `passiveMap` mechanism:
   - `pair-discrimination` → passively updates `transitive` and `intransitive` (both legs revealed)
   - `transitive` → passively updates `pair-discrimination` (one leg demonstrated)
   - `intransitive` → passively updates `pair-discrimination` (one leg demonstrated)
   Single-leg facets do NOT passively update each other: answering a `transitive` quiz does not reveal the intransitive verb.

5. **Partial pair scores (0.5) are left as-is**: when a `pair-discrimination` quiz is scored 0.5 (one leg correct), the pair model is updated with 0.5 as before. The passive update to the single-leg models still fires at 0.5 regardless of the pair score. This is the simplest consistent behavior.

6. **Single-leg scoring**: 1.0 or 0.0 only (no partial credit — there is only one field). Grading uses the same fast path (kana/kanji/romaji string match) and LLM slow path as `pair-discrimination`.

### Implementation plan

#### 7a. QuizDB migration v13

For every existing `ebisu_models` row with `word_type = "transitive-pair"` and `quiz_type = "pair-discrimination"`, insert `transitive` and `intransitive` rows with:
- `alpha = 4.0, beta = 4.0` (default new-card shape)
- `t` = pair-discrimination's current `t` (inherit halflife so the single-legs start at the same maturity level as the pair)
- `last_review` = now

`setFacetLearning` already guards against duplicate inserts, so this migration is idempotent if re-run.

#### 7b. TransitivePairCorpus: plant all three rows at enrollment

`setPairLearning` currently calls `setFacetLearning` once with `quiz_type = "pair-discrimination"`. Change it to call `setFacetLearning` three times: `pair-discrimination`, `transitive`, `intransitive`, all with the same default halflife (24h). The single-leg rows will start at 24h halflife alongside the pair, so they will be suppressed by the scheduler until the pair matures past 72h.

`clearPair` and `setPairKnown` must also handle all three facets.

#### 7c. QuizContext.build(): unlock-aware pair scheduling

Replace the current flat per-pair loop with a grouped approach:

1. Group all `word_type = "transitive-pair"` Ebisu records by `wordId`.
2. For each pair, find the `pair-discrimination` record.
3. If its halflife < `singleLegUnlockHalflife` (72h): build a `QuizItem` for `pair-discrimination` only.
4. If its halflife ≥ threshold: consider all three facets, pick the most-urgent (lowest predicted recall).
5. The chosen facet is stored in `QuizItem.facet` as `"pair-discrimination"`, `"transitive"`, or `"intransitive"`.

Constant: `static let singleLegUnlockHalflife = 72.0` hours.

#### 7d. QuizSession.PairQuestion: add `askedLeg`

Add an `askedLeg: AskedLeg?` field to `PairQuestion`. `nil` = both legs (pair-discrimination). `AskedLeg` is:

```swift
enum AskedLeg: Equatable { case transitive, intransitive }
```

Existing pair-discrimination code passes `askedLeg: nil`.

#### 7e. QuizSession: generateQuestion and prefetchQuestion

When `item.facet == "transitive"` or `item.facet == "intransitive"`, build a `PairQuestion` with `askedLeg` set to the matching case. The drill is selected the same way as `pair-discrimination` (random from the 3 drills). The `PairQuestion` still carries both verbs' kana/kanji/Japanese fields — the view and grader use `askedLeg` to know which leg to display/evaluate.

Set `phase = .awaitingPair(q)` as before (no new phase case needed).

#### 7f. QuizSession: submitPairAnswer and passiveMap

`submitPairAnswer` currently grades both fields. Extend it to check `pairQuestion.askedLeg`:
- `nil` → grade both fields (existing logic, score 1.0 / 0.5 / 0.0)
- `.intransitive` → grade only the intransitive field; score 1.0 or 0.0; ignore the transitive input
- `.transitive` → grade only the transitive field; score 1.0 or 0.0; ignore the intransitive input

Extend `passiveMap` with the pair facets:
```swift
"pair-discrimination": ["transitive", "intransitive"],
"transitive":          ["pair-discrimination"],
"intransitive":        ["pair-discrimination"],
```

The existing `applyPassiveUpdates` already uses `item.wordType` and `item.wordId`, so it will correctly look up `word_type = "transitive-pair"` rows without any further changes.

#### 7g. QuizView: single-leg card rendering

`awaitingPairView` currently renders two cue/field pairs unconditionally. Extend it to check `pairQuestion.askedLeg`:
- `nil` → existing two-field layout, facet badge shows `"pair-discrimination"`
- `.intransitive` → render only the intransitive cue + field; badge shows `"intransitive"`
- `.transitive` → render only the transitive cue + field; badge shows `"transitive"`

The graded-result reveal (after submission, in `.chatting` phase) currently shows both Japanese sentences via `lastPairQuestion`. For single-leg, still show both Japanese sentences in the reveal — seeing the paired sentence in context after answering just one leg reinforces the distinction.

### Work order

7a → 7b → 7c → 7d → 7e → 7f → 7g

## Appendix: Enrolling new pairs from all-transitive-pairs.json

The curated `transitive-pairs.json` is a subset of the candidate pool in `all-transitive-pairs.json`. To promote a pair:

### Prerequisites

Verify the pair in `all-transitive-pairs.json` has `ambiguousReason: null`. If it has an `ambiguousReason` string, clear it only if you've confirmed the ambiguity doesn't affect the core transitive/intransitive distinction.

### Enrollment steps

**Step 1: Copy the object manually**

Find the pair in `all-transitive-pairs.json` and copy its JSON object into `transitive-pairs.json`. The `drills` and `jaFurigana` fields will be added by the next two steps.

**Step 2: Generate drills**

```bash
node .claude/scripts/generate-pair-drills.mjs --generate --limit 1
```

This generates drills for any unambiguous pair in `transitive-pairs.json` that lacks them.

**Step 3: Add furigana**

```bash
node .claude/scripts/generate-pair-drills.mjs --add-furigana
```

This fills in `jaFurigana` for any drill sentence that lacks it, hitting the local REST endpoint at `http://127.0.0.1:8133/api/v1/sentence/`.

### Editing a drill after enrollment

Edit `en`/`ja` fields directly in `transitive-pairs.json`. If you change a `ja` sentence, delete its `jaFurigana` field and re-run `--add-furigana` to regenerate it.
