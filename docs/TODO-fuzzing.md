# Fuzzing experiment

## Dan Luu's approach

Dan Luu's [2014 post on testing](https://danluu.com/testing/) and a 2024 Mastodon thread argue
that software teams chronically under-invest in randomized / fuzzing-based testing because of
cultural inertia, not genuine technical obstacles. His updated view (post-LLM era):

1. **Use the LLM to audit the code first.** Before writing a single fuzzer, ask the LLM which
   areas of the code are risky — complex parsing, stateful logic, external input handling. This
   reconnaissance step is what he was unable to articulate in the blog post but that makes the
   process fast when sitting with someone in person.

2. **Write the fuzzer with the LLM.** What once took a week on an unfamiliar project now takes
   about an hour total (6 minutes of human time to find the first bug in a real text editor).

3. **The oracle problem is mostly a distraction.** The bugs fuzzing finds best — crashes,
   assertion violations, data corruption, inconsistent state — have free oracles. You almost never
   need to know the exact correct output for a random input; you just need to know the program
   should not crash, corrupt data, or violate a cheap structural invariant.

4. **LLM triage of fuzzer output** eliminates false positives at scale.

## Central hypothesis (preregistered)

> Dan correctly describes the typical engineer's incredulity about the effectiveness of this
> technique. **This experiment is about proving that hypothesis wrong**: that fuzzing this
> codebase — with minimal effort — will find real, non-trivial bugs in logic that was written
> by Claude and reviewed by a human.

Null hypothesis / prior belief: the non-UI logic in this codebase (JMDict queries, grading,
furigana segmentation, grammar data loading) is clean enough that a few hours of fuzzing will
not surface anything important. This is a codebase where the author was skeptical.

**Verdict so far** (iteration 1): one real, non-trivial bug found in
[`extractDetailsBlocks`](../.claude/scripts/shared.mjs) — a regex limitation that causes silent
data loss when a `<details>` block is nested inside a Vocab block. It is currently latent (not
fired by the corpus) but is a genuine "Claude wrote this, human reviewed it, no one noticed"
bug. Hypothesis weakly proved; iteration 2 should test that "weakly" more aggressively.

## Iteration 1: implemented

**Swift fuzz harness** in [Pug/TestHarness/Sources/TestHarness/Fuzz.swift](../Pug/TestHarness/Sources/TestHarness/Fuzz.swift),
dispatched via `TestHarness --fuzz <area>` (added in [main.swift](../Pug/TestHarness/Sources/TestHarness/main.swift)).
Three areas:

| Area | What it checks | Items checked | Result |
|---|---|---|---|
| `jmdict` | `QuizContext.jmdictWordData` returns non-empty `kanaTexts` and non-empty `text` for every entry; adversarial IDs return nothing | 215,611 entries (+ 9 adversarial IDs) | **PASS** (2 silently skipped — entries where every kana is tagged `ik`) |
| `furigana` | For every row in the `furigana` table, joined ruby fields exactly equal the row's `text` field | 231,776 rows | **PASS** |
| `fillin` | `GrammarQuizSession.gradeFillin` reflexivity; 。-strip invariant on either side; documented edge cases | 16 fixed cases + 500 random reflexivity + 1,000 random 。-strip | **PASS** |

**Node.js fuzzer** in [fuzz.mjs](../fuzz.mjs), run via `node fuzz.mjs`. Four areas:

| Area | What it checks | Result |
|---|---|---|
| `parseFrontmatter` | BOM/CRLF, colon-in-value, empty key lines, adversarial inputs (10k char strings, null bytes, etc.) | **PASS** (22/22) |
| `extractDetailsBlocks` | Single block, two separate blocks, case-insensitive summary, nested `<details>` | **2 BUGS FOUND** (see below) |
| `grammar-equivalences.json` partition | No duplicate topic IDs across groups; no empty groups; format `source:slug`; no duplicate sub-use IDs | **PASS** (107 IDs, 46 groups) |
| `extractJapaneseTokens` | Returned tokens always satisfy `isJapanese`, always non-empty, stop at first non-Japanese token | **PASS** (fixed cases + 1,000 random) |

