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

**Verdict so far** (iteration 2 complete): **three confirmed bugs**, all "Claude wrote this,
human reviewed it, no one noticed" class. All three are silent-data-loss bugs in the content
pipeline, currently latent (the corpus does not exercise them today). Hypothesis **proved**.
See [Bugs to fix](#-bugs-to-fix) for the catalog.

## Implemented

**Swift fuzz harness** in [Pug/TestHarness/Sources/TestHarness/Fuzz.swift](../Pug/TestHarness/Sources/TestHarness/Fuzz.swift),
dispatched via `TestHarness --fuzz <area>` (added in [main.swift](../Pug/TestHarness/Sources/TestHarness/main.swift)).
Six areas:

| Area | What it checks | Items checked | Result |
|---|---|---|---|
| `jmdict` | `QuizContext.jmdictWordData` returns non-empty `kanaTexts` and non-empty `text` for every entry; adversarial IDs return nothing | 215,611 entries (+ 9 adversarial IDs) | **PASS** (2 silently skipped — entries where every kana is tagged `ik`) |
| `furigana` | For every row in the `furigana` table, joined ruby fields exactly equal the row's `text` field | 231,776 rows | **PASS** |
| `fillin` | `GrammarQuizSession.gradeFillin` reflexivity; 。-strip invariant on either side; documented edge cases | 16 fixed cases + 500 random reflexivity + 1,000 random 。-strip | **PASS** |
| `ebisu` | `predictRecall` ∈ [0,1] across halflives 0.5h–10000h; `updateRecall` produces well-formed models; perfect-score halflife ≥ zero-score halflife (monotonicity); adversarial inputs throw cleanly | 27 fixed cases + 5,000 random predictRecall + 3,000 random updateRecall + 4 adversarial | **PASS** |
| `partial-template` | `buildPartialTemplate` round-trips: all kanji committed → output equals text; output matches manually computed expected for any subset | 50,000 furigana rows × 3 invariants | **PASS** (+ surfaced a non-bug data note about katakana, see below) |
| `romaji` | `romajiToHiragana` known cases; doesn't crash on random ASCII; output is hiragana-only when not nil | 19 fixed cases + 5,000 random ASCII | **PASS** |

**Skipped on inspection** (invariants hold trivially by construction, not productive to fuzz):
- MC shuffle correctness — single `swapAt(0, newCorrectIndex)` provably keeps `choices[correctIndex] == correctAnswer`
- Tier graduation monotonicity — three comparisons that are monotone in `(reviewCount, halflife)` by inspection

**Node.js fuzzer** in [fuzz.mjs](../fuzz.mjs), run via `node fuzz.mjs`. Eight areas:

| Area | What it checks | Result |
|---|---|---|
| `parseFrontmatter` | BOM/CRLF, colon-in-value, empty key lines, adversarial inputs (10k char strings, null bytes, etc.) | **PASS** (22/22) |
| `extractDetailsBlocks` | Single block, two separate blocks, case-insensitive summary, nested `<details>` | **BUG #1** (see below) |
| `grammar-equivalences.json` partition | No duplicate topic IDs across groups; no empty groups; format `source:slug`; no duplicate sub-use IDs | **PASS** (107 IDs, 46 groups) |
| `extractJapaneseTokens` | Returned tokens always satisfy `isJapanese`, always non-empty, stop at first non-Japanese token | **PASS** (fixed cases + 1,000 random) |
| `isFuriganaParent` | Self-reference is false; real parent relationship; asymmetry property; no throws on random inputs | **BUG #2** (see below) |
| `buildFuriganaForWord` | Kana-only words have empty forms; reading keys are hiragana-normalized; every form's `text` is in `word.kanji` (filtered) | **PASS** |
| `extractContextBefore` | Prose extraction across single + multi-line `<details>` blocks; nested `<details>` blocks; adversarial inputs | **BUG #3** (see below) |
| `migrateEquivalences` | Idempotency: `migrate(migrate(x)) === migrate(x)` | **PASS** |
| `check-vocab.mjs` resolution | Per-token line-number correctness (1,866 bullets × 277 .md files including the full personal corpus); direct-ID validity; resolved IDs exist; no crashes; nested-`<details>` false-positive scan | **PASS on resolution + BUG #4 found** (see below) |

**Refactor**: moved [`toHiragana`](../.claude/scripts/shared.mjs), [`isFuriganaParent`](../.claude/scripts/shared.mjs), [`buildFuriganaForWord`](../.claude/scripts/shared.mjs), [`extractContextBefore`](../.claude/scripts/shared.mjs), and [`extractVocabBulletsWithLines`](../.claude/scripts/shared.mjs) (line-number-aware variant) from `prepare-publish.mjs` and `check-vocab.mjs` to `shared.mjs`, so `fuzz.mjs` can import the canonical versions. Verified `prepare-publish.mjs --no-llm` and `check-vocab.mjs` both run end-to-end after the move.

**Corpus run on the full Markdown corpus** (~280 .md files including content + docs): **~1,800 vocab bullets, zero new bugs surfaced from real data.** The author has consistently used the canonical `<details>` pattern (single-line and multi-line variants), so none of the latent parser bugs (BUG #1, BUG #4) actually fire on production content. Structural invariants (line numbers, direct-ID validity, resolved-ID existence, no crashes) all hold.

A test-fuzzer bug surfaced during the corpus run: my initial line-number invariant assumed `actualLine.startsWith("-")`, which fails for the single-line Vocab block variant `<details><summary>Vocab</summary>- 食べる</details>` (the line starts with `<`, not `-`). Relaxed to "every leading Japanese token from the bullet must appear on the line" — catches real mismatches without false-positive on the single-line variant. Same lesson as the iteration-2 katakana/reading discrepancy in `partial-template`: **first-pass invariants tend to be too strong, and the corpus surfaces the over-strictness before any real-data bug.**

## 🚨 Bugs to fix

**Common root cause** for BUG #1, BUG #3, and BUG #4: regex / linear-scan code in `shared.mjs`
does not understand Markdown context (no awareness of `<details>` block depth, inline code
spans, or fenced code blocks). Three functions affected (`extractDetailsBlocks`,
`extractContextBefore`, plus knock-on effects in `extractVocabBulletsWithLines` and
`buildFuriganaForWord`-style downstream consumers); the proper fix is a small Markdown-aware
helper that strips code spans and code fences, plus tracks `<details>` depth with a stack.

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

### BUG #2: `isFuriganaParent` returns `true` for two distinct empty-furigana objects

**Where**: [`.claude/scripts/shared.mjs`](../.claude/scripts/shared.mjs) — the function
`isFuriganaParent(elt, maybeParent)` returns `true` for any pair of distinct objects whose
`furigana` arrays are both empty. The `while (xx.length || yy.length)` loop never executes,
so the function falls through to the default `return true`.

**Repro**:
```javascript
isFuriganaParent({furigana: []}, {furigana: []})  // returns true (should be false)
```

**Currently fires?** No. Callers in `buildFuriganaForWord` only pass furigana objects that
came from `furiganaMap.get(...)` matches, which are non-empty by construction. But a future
caller change — or upstream JmdictFurigana data with an empty furigana array — would silently
collapse all such forms (`forms.filter(f => !forms.some(other => isFuriganaParent(f, other)))`
would drop every form because everyone is everyone's "parent").

**Fix**: add an explicit `if (xx.length === 0 && yy.length === 0) return false;` guard at the
top of the function. One line.

### BUG #3: `extractContextBefore` loses prose context with nested `<details>`

**Where**: [`.claude/scripts/shared.mjs`](../.claude/scripts/shared.mjs) —
`extractContextBefore` walks backward looking for `<details` to find the start of a multi-line
block, but the inner loop matches the inner `<details>` first when blocks are nested.

**Symptom**: when a Vocab block contains a nested `<details>` (e.g. a Grammar block) and is
preceded by prose, that prose is silently lost. The function returns `{ text: null, line: null }`
instead of the actual prose paragraph.

**Repro** (in fuzz.mjs):
```
Prose paragraph.
<details><summary>Vocab</summary>
- 食べる eat
<details><summary>Grammar</summary>
- ている
</details>
- 飲む drink
</details>
```
Expected: `{ text: "Prose paragraph.", line: 1 }`. Actual: `{ text: null, line: null }`.

The backward walker, after seeing the outer `</details>`, descends into the outer block
looking for `<details`, finds the *inner* `<details>` instead, decrements past it, and lands
inside the outer block on a bullet line — which terminates prose collection.

**Currently fires?** Same status as BUG #1 (corpus has no nested `<details>` blocks today).
Same fix applies.

**Same root cause as BUG #1** — the regex in `extractDetailsBlocks` and the inner loop here
both fail to track block depth. A single shared depth-tracking helper would fix both.

### BUG #4: `extractDetailsBlocks` matches `<details>` inside inline code spans / code fences

**Where**: [`.claude/scripts/shared.mjs`](../.claude/scripts/shared.mjs) — same regex as BUG #1.

**Symptom**: when a file contains `<details>` mentions in prose (typically inside inline code
spans like `` `<details>` `` or fenced code blocks showing example markdown), the lazy regex
treats the first such mention as a real opening tag and matches greedily-but-laz​ily until the
first `</details>` it can find. If the captured chunk happens to contain `<summary>Vocab</summary>`
somewhere in its middle, the entire chunk is misclassified as a Vocab block.

**Concrete repro** (found by the J fuzzer in [docs/TODO-reader.md](TODO-reader.md)):

The file has `<details>` mentioned in inline code spans on lines 17, 28, 30, 53 (e.g.
"Do not parse `` `<details>` `` bullet text"), and a fenced-code-block example showing real
Vocab block syntax on lines 56–64. The regex starts matching at line 17's `<details>` and
runs to line 60's `</details>`, capturing 43 lines of unrelated prose. Because the chunk
contains `<summary>Vocab</summary>` (line 58), it's yielded as a Vocab block.

**Currently fires?** The fuzzer found three files where this manifests: `docs/TODO-reader.md`
(genuine corpus instance) and two hits in `docs/TODO-fuzzing.md` (this very file — the bug
example I documented under BUG #1 triggers BUG #4 in itself). None currently cause data
corruption because:
- These files don't have `llm-review: true` in frontmatter
- The bullet-like lines inside the malformed match don't happen to be Japanese (so they're
  silently skipped at the `extractJapaneseTokens` step)

**Risk**: any future content file that (a) has `llm-review: true` and (b) discusses
`<details>` syntax in prose would silently extract prose lines as vocab bullets.

**Fix**: same proper fix as BUG #1 — a Markdown-aware helper that strips code spans and code
fences before regex matching, or a real Markdown parser pass.

### Documented limitation: `gradeFillin` does not strip half-width ｡ (U+FF61)

The fillin fuzzer found that `gradeFillin(["食べます\u{FF61}"], ["食べます"])` returns false —
the half-width ideographic full stop is not stripped, only the full-width 。 (U+3002) is.

iOS Japanese keyboards always emit U+3002, so this is unlikely to fire for real users. Probably
not worth fixing, but the fuzz test now documents the boundary explicitly.

### Documented finding (not a bug): katakana surface forms in partial-template

The fuzzer initially reported 367 mismatches in `buildPartialTemplate` for the invariant
"with no kanji committed, output equals the row's `reading` field". On inspection these are
all katakana-surface entries (e.g. `text='アッと言う間に'` reading `'あっというまに'`). The
furigana segments preserve the original katakana (`{ruby: "アッ"}` with no `rt`), so
`buildPartialTemplate` correctly emits "アッ…" while the canonicalized `reading` column is
"あっ…". This is by design — the partial template preserves katakana for kana segments —
but **the discrepancy between the canonicalized `reading` column and the rendered template
is worth knowing about**: any UI that displays both fields side-by-side would show
inconsistent spelling. Test fuzzer was relaxed to assert the actual contract instead.

### Pre-existing build breakage (fixed during this work)

`QuizItem` had two new required fields (`committedFurigana`, `siblingKanaReadings`) that the
`TestHarness` callsites in [main.swift](../Pug/TestHarness/Sources/TestHarness/main.swift) and
[DumpPrompts.swift](../Pug/TestHarness/Sources/TestHarness/DumpPrompts.swift) hadn't been
updated for. The TestHarness was not building. Fixed by passing `nil` and `[]`. Worth noting
because **this is exactly the kind of drift fuzzing-as-build-gate would catch** — if `--fuzz`
ran in CI, the build break would have been caught at PR time.

## Iteration 2: status of proposed targets

Each target from the original iteration-2 proposal got one of three outcomes: **DONE** (a
fuzzer was implemented and run), **DROPPED** (on inspection, no productive fuzz target), or
**PENDING** (deferred to a future iteration).

| Code | Target | Outcome |
|---|---|---|
| A | `EbisuModel` math invariants | **DONE** — PASS |
| B | `buildPartialTemplate` round-trip | **DONE** — PASS (+ surfaced katakana/reading discrepancy as a UI consideration) |
| C | MC shuffle correctness | **DROPPED** — single-swap algorithm; invariant trivial by construction |
| D | Tier graduation monotonicity | **DROPPED** — three comparisons; monotone by inspection |
| E | `RomajiConverter.romajiToHiragana` | **DONE** — PASS |
| F | `isFuriganaParent` adversarial | **DONE** — **BUG #2 FOUND** (predicted edge case confirmed) |
| G | `buildFuriganaForWord` | **DONE** — PASS |
| H | `extractContextBefore` | **DONE** — **BUG #3 FOUND** (predicted same-pattern bug confirmed) |
| I | `migrateEquivalences` idempotency | **DONE** — PASS |
| J | `check-vocab.mjs` bullet resolution | **DONE** — resolution invariants PASS on 1,866 bullets across 277 files (full corpus); **BUG #4 FOUND** (new variant of BUG #1: regex confused by `<details>` in inline code spans / fences) |

The iteration-2 predictions held up: F was predicted to find a bug (the empty-array case
noted during code review) — confirmed. H was predicted to have the same backward-walking-
with-nested-HTML bug as BUG #1 — confirmed. J's nested-`<details>` scan was the **only finding
that came from random-style data fuzzing rather than predicted-by-code-review** — it surfaced
BUG #4 as a fresh variant.

## Iteration 3: iOS quiz logic (planned)

The first two iterations targeted data-pipeline parsing and Swift math/data-layer code. All
four bugs found are in `shared.mjs` parsing — a class the author already suspected was
fragile (regex-heavy hand-written parser, deliberately constrained to canonical patterns to
keep it working). To genuinely test the "fuzzing finds bugs you didn't expect" half of Dan's
claim, iteration 3 should target iOS quiz / commitment / kanji code where the author has
higher confidence.

### High-yield targets

**K. Word commitment progression** — [`WordCommitment+CommittedForms.swift`](../Pug/Pug/Models/WordCommitment+CommittedForms.swift)
Walk the commitment ladder ∅ → {k₁} → {k₁, k₂} → … → all-kanji for every JMDict word with
kanji and verify:
- The derived `partialKanjiTemplate` at each step satisfies the per-segment rule (ruby for
  committed, rt for uncommitted) for **every** segment, not just the aggregate
- Adding a new kanji to the committed set produces a template with strictly fewer
  rt-substituted segments (monotone)
- The all-committed template equals the original surface form (extends iteration-2 area B,
  which only tested the static `buildPartialTemplate` function on isolated inputs — K tests
  the full commitment-progression flow)

Why risky: this code is in active flux. The recent `committedFurigana` and
`siblingKanaReadings` fields were added to `QuizItem` without rebuilding the TestHarness
target (caught and fixed during iteration 1). Multi-kanji words with okurigana (e.g.
`閉じ籠もる`, `食べ物`) and alternate orthographies (e.g. `閉じこもる` vs `閉じ籠もる`) are
the most-likely sites for off-by-one bugs.

**L. Kanjidic2 cross-DB consistency**
For every JMDict word's `kanji.text`, every CJK ideograph in that string must resolve in
`kanjidic2.sqlite`. Scan all ~215k entries.

Why risky: two independent third-party datasets (JMDict + KANJIDIC2) bundled together. Sync
drift would manifest as the kanji-detail sheet showing empty data when the user taps a
kanji that JMDict knows about but kanjidic2 doesn't. Classic "Claude wrote consistency-checking
code with two examples in mind" bug class.

**M. Counter pronunciation completeness** — `Counters/counters.json`
For each counter, every `quizNumber` in the array must have a corresponding row in the 1–10
pronunciation table; rendaku and 4/7/9 hint strings non-empty when present; `whatItCounts`
non-empty.

Why risky: hand-curated from Tofugu TSV. Exactly the kind of data where one row gets dropped
silently during conversion.

### Medium-yield

**N. Transitive-pair distractor sanity** — `transitive-intransitive/`
For every pair, the generated MC distractor must not equal the correct answer, must not be
empty, must not contain disallowed characters. Pair-specific replacement logic in
`QuizSession.swift` (the `pairs.count >= 4` block found near the shuffle code).

**O. `vocab.json` structural invariants** (Node.js)
- Every entry has `id`, `sources` (non-empty), `references` (consistent shapes)
- IDs unique
- Every source string in `references` keys appears as some Markdown file's title prefix
- `writtenForms` array (when present) covers every `kanji` form and every `kana` reading

Why risky: optional fields, custom decoders, the iOS app's `VocabSync.swift` and the
generator `prepare-publish.mjs` must agree on the shape exactly.

### Drop unless time permits

**P. `rescaleHalflife` round-trip identity** — already covered by area A's single check.
**Q. Quiz urgency determinism** — `predictRecall` is a pure function; determinism follows by construction.
**R. Romaji round-trip** — only `romajiToHiragana` exists; no reverse direction.

### Plan

- **Single Swift batch**: K + L + M (and N if time). One rebuild, run all together.
- **Single Node.js batch**: O.
- **Refactor as needed**: probably extract `buildPartialTemplate`'s commitment-progression
  driver into a testable function (mirroring the iteration-2 `shared.mjs` extractions).
- Update this doc with iteration-3 outcomes the same way as iteration 2.

The full original iteration-2 proposals (A–J) follow for reference.

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

**Final result** (iterations 1 + 2 complete): **four confirmed bugs**:
- [BUG #1](#bug-1-extractdetailsblocks-mishandles-nested-details-blocks) — `extractDetailsBlocks` nested `<details>`
- [BUG #2](#bug-2-isfuriganaparent-returns-true-for-two-distinct-empty-furigana-objects) — `isFuriganaParent` empty-array edge case
- [BUG #3](#bug-3-extractcontextbefore-loses-prose-context-with-nested-details) — `extractContextBefore` nested `<details>`
- [BUG #4](#bug-4-extractdetailsblocks-matches-details-inside-inline-code-spans--code-fences) — `extractDetailsBlocks` matches `<details>` inside inline code spans / code fences

All four are in the same file ([`shared.mjs`](../.claude/scripts/shared.mjs)). Three of them
(BUG #1, #3, #4) share a single root cause (regex code that doesn't understand Markdown
context — no `<details>` depth tracking, no awareness of inline code spans or code fences).
All four are silent-data-loss class bugs: vocabulary bullets, parent-relationship judgments,
prose context paragraphs, and even Vocab-block boundaries themselves can be lost or
corrupted without any error message. None currently fire in production (none of the affected
files have `llm-review: true`), but they are dormant traps that would fire the moment a
content author either nests a `<details>` block or includes prose discussing `<details>`
syntax inside an `llm-review: true` file.

**Hypothesis proved.** Four "Claude wrote this, human reviewed it, no one noticed" bugs
found across two iterations totaling roughly 5 hours of work. Notably, BUG #4 was **discovered
by the fuzzer** rather than predicted by code review — the J area's nested-`<details>` scan
flagged real corpus files (TODO-reader.md and the bug example I documented in this very file
TODO-fuzzing.md), and tracing those flags led to the new bug variant. It's the first finding
in this experiment that came from random-data-style fuzzing rather than targeted code reading.

**Final stats**:
- Swift: 215,611 + 231,776 + 1,516 + 8,031 + 150,000 + 5,019 = **611,953 items checked**, 0 bugs
- Node.js: ~85 fuzz checks across 9 areas + 23 real bullets across 237 .md files = **4 bugs found** (all in `shared.mjs` content-pipeline code)
- Lines added: ~700 in [Fuzz.swift](../Pug/TestHarness/Sources/TestHarness/Fuzz.swift) + ~500 in [fuzz.mjs](../fuzz.mjs)
- Build infrastructure: `--fuzz <area>` mode in TestHarness; `node fuzz.mjs` for the Node side

The Swift side ran clean across 600k+ items — strong evidence that the quiz-logic and
math-heavy code is correct. All bugs were in the content-processing pipeline, where the code
parses Markdown and JMDict-derived data with regex-based linear scans. That's the predicted
shape of the result: simple regex on structured-but-not-quite-regular input is the canonical
home of latent silent-data-loss bugs.

## Recommended fixes

Single shared Markdown-aware preprocessing helper in [`shared.mjs`](../.claude/scripts/shared.mjs):

```javascript
// Strip inline code spans (`...`) and fenced code blocks (```...```) from `content`,
// replacing them with same-length blanks (so character offsets are preserved).
// This makes downstream regex/scan code see only "live" Markdown, not example syntax.
export function stripCodeRegions(content) { /* state machine */ }

// Find the matching </details> for an opening <details> at character offset `start`,
// tracking depth so nested blocks pair correctly. Returns the offset of the start of the
// matching </details>, or null if unbalanced.
export function findMatchingDetailsClose(content, start) { /* stack-based scan */ }
```

Use these in:
- `extractDetailsBlocks` — preprocess with `stripCodeRegions` to fix BUG #4; use
  `findMatchingDetailsClose` instead of the lazy regex to fix BUG #1
- `extractContextBefore` — preprocess with `stripCodeRegions`, replace the inner
  backward-walking loop with a backward depth scan (fixes BUG #3)
- `isFuriganaParent` — separate one-line fix: add `if (xx.length === 0 && yy.length === 0) return false;`
