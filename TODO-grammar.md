# Grammar feature plan

## Concepts

### Grammar databases
Three sources, each providing topic IDs:
- **Genki** (`grammar-stolaf-genki.tsv`): ~123 topics, slugified IDs like `potential-verbs`
- **Bunpro** (`grammar-bunpro.tsv`): ~943 topics, IDs like `られる-Potential`
- **DBJG** (`grammar-dbjg.tsv`): ~370 entries from Dictionary of Basic Japanese Grammar table of contents (slugified from `grammar-dbjg.md` via `slugify-dbjg.mjs`)

All IDs are prefixed by source in annotations and in the app: `genki:potential-verbs`,
`bunpro:られる-Potential`, `dbjg:rareru2`.

### Equivalence groups
Many topics across databases describe the same grammar (e.g., Genki `potential-verbs`,
Bunpro `られる-Potential`, DBJG `rareru2`). At publish time, an LLM-assisted step
clusters these into equivalence groups. When a quiz updates Ebisu for one topic, all
topics in the same group are updated. This prevents redundant quizzing.

### Markdown annotation
```markdown
<details><summary>Grammar</summary>
- genki:potential-verbs
- dbjg:noni1
</details>
```
Bullets **must** be source-prefixed (`source:id`). Unprefixed IDs are rejected.
Valid prefixes: `genki:`, `bunpro:`, `dbjg:`. Prefix matching is case-insensitive
(`DBJG:` = `dbjg:`). Optionally followed by free-text notes
(e.g., `bunpro:causative in ならせて`). The note is preserved for display but
only the first token (up to first space) is the topic ID used for lookup.

### Quiz facets

| Facet | Prompt shows | Student produces | Status |
|-------|-------------|-----------------|--------|
| `production` | English sentence/context | Japanese using target grammar | Launch facet |
| `recognition` | Japanese sentence | English meaning / identify grammar | Launch facet |
| `error-correction` | Japanese sentence with deliberate grammar mistake | Corrected sentence | Future |
| `sentence-completion` | Beginning of Japanese sentence | Completion using target grammar | Future |

`error-correction` and `sentence-completion` are future variants that may live
within existing facets rather than as independent facets.

### Format tiers

The two facets have different tier progressions:

**Recognition** (Japanese → English): two tiers
| Tier | Format | Generation | Grading |
|------|--------|------------|---------|
| 1. Multiple choice | Pick English meaning/grammar explanation from 4 choices | LLM (Haiku) | Pure logic (zero tokens) |
| 2. Free text | Open explanation of meaning and grammar point | LLM (Haiku) | LLM (Haiku) |

**Production** (English → Japanese): three tiers
| Tier | Format | Generation | Grading |
|------|--------|------------|---------|
| 1. Multiple choice | English context + 4 complete Japanese sentence choices; student taps a button | LLM (Haiku) | Pure logic (zero tokens) |
| 2. Fill-in-the-blank | Same English context + same 4 choices; student types the correct sentence | (reuses tier 1 generation) | String match, fallback to coaching LLM |
| 3. Free text | Full translation from English prompt | LLM (Haiku) | LLM (Haiku, multi-turn coaching) |

Tiers 1 and 2 share the same generated question — the only difference is the UI widget
(four tap buttons vs a text input). This means the LLM generation call happens once; the
tier 1 question is reused at tier 2 without regenerating.

