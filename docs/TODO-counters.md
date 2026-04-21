# Counters and Numbers Quiz

## Motivation

Counting in Japanese requires two compounding skills that we can drill:

1. **Counter selection** — knowing that pencils use 本 (ほん), animals use 匹 (ひき), flat things use 枚 (まい), etc.
2. **Phonetic modification** — knowing that 6+本 is ろっぽん (not ろくほん), or that 3+匹 is さんびき (not さんひき).

Pug should have custom question generation for each number+counter combination. With pre-compiled pronunciation table per counter, this is now tractable.

Additionally, **wago (native Japanese numbers)**: ひとつ、ふたつ、みっつ… through とお are a separate, self-contained skill. They appear in literary content and conversation and should get dedicated drill time.

---

## Key Design Decisions

### Counters are a new `word_type`, not overloaded onto `word_type="jmdict"`

Early designs tried to enroll counters as ordinary `word_type="jmdict"` vocab words and detect counter status at runtime by checking whether the word's JMDict ID appears in `counters.json`. This was abandoned for three reasons:

1. **Ebisu key collision** — a word like 本 has both a "book" meaning and a "cylindrical objects" counter meaning sharing the same JMDict ID. The Ebisu model key `(word_type, word_id, quiz_type)` would conflate quiz performance across the two entirely different meanings.
2. **Dual-context counters** — 月 has two TSV rows (つき duration months vs. がつ calendar months) and 組 has two rows (groups vs. classroom numbers), both pairs sharing a single JMDict ID. A new `word_type` gives each row its own stable `word_id`.
3. **No-counter-sense entries** — five counters in the top-66 scope (番、秒、便、部屋、文字) have JMDict entries but no `ctr` part-of-speech tag. They need a JMDict reference for the detail sheet but cannot be anchored to a counter sense index.

Each `counters.json` entry carries a stable `id` (kana-based, unique across all entries) that serves as `word_id` in the Ebisu model key `(word_type="counter", word_id="{id}", quiz_type="…")`.

Enrollment still flows through the existing Markdown reading workflow — a `counters-must-know.md` file references counter IDs, and the user enrolls them by reading and committing as usual.

### Facet design — production only, two facets

The target skill is production during conversation: given what you want to count, produce the right counter with the right pronunciation. This scopes to exactly two facets:

| Facet | Prompt | Answer | Notes |
|---|---|---|---|
| `meaning-to-reading` | "small animal counter" (`whatItCounts`) or one example item (from `countExamples`) | ひき | tests counter selection only, no number |
| `counter-number-to-reading` | 6 + <ruby>匹<rt>ひき</rt></ruby> | ろっぴき | **new facet**; number drawn at quiz time from the hard ones (1, 3, etc.) |

**Why `meaning-to-reading` does not include a number:** injecting a number would conflate counter selection with phonetic modification — a single Ebisu model cannot distinguish which skill failed. Keeping them separate allows targeted remediation.

**Why `counter-number-to-reading` is kanji-gated:** the prompt must show the counter unambiguously. Showing the kana reading (ひき) leaks the answer — the student sees the h- initial and can apply the rendaku rule mechanically. Showing the kanji (匹) is opaque until the student knows it.

**Number sampling for `counter-number-to-reading`:** draw from {1, 3, 6, 8, 10} (and ignore {2, 4, 5, 7, 9}, since phonetically interesting modifications only occur on the former set). The Ebisu model tracks overall mastery of the counter's phonetic pattern, not per-number mastery.

**Out of scope for version 1** (enumerate as future work if desired): `reading-to-meaning` (recognition, not production), `kanji-to-reading` (same answer as `meaning-to-reading`, different prompt), `meaning-reading-to-kanji` (kanji writing).

### Pronunciation encoding in `counters.json`

The Tofugu TSV uses two distinct conventions in each pronunciation cell:

- **Space-separated** (no parens) — equally valid alternates, no preference (e.g. `はっぽん はちほん` for 8本)
- **Parenthesized** — rare or less-preferred variant (e.g. `ななほん (しちほん)` for 7本, `じっぽん` in `じゅっぽん (じっぽん)`)

