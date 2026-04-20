# Counters and Numbers Quiz

## Motivation

Counting in Japanese requires two compounding skills that we can drill:

1. **Counter selection** — knowing that pencils use 本 (ほん), animals use 匹 (ひき), flat things use 枚 (まい), etc.
2. **Phonetic modification** — knowing that 6+本 is ろっぽん (not ろくほん), or that 3+匹 is さんびき (not さんひき).

Pug should have custom question generation for each number+counter combination. With pre-compiled pronunciation table per counter, this is now tractable.

Additionally, **wago (native Japanese numbers)**: ひとつ、ふたつ、みっつ… through とお are a separate, self-contained skill. They appear in literary content and conversation and should get dedicated drill time.

---

## Key Design Decisions

### Counters are vocab words, not a separate corpus

Counters like 本、匹、枚 already exist in JMDict and can be enrolled as ordinary vocab words. Rather than building a parallel CounterCorpus/CounterSync/CounterBrowserView infrastructure (as we did for transitive-intransitive pairs), we instead:

- Enroll counters as normal vocab words via the existing Markdown reading workflow
- Bundle a `counters.json` mapping JMDict IDs → counter metadata (pronunciation table for 1–10, example items to count)
- When the app detects a vocab word's JMDict ID appears in `counters.json`, it overrides quiz generation for the new `counter-pronunciation` facet

This keeps enrollment, Ebisu models, kanji commitment, and detail sheets entirely within the existing vocab infrastructure.

### Facet design

Counters use the standard four vocab facets plus one new one:

| Facet | Prompt | Answer | Notes |
|---|---|---|---|
| `reading-to-meaning` | ひき | "small animal counter" | unchanged from vocab |
| `meaning-to-reading` | "small animal counter" | ひき | unchanged — tests counter selection only, no number |
| `kanji-to-reading` | 匹 | ひき | kanji-committed only, unchanged |
| `meaning-reading-to-kanji` | "small animal counter" + ひき | 匹 | kanji-committed only, always multiple choice |
| `counter-pronunciation` | 6 + 匹 | ろっぴき | **new**; kanji-committed only; number drawn at quiz time |

**Why `meaning-to-reading` does not include a number:** injecting a number into this prompt would conflate counter selection with phonetic modification — a single Ebisu model cannot distinguish which skill failed. Keeping them separate allows targeted remediation.

**Why `counter-pronunciation` is kanji-gated:** the prompt must show the counter unambiguously. Showing the kana reading (ひき) in the prompt leaks the answer to the phonetic question (student sees h- initial and can apply the rule mechanically). Showing the kanji (匹) is opaque until the student knows the kanji.

**Number sampling for `counter-pronunciation`:** draw from {1, 3, 6, 8, 10} with higher weight than {2, 4, 5, 7, 9}, since the phonetically interesting modifications only occur on the former set. The exact drawn number varies each session; the Ebisu model tracks overall mastery of the counter's phonetic pattern.

### Wago is a Markdown reading file, not a special corpus

The ten wago forms (一つ through 十, plus the standalone とお) are a fixed, closed set. All are in JMDict. The right treatment is a short Markdown reading file (like our other story/lyrics content) with the ten words enrolled as normal vocab. No new infrastructure needed.

---

## Data Sources

### Tofugu TSV (`counters/TofuguList.tsv`)

351 rows, hand-authored by Tofugu. Each row contains:
- Kanji, reading, what it counts, frequency category (Absolutely Must Know / Must Know / Common / Somewhat Common / Rare / Gairaigo)
- Full 1–10 pronunciation table, including alternates (e.g. `さんわ さんば` for 羽) and parenthesized rare forms
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

**Scope for version 1:** the top three tiers (2 + 17 + 47 = 66 counters). These should all have JMDict entries. The Somewhat Common and below tiers may include obscure kanji not in JMDict; punted to a future version.

---

## Known Unknowns

1. **~~JMDict coverage of the 66 counters~~** — resolved. `build-counters-json.mjs` looks up all 66 via `ctr` part-of-speech filtering plus a manual override map. All 66 resolved, `counters.json` written to `counters/counters.json`. Each entry includes `jmdictId`, `senseIndex` (index of the first counter sense in the JMDict entry), `kanji`, `reading`, `category`, `whatItCounts`, and `pronunciations` (keys `"1"`–`"10"` and `"how-many"`).