> **Fill-in-the-blank for production tiers 1 and 2** (implemented and iterated through
> 2026-03-15): the original full-sentence choice design had recurring problems:
> (a) distractors that differed only by particle (が vs を) rather than by grammar form,
> and (b) ことができる appearing as a distractor even though it is valid Japanese.
> Note: problem (b) was originally framed as "generating four same-meaning sentences is hard"
> — this was a mis-framing. Full-sentence MC distractors should have *different* meanings (they
> express the wrong grammar for the English stem), not the same meaning. The real issue was just
> (a): particle-only variation between distractors is too subtle to discriminate grammar knowledge.
> Fill-in-the-blank solves (a) by reducing choices to short conjugation-level fills rather than
> complete sentences. It remains the right design for multi-gap patterns (〜し〜し, ば〜ほど).
> For single-gap grammar, full-sentence MC with properly-differentiated distractors is also viable.
>
> The fix: generate a Japanese sentence with one or more `___` gaps and 4 short
> conjugation-level choices. Each choice is an **array of strings**, one per gap.
> Single-gap example (potential verbs):
> ```json
> {"stem": "Describe that you can play guitar.",
>  "sentence": "彼は毎日ギターが___。",
>  "choices": [["弾けます"], ["弾きます"], ["弾かせます"], ["弾けません"]],
>  "correct": 0}
> ```
> Multi-gap example (〜し、〜し — multiple reasons):
> ```json
> {"stem": "Explain why you don't like the class.",
>  "sentence": "先生は厳しい___、宿題はたくさんある___。",
>  "choices": [["し", "し"], ["て", "て"], ["から", "から"], ["のに", "のに"]],
>  "correct": 0}
> ```
> Heterogeneous-gap example (〜ば〜ほど):
> ```json
> {"stem": "Say that the more you study, the more fun it gets.",
>  "sentence": "勉強すれ___楽しくなる___。",
>  "choices": [["ば", "ほど"], ["たら", "くらい"], ["と", "ほど"], ["ば", "ない"]],
>  "correct": 0}
> ```
> The gap isolates exactly the grammar slot(s) under test; each choice fills all gaps
> and the discrimination is purely about knowing the correct form. The verb stem
> visible around the gap (e.g. `弾___`) does reveal which verb is used, but this is
> acceptable — the student already sees the grammar topic name in the UI, and we have
> decided that sharing vocabulary context with the student on demand is fine.
>
> **Note on distractor semantics**: distractors do NOT need to have the same meaning
> as the correct choice — they just need to be plausible Japanese forms that happen to
> express the wrong meaning for this context. For example, `し` vs `て` vs `から` all
> express different relationships (multiple reasons vs sequential vs single cause). The
> English stem fixes the intended meaning; the student's job is to pick the form that
> correctly expresses that meaning. This is also true for full-sentence multiple choice
> (see "full-sentence MC" notes below).
>
> For tier 2, typing short fills into gaps is more tractable than reconstructing a
> whole sentence from memory, which better targets grammar knowledge rather than
> sentence production. For multi-gap tier 2, the student types each fill in sequence.
>
> In practice `correct` is a random 0–3, not always 0 — the examples above show 0 for
> brevity. The generation prompt instructs Haiku to place the correct fill at a random index.
>
> **Implementation** (done): `GrammarMultipleChoiceQuestion.choices` is `[[String]]`.
> The display layer counts `___` occurrences and fills the *n*th gap with `choice[n]`.
> The generation prompt instructs Claude to place one or more `___` gaps as needed
> by the grammar pattern, and return choices as arrays of strings (one element per gap).
> The tier-2 string-match fast path compares each typed segment against the
> corresponding element of `choices[correctIndex]`. The JSON parser also accepts
> legacy flat `[String]` format (auto-wrapped into 1-element sub-arrays).

Recognition collapses to two tiers because fill-in-the-blank in a Japanese sentence
is production by another name — it tests supplying the grammar form, not comprehending it.

Graduation thresholds TBD but likely higher than vocab (grammar production is harder).

**Difficulty scaling via known grammar, not halflife.** At quiz generation time, Claude
receives the list of grammar topics the student has at or above the quiz target's
establishment level. Claude uses these as scaffolding — building sentences that
incorporate well-known grammar patterns around the target point. A beginner studying
potential verbs gets simple sentences; someone who also has solid passive + causative
gets compound sentences using those patterns.

**Opportunistic passive grading.** On free-text quizzes, Claude also grades any
other enrolled grammar topics visible in the student's response. The scheduled topic
gets a full-weight Ebisu update; other topics get passive updates (`updateRecall(...,
0.5, 1, elapsed)`). This makes free-text grading token-efficient — one LLM call yields
multiple Ebisu updates.

### Token cost awareness
Grammar quizzes always require at least one LLM call for question generation (unlike
vocab where stems can be built locally). Keep prompts tight: topic ID, title, level,
example sentences, scaffolding grammar list. No database dumps. Post-answer discussion
is one additional call (same as vocab). Monitor via existing `api_events` telemetry.