## 🚨 Bugs to fix

### BUG #1: `extractDetailsBlocks` mishandles nested `<details>` blocks

**Where**: [.claude/scripts/shared.mjs](../.claude/scripts/shared.mjs) — the regex
`/<details\b[^>]*>([\s\S]*?)<\/details>/gi`.

**Symptoms** (both observed by the fuzzer, both consequences of the same root cause):

1. **Silent data loss.** When a Vocab block contains a nested `<details>` block, any vocabulary
   bullet that appears between the inner `</details>` and the outer `</details>` is silently
   dropped from extraction. The lazy quantifier `*?` matches the *inner* `</details>` first.

2. **Cross-block leakage.** Bullets inside the nested block (e.g. a Grammar `<details>` inside
   a Vocab `<details>`) leak into the Vocab extraction because `stripped` ends after the inner
   close — the Grammar bullets stay in the captured content.

**Repro** (in fuzz.mjs):
```html
<details><summary>Vocab</summary>
- 食べる eat
<details><summary>Grammar</summary>
- ている
</details>
- 飲む drink     ← silently dropped
</details>
```
Result: `extractVocabBullets` returns `["食べる eat", "ている"]`. The first is correct, the
second is a Grammar bullet leaking into Vocab, and `飲む drink` is gone.

**Currently fires?** No. Searched the corpus — no Vocab block currently contains a nested
`<details>`. So this is a **latent** bug, not an active one. But it would silently corrupt
content the moment someone uses a collapsible Grammar block inside a Vocab block, which is a
reasonable Markdown pattern to want.

**Fix options**:
- **Easiest**: enforce a "no nested details" rule in `prepare-publish.mjs` validation. Detect
  the pattern and warn (or fail). Cheap and prevents the bug from firing.
- **Proper**: replace the regex with a stack-based parser that tracks `<details>`/`</details>`
  depth. ~20 lines of code; would also fix `extractContextBefore`'s similar backward-walking
  logic which has the same vulnerability.

### Documented limitation: `gradeFillin` does not strip half-width ｡ (U+FF61)

The fillin fuzzer found that `gradeFillin(["食べます\u{FF61}"], ["食べます"])` returns false —
the half-width ideographic full stop is not stripped, only the full-width 。 (U+3002) is.

iOS Japanese keyboards always emit U+3002, so this is unlikely to fire for real users. Probably
not worth fixing, but the fuzz test now documents the boundary explicitly.

### Pre-existing build breakage (fixed during this work)

`QuizItem` had two new required fields (`committedFurigana`, `siblingKanaReadings`) that the
`TestHarness` callsites in [main.swift](../Pug/TestHarness/Sources/TestHarness/main.swift) and
[DumpPrompts.swift](../Pug/TestHarness/Sources/TestHarness/DumpPrompts.swift) hadn't been
updated for. The TestHarness was not building. Fixed by passing `nil` and `[]`. Worth noting
because **this is exactly the kind of drift fuzzing-as-build-gate would catch** — if `--fuzz`
ran in CI, the build break would have been caught at PR time.

## Iteration 2: more areas to test (proposed)

The iteration-1 hypothesis verdict is "weakly proved." To test it more aggressively, here are
the most promising additional targets, ranked by expected bug yield.

### iOS / Swift

#### A. `EbisuModel` mathematical invariants — **highest expected yield**
Functions: `predictRecall`, `updateRecall`, `rescaleHalflife` in
[EbisuModel.swift](../Pug/TestHarness/Sources/TestHarness/EbisuModel.swift).

**Free oracles** (all checkable without knowing the "right answer"):
- `t > 0` always (halflife is positive); `alpha > 0`, `beta > 0`
- `predictRecall` ∈ [0, 1] for all valid models and all `tnow ≥ 0`
- No `NaN`, no `Infinity` in any output for any reasonable input
- Monotonicity: holding `(prior, tnow)` fixed, `updateRecall(prior, successes: 1, ...).t ≥
  updateRecall(prior, successes: 0, ...).t` (perfect review never hurts halflife)
- Idempotency under no review: `predictRecall(model, 0)` should be ~1 (recall right after a review)