2. **Multiple `counters.json` entries sharing the same JMDict ID** — the Tofugu TSV has two rows each for 月 and 組, because each has two distinct counting contexts with different pronunciation tables:
   - 月(つき): wago-style duration months (よつき, ここのつき…)
   - 月(がつ): calendar months with frozen irregular readings (しがつ, しちがつ, くがつ…)
   - 組(くみ): groups/pairs — uses wago for 1 and 2 (ひとくみ, ふたくみ)
   - 組(くみ): classroom numbers — uses Sino-Japanese throughout (いちくみ, にくみ)

   **Unresolved:** the `counter-pronunciation` Ebisu model is keyed `(word_type="jmdict", word_id="{jmdictId}", quiz_type="counter-pronunciation")`. With two contexts sharing the same jmdictId, the key collides. Candidate solution: encode the context into `quiz_type`, e.g. `counter-pronunciation-がつ` and `counter-pronunciation-つき`. This requires a stable `facetSuffix` field in each `counters.json` entry (derived from reading, or from a slugified `whatItCounts` when readings also collide as with 組). For the 62 unambiguous counters, `facetSuffix` equals the reading. **Decision needed before iOS implementation.**

3. **Alternate readings in the TSV** — some cells contain parenthesized variants (e.g. `じゅっこ (じっこ)`). Decide whether `counter-pronunciation` accepts any listed variant or only the primary (non-parenthesized) reading.
4. **Markdown reading files** — need to author: (a) a wago file (10 words, trivial), (b) a must-know counters file (19 counters), (c) a common counters file (47 counters). These are the enrollment vehicle — counters only enter the quiz queue when a user reads and commits to the word.
5. **WordDetailSheet counter section** — when a word's JMDict ID is in `counters.json`, the detail sheet should display a 1–10 pronunciation table (analogous to how transitive pairs show both verb forms). Design TBD.
6. **Quiz prompt wording for `counter-pronunciation`** — distractors can be generated entirely without LLM: just pick three other readings from the same counter's 1–10 table (e.g. for 六匹→ろっぴき, offer いっぴき, さんびき, はっぴき). Free-answer phase: app builds stem locally, LLM grades. Needs a system prompt.
7. **`counter-pronunciation` in TestHarness** — needs a new prompt variation enumerated in `--dump-prompts`.

---

## Work Plan

### Phase 1: Data pipeline — `counters.json` ✅

1. ✅ `.claude/scripts/build-counters-json.mjs` written and working. Uses `ctr` part-of-speech filtering to auto-resolve ambiguous JMDict matches, with a manual override map for the 21 that remained ambiguous after filtering.
2. ✅ All 66 counters resolved. `counters/counters.json` written.
3. Commit `counters.json` alongside `transitive-pairs.json` in the published Gist. **Blocked on resolving the `facetSuffix` / duplicate-jmdictId question (Known Unknown 2) before the iOS side can consume it.**

### Phase 2: Markdown reading files

4. Author `wago.md` — a short reading file with the ten wago forms (ひとつ, ふたつ, … とお) enrolled as vocab.
5. Author `counters-must-know.md` — 19 counters (2 absolutely must know + 17 must know) with example sentences using each counter.
6. Author `counters-common.md` — 47 common counters.

### Phase 3: iOS — counter detection and `counter-pronunciation` facet

7. Add `CounterSync.swift` (parallel to `TransitivePairSync.swift`) — downloads and caches `counters.json`.
8. Extend the quiz context to check if the current word's JMDict ID appears in the counter table. If so, make `counter-pronunciation` available as a facet (kanji-committed words only).
9. Implement `counter-pronunciation` quiz generation:
   - Multiple choice: LLM generates stem + three wrong phonetic distractors
   - Free-answer: app builds stem ("How do you read 六匹?"), LLM grades
10. Add the system prompt for `counter-pronunciation` and enumerate it in TestHarness `--dump-prompts`.

### Phase 4: iOS — WordDetailSheet counter section

11. When `word_type` maps to a counter JMDict ID, show a counter pronunciation table (1–10 grid) in WordDetailSheet below the existing senses section.
12. Optionally: show the DBJG type label and a one-sentence explanation of the phonetic pattern.

### Phase 5: Validation

13. Run TestHarness against `counter-pronunciation` prompts for a representative sample of counters (Type B, Type C, irregular).
14. Manual end-to-end test in simulator: enroll 本, commit to kanji, trigger `counter-pronunciation` quiz, verify correct and incorrect answers grade correctly.