The vocab system evolved from fully-LLM to hybrid (logic where possible). Expect
grammar to follow the same trajectory — start with LLM everywhere, migrate
deterministic parts to pure logic as patterns emerge.

---

## Phases

### Phase 0 — content pipeline (no iOS)

- [x] Slugify DBJG entries into a proper TSV (id, option, title-en) matching the Genki/Bunpro format
  - Handle cross-references like `chau <shimau>` — these become aliases pointing to the main entry
  - Numbering disambiguates homographs: `ageru1`, `ageru2`
  - `option` = `"basic"` for all (future: `"intermediate"`, `"advanced"` for the sequel books)
  - Done: `grammar/slugify-dbjg.mjs` → `grammar/grammar-dbjg.tsv`
- [x] Build grammar database loader in `.claude/scripts/` — reads all three TSVs, prefixes IDs by source
  - Done: `loadGrammarDatabases()` in `.claude/scripts/shared.mjs`
- [x] Parse `<details><summary>Grammar</summary>` blocks from Markdown (parallel to vocab extraction)
  - Done: `extractGrammarBullets()` in `.claude/scripts/shared.mjs`
- [x] Build `check-grammar.mjs` — validates grammar tags against known databases, reports unknown IDs
  - Done: `.claude/scripts/check-grammar.mjs`
- [x] Build equivalence groups: LLM-assisted clustering of topics across databases
  - Output: `grammar-equivalences.json` — array of arrays of prefixed topic IDs (e.g. `[["bunpro:causative", "genki:causative", "dbjg:saseru"]]`)
  - `add-grammar-equivalence.mjs`: pure graph operation script
    - 1 argument: adds topic as a singleton group
    - 2+ arguments: merges all into one group (union-find style), idempotent
    - Reads/writes `grammar-equivalences.json`
  - `/cluster-grammar-topics` skill: finds topics in `grammar.json` missing from `grammar-equivalences.json`, uses LLM to suggest matches against all three databases, calls `add-grammar-equivalence.mjs` to apply
  - Checked into repo, manually reviewable
- [x] Generate `grammar.json` (analogous to `vocab.json`)
  - `sources`: metadata per database
  - `topics`: keyed by prefixed ID, contains title, level, href, example sentences, equivalence group
  - Done: `prepare-publish.mjs` collects grammar annotations and writes `grammar.json`
- [x] Update `prepare-publish.mjs` (or equivalent) to produce `grammar.json` alongside `vocab.json`
- [x] `prepare-publish.mjs` validation: fail if any topic in `grammar.json` is missing from `grammar-equivalences.json`

### Content workflow

1. Edit Markdown files — add `<details><summary>Grammar</summary>` blocks with `source:id` bullets
2. Run `check-grammar.mjs` — validates all IDs exist in the three grammar databases
3. Run `prepare-publish.mjs` — produces `grammar.json` (and `vocab.json`); **fails** if `grammar-equivalences.json` is missing any topics
4. If step 3 fails, run `/cluster-grammar-topics` — adds new topics to `grammar-equivalences.json` (LLM-assisted, then manually review the diff)
5. Re-run `prepare-publish.mjs`
6. [x] `publish.mjs` pushes `grammar.json` alongside `vocab.json`
7. TODO: bundle `grammar.json` and `grammar-equivalences.json` into the iOS app

### Phase 1A — Core library (TestHarness-compatible)

- [x] GRDB migration: `grammar_enrollment` table (topic_id, status, enrolled_at)
  - Reuse existing `ebisu_models` and `reviews` tables with `word_type = 'grammar'`