**Why risky**: floating-point Bayesian math with `betaln`, `logsumexp`, `bisect`. Numerical
instability is signaled by an explicit error type — but the question is whether legitimate
inputs ever trigger it, and whether outputs stay sane near the edges (very small / very large
halflives, near-zero α/β).

#### B. `buildPartialTemplate` (partial-kanji quiz template)
Function: [DumpPrompts.swift:62](../Pug/TestHarness/Sources/TestHarness/DumpPrompts.swift#L62).

**Free oracles**:
- When `committedKanji` contains *every* kanji in the form, the output equals the original
  surface form exactly (round-trip identity)
- The output's character count equals the sum of either `ruby.count` (committed) or `rt.count`
  (uncommitted) per segment — never both, never neither
- The output never contains kanji not in `committedKanji`
- The function never crashes on unusual furigana segmentations (single-char ruby, multi-char rt,
  empty rt)

**Why risky**: directly user-facing in partial-kanji quiz mode. A malformed template means the
student sees the wrong question. Fuzz over real `furigana` table rows × random subsets of the
form's kanji as `committedKanji`.

#### C. Multiple-choice shuffle correctness (recent change)
Recent commit `e6ce55b` moved choice shuffling app-side after a Haiku-mistracking bug. Search
[QuizSession.swift](../Pug/TestHarness/Sources/TestHarness/QuizSession.swift) for `shuffled()`
and `correctIndex`.

**Free oracles**:
- Shuffle is a permutation: `Set(shuffled.choices) == Set(original.choices)`, count equal
- `shuffled.choices[shuffled.correctIndex] == original.choices[original.correctIndex]`
  (the correct answer string follows the index after shuffling)
- Determinism with seeded RNG (if a seed is exposed)

**Why risky**: just changed; the previous bug was subtle. Shuffle + index tracking is a
classic source of off-by-one errors.

#### D. Tier graduation monotonicity
Tier transitions in [GrammarQuizSession.swift](../Pug/TestHarness/Sources/TestHarness/GrammarQuizSession.swift)
and [QuizSession.swift](../Pug/TestHarness/Sources/TestHarness/QuizSession.swift) based on
review count and halflife (per [TESTING.md](TESTING.md): tier 2 requires ≥3 reviews and ≥72 h
halflife; tier 3 requires ≥6 reviews and ≥120 h).

**Free oracle**: tier is a non-decreasing function of `(reviewCount, halflife)`. Adding more
reviews or more halflife should never lower the tier. Random fuzz over (reviewCount, halflife)
pairs.

**Why risky**: the threshold boundaries (3 vs 4 reviews, 71 h vs 72 h) are exactly where bugs
hide.

#### E. `RomajiConverter.romajiToHiragana` adversarial inputs
Function: [RomajiConverter.swift:10](../Pug/TestHarness/Sources/TestHarness/RomajiConverter.swift#L10).

**Free oracles**:
- Returns `nil` (not crashes) for any input it can't convert
- For canonical romaji input (e.g. all Wapuro romaji), output contains only hiragana
- Geminate consonants (`tta` → っ た), ya/yu/yo combinations (`sha` → しゃ), long vowels
  (`oo` / `ou`) all produce expected length output

**Why risky**: Japanese transliteration has many edge cases (`n` followed by vowel vs.
consonant; `nn` for ん; `tsu` vs `tu`; etc.). Only the forward direction exists, so no
round-trip — but adversarial-input testing is still valuable.

### Node.js / content pipeline

#### F. `isFuriganaParent` adversarial inputs — **edge case noted during code review**
Function: [prepare-publish.mjs:90-143](../prepare-publish.mjs#L90).

**Free oracles**:
- Empty-furigana edge case: `isFuriganaParent({furigana: []}, {furigana: []})` returns `true`
  for two distinct objects with empty arrays. This is wrong (no parent relationship exists).
  Currently doesn't fire because callers filter empty-furigana words upstream — but a future
  caller change would expose it.
- Asymmetry: not both `isFuriganaParent(a, b)` and `isFuriganaParent(b, a)` should be true
  (unless after the early identity check)
- Self: `isFuriganaParent(a, a)` should always return `false` (the function checks reference
  equality, but objects deserialized from JSON would never be identical)

**Why risky**: it's the complex nibbling algorithm Claude wrote, with eight branches and
mixed-type comparisons. Needs to be exported from `prepare-publish.mjs` (or the test moved
into that file) since it's currently file-private.

#### G. `buildFuriganaForWord` structural invariants
Function: [prepare-publish.mjs:155-217](../prepare-publish.mjs#L155).

**Free oracles**:
- For non-kana-only words: every returned form's `text` field appears in
  `word.kanji.map(k => k.text)` (filtered for `iK`)
- Reading keys are hiragana (no katakana leaking through)
- For kana-only words: returned `forms` array is empty
- After collapsing, no form is the parent of any other form

**Why risky**: complex Map-of-arrays grouping with mutation, multiple filter passes, and the
collapse step that depends on `isFuriganaParent`. Fuzz with synthesized JMDict word objects
having permuted kanji/kana orderings.

#### H. `extractContextBefore` backward-walking — same pattern as BUG #1
Function: [prepare-publish.mjs:226-290](../prepare-publish.mjs#L226). Walks backward from a
position skipping nested `<details>` blocks.

**Free oracles**:
- Returned `line` ≤ input position's line
- Returned text never contains a complete `<details>...</details>` substring
- Doesn't infinite-loop on adversarial inputs (intentionally malformed `<details>` markup)

**Why risky**: this is exactly the same backward-walking-with-nested-HTML pattern as the
nested-block bug we already found. **Strong prior that this also has bugs.**

#### I. `migrateEquivalences` idempotency
Function: [shared.mjs:371](../.claude/scripts/shared.mjs#L371). Migrates legacy
array-of-arrays format to current array-of-objects format.

**Free oracle**: `migrateEquivalences(migrateEquivalences(x)) === migrateEquivalences(x)` for
any input. (Idempotency.)

**Why risky**: cheap to test; idempotency violations are easy to write accidentally and have
caused production bugs in similar migration code in other projects.

#### J. `check-vocab.mjs` bullet resolution
The vocabulary-bullet → JMDict-ID resolution is the most data-heavy logic in the content
pipeline.

**Free oracles**:
- Returned IDs always exist in `jmdict.sqlite`
- A bullet that resolves to one ID must not also be flagged as ambiguous
- Resolution is deterministic (same bullet → same ID across runs)
- Empty / whitespace-only bullets produce no ID and a warning

**Why risky**: complex matching with fallbacks (token intersection, kanji-anywhere match, etc.).
Probably has the highest concentration of "Claude wrote this with one example in mind" bugs.

## Implementation notes (for iteration 2)

- All Swift proposals (A–E) extend the existing `--fuzz` flag with new area names. No new
  build targets needed.
- For (F) and (G), `prepare-publish.mjs` will need to export the helpers (or the tests move
  inline). The Node.js fuzzer pattern in [fuzz.mjs](../fuzz.mjs) is easy to extend.
- Estimate: each iteration-2 area is ~30 minutes of human time given the iteration-1
  scaffolding already exists. Total ~5 hours for all ten.

## Success criteria

The experiment is considered to have **proved the hypothesis wrong** if fuzzing finds at least
one bug that:
- was not covered by an existing test or test harness path, **and**
- would have been observable to a user (wrong quiz output, silent data corruption, or a crash).

**Iteration 1 result**: one such bug found ([`extractDetailsBlocks`](#bug-1-extractdetailsblocks-mishandles-nested-details-blocks)).
Currently latent in the corpus but it satisfies the criterion. Hypothesis weakly proved.

The experiment **confirms the null hypothesis** if N ≥ 5,000 fuzz iterations across all areas
produce zero new failures beyond what the existing test harness already catches.

**Iteration 1 stats**: 215,611 + 231,776 + 1,516 + 50 = **448,953 items checked**, one bug
found. The "low effort" half of Dan's claim is well-supported (under 2 hours of work). The
"finds bugs" half is supported by exactly one finding — which is why iteration 2 is worth
doing.