The `pronunciations` values in `counters.json` are therefore parsed into structured objects:

```json
"8": { "primary": ["はっぽん", "はちほん"], "rare": [] },
"7": { "primary": ["ななほん"], "rare": ["しちほん"] }
```

The quiz engine accepts any `primary` reading as correct. `rare` readings may optionally be accepted but are not shown in the prompt or as distractors.

### Wago is a Markdown reading file, not a special corpus

The ten wago forms (一つ through 十, plus the standalone とお) are a fixed, closed set. All are in JMDict. The right treatment is a short Markdown reading file (like our other story/lyrics content) with the ten words enrolled as normal vocab. No new infrastructure needed.

---

## `counters.json` schema

```json
{
  "id": "ほん",
  "kanji": "本",
  "reading": "ほん",
  "category": "Must Know",
  "whatItCounts": "Long, cylindrical things",
  "countExamples": ["pens", "asparagus", "..."],
  "jmdict": {
    "id": "1522150",
    "senseIndex": 4
  },
  "pronunciations": {
    "1": { "primary": ["いっぽん"], "rare": [] },
    "7": { "primary": ["ななほん"], "rare": ["しちほん"] },
    "8": { "primary": ["はっぽん", "はちほん"], "rare": [] },
    "how-many": { "primary": ["なんぼん"], "rare": [] }
  }
}
```

- `id` — stable kana-based word_id for Ebisu models; unique across all entries. For entries whose reading collides with a more common word, a kanji suffix is appended (e.g. `かい-階` for floors, `かん-巻` for volumes). For 組's two contexts, descriptive suffixes are used (`くみ-グループ`, `くみ-クラス`).
- `countExamples` — initially empty; fill in manually from the Tofugu article for each counter (e.g. for 台: "playground slides, beds, tables, couches, harps, pianos, cellos, cars, trucks, motors, washing machines, dryers, ovens, air conditioners, microwaves, cellular phones, keyboards, and more").
- `jmdict` — `null` if no JMDict entry exists. `senseIndex` is an array of 0-based indices of the counter senses in the JMDict entry, or `null` if the entry exists but JMDict has no `ctr`-tagged sense (the "no-counter-sense" case: 番、秒、便、部屋、文字). Most entries have exactly one index. 着 is the only current exception with two indices (`[1, 2]`), because it counts both clothing items and race placements.

---

## Data Sources

### Tofugu TSV (`counters/TofuguList.tsv`)

351 rows, hand-authored by Tofugu. Each row contains:
- Kanji, reading, what it counts, frequency category (Absolutely Must Know / Must Know / Common / Somewhat Common / Rare / Gairaigo)
- Full 1–10 pronunciation table, including space-separated equal alternates and parenthesized rare forms
- A "How Many" (何+counter) column
- Link to a special Tofugu article for some counters

This is the authoritative source for `counters.json`. We do not need to classify counters into DBJG phonetic types and regenerate pronunciations algorithmically — the TSV already has every cell filled in.

### DBJG appendix (`counters/counters-613.jpg` through `counters-616.jpg`)

Provides a pedagogically useful type classification (Type A through F plus irregular types). Useful for explanatory text in WordDetailSheet ("this counter follows the Type B pattern: h→p with 1, 6, 8, 10") but not needed for quiz generation.

### Tofugu frequency groupings (`counters/tofugu-350.json`)

| Group | Count |
|---|---|
| Absolutely Must Know | 2 |
| Must Know | 17 |
| Common | 47 |
| Somewhat Common | 205 |
| Rare But Interesting | 22 |
| Gairaigo | 57 |

**Scope for version 1:** the top three tiers (2 + 17 + 47 = 66 counters). The Somewhat Common and below tiers may include obscure kanji not in JMDict; punted to a future version.

---

## Known Unknowns

1. **~~JMDict coverage of the 66 counters~~** — resolved. `build-counters-json.mjs` looks up all 66 via `ctr` part-of-speech filtering plus a manual override map. All 66 resolved. Five entries have `jmdict.senseIndex === null` (no counter-tagged sense in JMDict): 番、秒、便、部屋、文字.