- [x] Grammar JSON loader — `GrammarSync.swift`; model types `GrammarManifest`, `GrammarTopic`, `GrammarSourceMeta`; URL derived from vocab URL (same Gist)
- [x] `GrammarQuizContext.swift` — `GrammarQuizItem` + context builder ranked by Ebisu recall; scaffolding topic list for difficulty scaling; `QuizDB` extensions for grammar enrollment and review counts
- [x] `GrammarQuizSession.swift` — tier-1 multiple choice only (production + recognition); system prompt builder with topic info + scaffolding list; `generateQuestionForTesting` + `gradeAnswerForTesting` entry points; `GrammarMultipleChoiceQuestion` parsed from Claude JSON
- [x] TestHarness integration: `--grammar <topic_id>` mode with `--dump-prompts`, `--live`, and single-item generate; symlinks added for all three new Swift files
- [x] Update documentation in TESTING.md
- [x] Tier 2 (fill-in-the-blank) library — two-stage grading:
  - [x] Fast path: `GrammarQuizSession.gradeFillin(studentAnswer:correctAnswer:)` — pure Swift string match (normalize trailing 。/、 and whitespace) against `choices[correctIndex]` from the tier-1/2 generation call. Score 1.0 immediately, no LLM.
  - [x] Fallback coaching path: `GrammarQuizSession.gradeTier2FallbackForTesting(item:stem:referenceAnswer:studentAnswer:)` — invoked when string match fails. Haiku acts as a coaching tutor: scores immediately if the answer is clearly right (different valid form) or clearly wrong; asks a focused Socratic question if the answer is close but uses the wrong construction, then waits for the student's next attempt. Multi-turn conversation continues until SCORE is emitted or a max-turn limit is reached.
  - [x] TestHarness `fillin-grading` path: tests exact match, wrong-choice rejection, and punctuation normalization (no LLM). `fillin-fallback` path: generates a question, sends a wrong distractor as the student's first attempt to trigger the coaching path, then validates SCORE format.
  - Graduation threshold: ≥ 3 reviews, halflife ≥ 72 h.
- [x] Tier 3 (free text) production + tier 2 free text recognition — `GrammarQuizSession.generateFreeTextStemForTesting()`: LLM generates English context (production) or Japanese sentence (recognition); `gradeAnswerForTesting()` grades with SCORE + opportunistic `PASSIVE: topic_id score` lines. Graduation threshold for production tier 3: ≥ 6 reviews, halflife ≥ 120 h.
  - [x] TestHarness: `free-generation` and `free-grading` paths added to `allGrammarPaths`; live mode validates stem language (English-only or Japanese), SCORE token, score ≥ 0.8 for correct answer, and PASSIVE line format.
  - [x] System prompts updated with SCORE and PASSIVE instructions; distractor prompt tightened to exclude alternative-correct constructions (e.g. ことができる as a potential-verb distractor).
  - [x] `GrammarQuizItem.tier: Int` added (1/2/3 for production, 1/2 for recognition); computed from review count + halflife in `GrammarQuizContext.build()`.
  - [x] TESTING.md updated with tier table, thresholds, and validation check list.
- [x] `--extra-grammar topic1,topic2` flag in TestHarness to simulate a student who knows specific grammar, for testing difficulty scaling

### Phase 1B — iOS Views

- [ ] Grammar topic list view — filterable by source, level, enrollment status
- [ ] GrammarDetailSheet — example sentences, chat box (Claude), mnemonic support
  - Reuses mnemonic infrastructure with `word_type = 'grammar'`
- [ ] Grammar quiz view — tier 1 multiple choice (reuses `GrammarQuizSession` from Phase 1A)
- [ ] Grammar quiz: fill-in-the-blank (tier 2) — requires tier 2 library from Phase 1A
- [ ] Grammar quiz: free text with opportunistic passive grading (tier 3) — requires tier 3 library from Phase 1A; passive Ebisu updates for all `PASSIVE:` lines in response
- [ ] Integrate grammar items into unified quiz scheduling (alongside vocab)

### Prompt design decisions (2026-03-14)

**Target grammar strictness (all production grading paths).**
All production grading — tier 2 fill-in-the-blank fallback (path 4), tier 3 free text (path 6) —
requires the student to use the *specific target grammar form*, not a semantically equivalent
alternative construction. If the student writes correct Japanese that uses a different construction
(e.g. ことができる instead of potential verb form), Haiku coaches them toward the target form
rather than scoring immediately. If they cannot produce it after coaching, score is 0.0–0.2.
Rationale: without this, the Ebisu model for the target grammar never gets meaningful signal.

**Production tier 3 grading is multi-turn coaching.**
Like tier 2 fallback, tier 3 production grading uses a multi-turn coaching conversation
(`gradeTier3ProductionForTesting`). Haiku also points out other errors in the student's
Japanese (wrong particles, conjugation mistakes) as coaching notes — but these don't affect
the SCORE for the target grammar.

**Recognition tier 2 expects English translation only.**
The recognition tier 2 grading prompt expects a plain English translation, not grammar
analysis or metalinguistic explanation. SCORE reflects whether the translation captures
the meaning that the target grammar conveys.

**Stem generation: reasoning + divider format.**
Free-text stem generation (production tier 3, recognition tier 2) allows Haiku to reason
before a `---` divider. After the divider: only the stem text. The parser strips everything
before `---`. This improves output quality without polluting the stem.

**GRAMMAR_TOPICS: stem generation emits topic IDs for passive grading.**
When scaffolding topics are provided, the stem generation step asks Haiku to emit a
`GRAMMAR_TOPICS: id1, id2, ...` line listing which scaffolding topics the sentence exercises.
These IDs are parsed and passed to the grading prompt, which uses them for PASSIVE lines.
This avoids the grader guessing topic IDs (which may not match actual IDs in the system).
When scaffolding is empty, no GRAMMAR_TOPICS line is requested and no PASSIVE is possible.

**Passive grading of botched extra topics.**
When the student's response demonstrates incorrect use of a non-target grammar topic from the
GRAMMAR_TOPICS list, Haiku should skip emitting a PASSIVE line for that topic (neither positive
nor negative). Rationale: the student's attention is on the main quiz topic; errors in peripheral
grammar may reflect inattention rather than lack of knowledge, and a negative passive update
would unfairly penalize them. Only emit PASSIVE when there is genuine positive evidence.

**Paths 1 and 2 produce identical prompts (by design).**
Tier 1 and tier 2 production use the same multiple-choice generation prompt. The only
difference is the halflife in the Memory line (24h vs 96h, reflecting different graduation
thresholds). The generated question is reused: tier 1 shows it as tap-a-button, tier 2
shows it as type-the-answer (fill-in-the-blank).

### Model selection: Haiku is the right choice (2026-03-14)

Ran `genki:potential-verbs` production facet (all 6 paths, with `bunpro:causative` and
`bunpro:Verb[passive]` scaffolding) against Haiku, Sonnet 4.6, and Opus 4.6 in parallel.
All three models passed all 6 validation checks. Key findings:

- **Latency**: Haiku 2–9 s per call; Sonnet 5–18 s; Opus 13–22 s. For a quiz app where
  the student is waiting at a spinner, Sonnet and Opus are too slow for real-time use.
- **Spicy food fixation**: Haiku repeatedly defaulted to 食べる/食べ物 scenarios even with
  scaffolding; Sonnet and Opus naturally varied their verbs (泳ぐ, 話す, 読む) and wove
  scaffolding grammar into richer multi-clause sentences.
- **GRAMMAR_TOPICS accuracy**: Haiku (old comma-separated prompt) hallucinated
  `bunpro:causative` for a sentence that contained no causative construction. Switching to
  a JSON array format with "only include if syntactically present" fixed the hallucination
  in subsequent Haiku runs.
- **Coaching quality**: Sonnet and Opus produced cleaner, more focused coaching responses.
  Haiku occasionally echoed template language from the prompt that didn't apply to the
  student's actual mistake.

**Conclusion**: Haiku quality gaps are addressable with prompt improvements (verb-variety
nudge, JSON GRAMMAR_TOPICS, pattern-not-example phrasing in coaching). Sonnet and Opus
produced noticeably better output — richer multi-clause sentences that naturally wove
scaffolding grammar in, more accurate GRAMMAR_TOPICS attribution, and cleaner coaching
responses. However, the latency gap is large. Note that the vocab quiz already masks
latency by prefetching the next question as soon as the student submits their answer;
grammar quizzes could do the same, which would make Sonnet's 5–18 s more tolerable.
For now, stick with Haiku and improve prompts; revisit Sonnet if prompt improvements
plateau or if prefetch makes the latency acceptable in practice.

### Prompt quality observations (from 2026-03-15 live tests)

Iterated on fill-in-the-blank generation prompt across `genki:potential-verbs`,
`bunpro:causative`, and `genki:shi`. All 6 paths pass. Key changes made and their effects:

**Changes implemented (2026-03-15):**