2. **~~Multiple `counters.json` entries sharing the same JMDict ID~~** — resolved. Each TSV row gets its own stable `id` derived from the reading. Collisions between distinct counters sharing a reading (e.g. 階 vs 回, both かい) are resolved by appending the kanji: `かい-階`. The two 組 rows get descriptive suffixes: `くみ-グループ` and `くみ-クラス`. The Ebisu model key `(word_type="counter", word_id="{id}", quiz_type="…")` is unambiguous for all 66 entries.

3. **~~Alternate readings in the TSV~~** — resolved. Space-separated entries are equal alternates (all `primary`); parenthesized entries are rare variants. The `pronunciations` field stores `{ primary: string[], rare: string[] }` per number. The quiz engine accepts any `primary` reading as correct.

4. **`countExamples` population** — `build-counters-json.mjs` writes `countExamples: []` for every entry. These should be filled in manually from each counter's Tofugu article. Not blocking for quiz functionality, but useful for WordDetailSheet and future quiz prompt enrichment.

5. **Markdown reading files** — need to author: (a) a wago file (10 words, trivial), (b) a must-know counters file (19 counters), (c) a common counters file (47 counters). These are the enrollment vehicle — counters only enter the quiz queue when a user reads and commits to the word.

6. **WordDetailSheet counter section** — when a word has `word_type="counter"`, the detail sheet should display the 1–10 pronunciation table (analogous to how transitive pairs show both verb forms). When `jmdict.senseIndex === null`, include a note that the word is used as a counter even though JMDict does not tag it as one. Design TBD.

7. **Quiz prompt wording for `counter-number-to-reading`** — multiple-choice distractors can be generated without LLM: pick three other readings from the same counter's 1–10 table (e.g. for 六匹→ろっぴき, offer いっぴき, さんびき, はっぴき). Free-answer phase: app builds stem locally, LLM grades. Needs a system prompt.

8. **`counter-number-to-reading` in TestHarness** — needs a new prompt variation enumerated in `--dump-prompts`.

9. **`pronunciations` parsing in `build-counters-json.mjs`** — ✅ resolved. Each TSV cell now parsed into `{ primary: string[], rare: string[] }`.

---

## Counter Detection in `prepare-publish.mjs` for `vocab.json`

### Where counter info lives in a vocab reference

A vocabulary reference object in `vocab.json` can carry counter information in two distinct places, depending on source:

**Manual annotation** (`- counter:id` bullet in Markdown) → stored as a **sibling to `llm_sense`**:
```json
{
  "line": 82,
  "context": "赤ちゃんは３ヶ月で笑い始めます。",
  "counter": "つき",
  "llm_sense": { "sense_indices": [1], "computed_from": [...], "reasoning": "..." }
}
```

**LLM-detected counter** → stored **inside `llm_sense`**:
```json
{
  "line": 67,
  "context": "１００枚の折り紙が必要です。",
  "llm_sense": { "sense_indices": [0], "counter": "まい", "computed_from": [...], "reasoning": "..." }
}
```

Consumers resolve the counter as: `ref.counter ?? ref.llm_sense?.counter`.

A ref never has both: if `ref.counter` is set from a manual annotation, the LLM counter-detection question is skipped entirely for that ref.

### Detection strategy

1. **Manual annotation**: `- counter:id` in a `<details><summary>Vocab</summary>` block explicitly tags a word as a counter with a known ID. This is stored in `ref.counter` (sibling to `llm_sense`) and skips LLM inference.
2. **LLM inference**: For words whose JMDict ID appears in `counters.json`, `prepare-publish.mjs` adds a counter-detection question to the sense analysis prompt. The LLM result is stored in `llm_sense.counter`.

### LLM prompt for counter detection

`countersByJmdictId` maps each JMDict ID to the array of `counters.json` entries that reference it. Most IDs have exactly one entry; a few ambiguous readings (e.g. 月 with ID 1255430) have two.

- **1 candidate**: prompt asks "Is this word being used as counter `id` (for `whatItCounts`)? If yes, respond with `id`. If not or unsure, set counter to null."
- **2+ candidates**: prompt lists all candidates by index and asks the LLM to choose the matching counter ID, or null if unsure. Example for 月: "Is this word being used as one of these counters? 0: `つき` (Months), 1: `がつ` (Calendar months)."