- **Mandatory chain-of-thought in `questionRequest`** (replaces "Think first if helpful"):
  Five explicit steps — (1) write full sentence with no gaps, (2) bracket the grammar slot(s),
  (3) self-check that the target form doesn't appear outside the brackets, (4) English stem,
  (5) three distractors each verified to produce valid Japanese when substituted.
  Fixed: ことができる appearing in sentence body alongside the gap; causative subject reversal;
  nonsense distractors (e.g. `捕まええない`).

- **Bracket size instruction updated**: old example `彼女はピアノが【弾け】ない` taught
  verb-stem splitting. New instruction: "bracket enough so every choice combines cleanly with
  the surrounding text." For conjugation grammar: include auxiliaries → `【弾けない】`.
  For conjunction/particle grammar: the particle is the complete unit → `【し】`.
  This generalizes cleanly — tested with `genki:shi` (two-gap 〜し〜し), where each gap is
  correctly a single conjunction character.

- **Quirky instruction relaxed**: "quirky, unexpected, or funny" reduced to "Vary the verb and
  setting; 食べる, 飲む, and 泳ぐ are overused." Removes pressure to reach for unusual vocabulary
  that caused e.g. `撃つ` (shoot a weapon) for a basketball scenario.

- **Correct index now randomized**: added explicit instruction to place the correct fill at a
  randomly chosen index (0–3). Previously Haiku defaulted to index 0 almost every time.

**Remaining observations / open items:**

- **ことができる is no longer a relevant concern for fill-in-the-blank** generation: short
  conjugation fills can't contain ことができる, so the old distractor problem is moot. The
  prompt's "Do NOT use ことができる" now guards against it leaking into the sentence body,
  which is a different (and rarer) pathology — the chain-of-thought self-check handles it.

- **Enriched topic descriptions**: the current prompt provides only topic ID, title, level, and a
  reference URL (which Haiku cannot fetch). For well-known topics like potential verbs and causative,
  Haiku's internal knowledge is sufficient. For more obscure or ambiguous topics this may be
  insufficient.
  - **TODO**: Consider adding an LLM-generated summary per equivalence group at `prepare-publish.mjs`
    time and injecting it into the quiz system prompt. This would be especially useful for topics
    where the title alone is ambiguous (e.g. `bunpro:てならない` — "Very, Extremely, Can't help but
    do" is enough, but a two-sentence gloss of the conjugation pattern could prevent errors on
    unusual topics).
  - **TODO**: The descriptor for `genki:potential-verbs` (and any equivalent group entry) must
    explicitly note that ら抜き言葉 forms (e.g. `食べれる`, `見れる`) are colloquially accepted
    alternatives — Genki II Chapter 13 calls this out explicitly. Haiku must not use these as
    distractors (a student who writes `食べれます` is arguably correct) and must not penalize them
    in grading. The distractor for "wrong potential form" should be an unambiguously wrong
    conjugation instead (e.g. dropping the potential suffix entirely, or using the wrong verb class
    pattern).

- **Token budget**: the chain-of-thought prompt is more verbose (~400–500 reasoning tokens before
  the JSON). One PATH 4 generation hit the 1024 maxTokens ceiling and needed a retry. Consider
  raising maxTokens for grammar generation calls to 1500 or 2000.

- **Full-sentence multiple choice reconsidered**: the original motivation for fill-in-the-blank
  included "generating four same-meaning sentences is hard." This framing was wrong — distractors
  in full-sentence MC should express *different* (plausibly wrong) meanings, not the same meaning.
  Full-sentence MC with different-meaning choices is actually feasible and arguably better for
  single-gap grammar (the surrounding context provides more information). Fill-in-the-blank remains
  the right design for multi-gap patterns (〜し〜し, ば〜ほど) where short fills per gap is cleaner.
  A future UI could diff-highlight the varying parts of full-sentence choices to aid readability.

- **Part-of-speech annotation for coaching accuracy**: Haiku occasionally misidentifies verb
  class in coaching responses (observed: calling 弾く a "る-verb" and directing the student
  toward the ichidan potential pattern 食べ**られ**る, when the correct godan pattern is
  弾**け**る). This happens because the coaching prompt only receives the correct fill string
  (e.g. `弾ける`) without knowing how it was derived.
  - **Option A — annotate the generation JSON**: ask the generation step to include a
    `verbNote` field (e.g. `"verbNote": "godan: 弾く → 弾ける"`) alongside `sentence` and
    `choices`. The coaching prompt receives this as a plain-text hint, no extra tool calls.
  - **Option B — lookup_jmdict in coaching**: give the coaching LLM access to `lookup_jmdict`
    so it can look up the verb's part-of-speech tag (e.g. `v5k` = godan-ku). Adds latency and
    tokens on every coaching turn.
  - Option A is simpler and token-cheaper; Option B is more general. Current priority: low —
    the error is rare and the student can still reach the correct answer despite the wrong hint.
  - **See also**: `lookup_jmdict` already returns part-of-speech data for vocab quizzes
    (via `ToolHandler.swift`); the data is available if needed.

- **VOCAB_ASSUMED: on-demand vocabulary glossary for grammar quiz stems**: grammar quiz stems
  use vocabulary that the student may not know — vocabulary knowledge should not block grammar
  testing. Both production (English → Japanese) and recognition (Japanese → English) facets can
  benefit from this.
  - **Design**: during stem generation (tier-2 fill-in-the-blank / tier-3 free-text / recognition
    tier-2), Haiku emits a `VOCAB_ASSUMED: word1,word2,...` line listing the key content words
    the student needs in order to answer the question (e.g. `VOCAB_ASSUMED: 泳ぐ,海` for a
    swimming-in-the-ocean stem). This line is parsed and stored alongside the stem; it is NOT
    shown to the student by default.
  - **App UX**: a "Show vocabulary" button appears below the stem. Tapping it reveals a glossary
    with the assumed words and their meanings (looked up from the local JMDict). Experienced
    learners who know the words can ignore it; beginners can refer to it without penalty.
  - **Passive vocab boost**: if any VOCAB_ASSUMED word is enrolled in the student's vocab list,
    the grading step can emit a `PASSIVE_VOCAB: word_id score` line (analogous to `PASSIVE:` for
    grammar) to award a passive recall update. This is a free bonus — the student used the word
    in a grammar context without being explicitly quizzed on it.
  - **Grading with VOCAB_ASSUMED**: grade based on grammar-form correctness, not vocabulary
    precision. If the student uses the correct grammar form but the wrong vocabulary (e.g.
    answers a swimming question with a sentence about eating), Haiku should note the vocabulary
    mismatch in coaching but still score the grammar form appropriately. A completely off-topic
    response (correct grammar, unrelated context, no attempt to address the stem) should score
    lower because the grammar demonstration is decontextualized — the student may be gaming
    the quiz rather than translating.
  - **Open question**: how many words to include in VOCAB_ASSUMED? Keep it to 2–5 essential
    content words (verbs, nouns). Particles, copulas, and the target grammar structure itself
    should not be listed — the whole point is to test those.
  - **Format consideration**: for tier-2 fill-in-the-blank (multiple choice), the correct answer
    itself implicitly reveals the vocabulary, so VOCAB_ASSUMED is less critical there. Most
    useful for tier-3 free-text production and recognition tier-2 free-text.

- **Furigana for unknown kanji in quiz questions**: recognition stems are Japanese sentences
  containing the target grammar. Students who haven't learned all the kanji in a sentence may be
  blocked by kanji they've never seen rather than tested on the grammar.
  - **TODO**: Show furigana (ruby text) on kanji the student hasn't enrolled or committed to. The
    app already has vocab enrollment and kanji commitment data; the quiz display layer could suppress
    furigana only for kanji the student has committed to and reveal it for everything else. This is
    non-trivial because the sentence is LLM-generated (not from JMDict), so furigana would need to
    be either (a) generated by the LLM alongside the sentence, or (b) added via a local lookup
    (JmdictFurigana or similar) after generation. LLM-side is simpler to implement first.

### Future

- [ ] Error-correction and sentence-completion quiz variants
- [ ] Cross-database linking UI — surface equivalences to user, allow manual adjustments
- [ ] Dictionary of Intermediate / Advanced Japanese Grammar databases
- [ ] Grammar → vocab connections (e.g., a grammar quiz sentence uses enrolled vocab)
- [ ] Difficulty analytics — track which grammar points have low recall, suggest review strategies