Three meaningful states for `llm_sense.counter`:
- **key absent** — LLM was never asked (word not counter-capable, or entry predates counter detection). Gap detection flags these.
- **`counter: null`** — LLM was asked and said "not a counter here" or "unsure which counter".
- **`counter: "id"`** — LLM confirmed counter usage and identified the counter.

### Gap detection

`prepare-publish.mjs` scans all refs after analysis and reports any counter-capable words (JMDict ID in `countersByJmdictId`) whose `llm_sense` lacks a `counter` key. These are logged per-ref and summarised at the end:

```
  Would analyze 月 [Music/Shiki no Uta:65] (potential counter sense found, counter field unevaluated)
- 1 potential counter senses found, 0 skipped
```

---

## Work Plan

### Phase 1: Data pipeline — `counters.json`

1. ✅ `.claude/scripts/build-counters-json.mjs` written and working. Uses `ctr` part-of-speech filtering to auto-resolve JMDict matches, with manual override maps for the 22 ambiguous entries and 8 reading-collision IDs.
2. ✅ All 66 counters resolved. New schema: `id`, `countExamples`, `jmdict: { id, senseIndex }`, `pronunciations` with `{ primary, rare }` objects.
3. ✅ `build-counters-json.mjs` parses TSV pronunciation cells into `{ primary, rare }` objects.
4. ✅ Commit `counters.json` to published Gist (alongside `transitive-pairs.json`): added to `filesToPublish` in `publish.mjs`.

### Phase 2: Enrollment via `prepare-publish.mjs`

5. ✅ Counter detection wired into `prepare-publish.mjs`: for any word appearing in `counters.json`, the sense analysis includes a counter-detection question.
6. ✅ LLM-detected counter stored in `llm_sense.counter`; manual `- counter:id` annotation stored as sibling `ref.counter`. Consumers check `ref.counter ?? ref.llm_sense?.counter`.
7. ✅ Counter extraction wired: `prepare-publish.mjs` collects counter enrollments from both `- counter:id` bullets and LLM-detected counter usage.
8. ✅ Update `prepare-publish.mjs` to emit counter enrollments into `corpus.json` (parallel to vocab/grammar counts).

### Phase 3: iOS — Counter enrollment and `meaning-to-reading` facet

9. Add `CounterSync.swift` (parallel to `TransitivePairSync.swift`) — downloads and caches `counters.json`.
10. Add `CounterCorpus` — loads `counters.json`, indexed by `id`. Provides lookup by `id` and by `jmdict.id`.
11. Add `CounterBrowserView` — displays all 66 counters in a browser, user can enroll by reading each counter's entry (analogous to TransitivePairBrowserView).
    a. Put the 18 "Absolutely must know" and "Must know" in a "Must know" doc (or sub-doc)
    b. Put the remaining 48 "Common" counters in a second "Common" doc after the previous one
12. Implement `meaning-to-reading` for counters: prompt is `whatItCounts`, answer is the reading. Distractors are other counter readings from the same frequency tier.

### Phase 4: iOS — `counter-number-to-reading` facet

13. Implement `counter-number-to-reading` quiz generation (kanji-committed words only):
    - Multiple choice: app draws a number, builds stem, picks three distractors from the counter's own 1–10 table.
    - Free-answer: app builds stem locally, LLM grades.
14. Add the system prompt for `counter-number-to-reading` and enumerate it in TestHarness `--dump-prompts`.

### Phase 5: iOS — WordDetailSheet counter section

15. When `word_type="counter"`, show a pronunciation table (1–10 grid) in WordDetailSheet below the existing senses section.
16. Optionally: show the DBJG type label and a one-sentence explanation of the phonetic pattern.

### Phase 6: Validation

17. Run TestHarness against `counter-number-to-reading` prompts for a representative sample of counters (Type B, Type C, irregular).
18. Manual end-to-end test in simulator: enroll 本, commit to kanji, trigger both counter facets, verify correct and incorrect answers grade correctly.
