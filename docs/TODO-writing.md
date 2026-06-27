# Writing practice — plan

Goal: add a *writing* dimension to the project (today it is mostly vocabulary
and grammar **review** plus intensive **reading**). The long-term vision is a
dashboard that, over a multi-year journey, shows which "Japanese muscles" a
learner's writing exercises and which it neglects — vocabulary range, grammar
constructions, dependency-tree complexity, and register (colloquial vs written
vs keigo). Explicitly **not** a class grade, and explicitly wary of Goodhart's
law: the dashboard reports coverage and diversity, not a single score.

The core practice activity is **back-translation**: read an English gloss of a
passage you have already studied, write your own Japanese from it, then reveal
the original to compare. Unlike open English→Japanese translation, the source
is native Japanese, so it ships its own answer key — and the *gaps* between your
attempt and the original (words you could not produce, register mismatches,
errors) are the measurement surface.

## Two guiding principles

- **Measure cold, practice warm.** Your first attempt, written *before*
  revealing the original, is the true-level datapoint. Attempts after revealing
  are practice, not measurement. Keep them distinguishable.
- **Claude coaches, the deterministic system scores.** An LLM is sycophantic,
  drifts between sessions, and is non-reproducible — fine for feedback, wrong
  for the longitudinal record. Frequency/parse-based analysis is the
  scorekeeper; Claude is the per-session sparring partner.

## Short term (now) — just write

Lower the activation energy so the hard part (sitting down and writing) happens
daily, before any analysis infrastructure exists.

- [x] **`make-writing-practice.mjs`** — `.claude/scripts/make-writing-practice.mjs`.
  Takes an annotated reading file and writes `{original}.WRITING-PRACTICE.md`
  next to it. Each paragraph becomes a numbered card: an HTML-comment backlink
  (`source-line` + `source-hash`, a short SHA-256 of the source paragraph text)
  pointing at the paragraph in the original file, the English gloss shown as a
  quote, and blank lines for attempts. The original Japanese is **not included
  in this file at all** — not even collapsed — since VS Code (used on the
  laptop) doesn't hide `<details>` blocks. The hash lets the source paragraph be
  relocated even if line numbers shift from later edits. No LLM calls. Parses
  via the shared, fuzz-tested helpers (`iterateDetailsBlocks` +
  `findContextBefore`) rather than re-implementing Markdown parsing. Tested on
  both annotated NHK Easy articles.
- Workflow: generate a deck on the laptop, then *write on any device* — unlike
  annotation, back-translation is just typing Japanese into Markdown, so it
  works fine on the phone. Each line in a card's attempt area is one attempt;
  prefix/suffix it with the Obsidian "insert timestamp" template so the future
  parser can order revisions.
- Filesystem is the version history: each run writes a fresh, timestamped deck
  (`{source}.WRITING-PRACTICE.{YYYY-MM-DD-HH.MM.SS}.md`, readable local time, not
  a Unix timestamp), so doing the same passage again days later produces a new
  file rather than overwriting — the dated decks become the longitudinal record.

### On vocabulary hints (deferred, not rejected)

The script intentionally omits per-card vocab hints — they are a tempting
backdoor during a cold attempt. The case *for* eventually adding them as an
opt-in, separately-collapsed tier (never shown before the cold attempt): when
you blank on an opaque word (e.g. 成功, which you cannot build from its parts),
a lexical hint lets you finish the sentence and keep practicing sentence
structure instead of stalling — and *which* hint tier you needed is itself a
useful signal. Decide after collecting real attempts and seeing how often a
blank actually derails a card. Until then: original-only answer key.

## Long term (after a few days of collected attempts)

1. **Parser.** Read `*.WRITING-PRACTICE.md` files: pull each card's gloss,
   ordered timestamped attempts (cold vs post-reveal), and the original. Emit a
   clean structured record. The dated Markdown decks are the log; promote to a
   database only when the dashboard needs it.
2. **Deterministic analyzer** (the scorekeeper). Per attempt vs original, no
   LLM: vocabulary frequency/register profile via `bccwj.sqlite` (per-register
   PMW — colloquial OC/OY vs formal OW/OL/PN; see `docs/DATA-FORMATS.md`),
   word-origin (和語/漢語/外来語) ratio, JMDict coverage, and eventually
   dependency-tree complexity. Tracks coverage and diversity over time.
3. **Divergence classifier** (Claude in the loop, but classifying not grading).
   Tag each difference between attempt and original as: match / valid
   alternative / circumlocution / gap / error / upgrade. A string diff cannot
   tell a valid paraphrase from an error; this is where Claude earns its place.
   The deterministic analyzer then frequency/register-tags each item.
4. **Personalized production-demand queue.** Circumlocutions and gaps (words you
   *reached for* but could not produce) feed a learning queue that is far more
   predictive of your production needs than corpus frequency. You opt in per
   word — circumlocution is sometimes the better answer, so do not auto-drill
   everything. Candidate integration point: Pug review.
5. **Coaching skill** (Claude). A skill that grills/tests you: points at errors
   before revealing fixes (preserve the productive struggle), runs register
   transformation drills (rewrite casual → keigo), and Socratic interrogation
   ("why は not が here?"). Driven by whichever coverage gap the dashboard flags.
6. **Dashboard.** Visualize the longitudinal record: coverage gaps as
   prescriptions, and the migration of individual words across the
   circumlocution → match → upgrade boundary — the most motivating, least
   reductive progress signal.

## Appendix: gloss quality is the sleeper risk

Back-translation is a noisy-channel round-trip:
`Original(J) → [gloss] → Gloss(E) → [back-translate] → Attempt(J′)`. We want to
measure the *decode* step (production), but the *encode* step (glossing) is also
variable and lossy, and its noise contaminates the measurement.

- **The variability biases upward, asymmetrically.** Syntax-hugging "faithful"
  glosses *leak the answer* — back-translation becomes transcription of your own
  calque — which **inflates** measured ability. Natural/idiomatic glosses
  *underdetermine* the target (many valid Japanese renderings), which is *harder
  but honest*. Rule of thumb: for cards meant for back-translation, write the
  gloss **natural, not faithful**. (Faithful glosses remain fine for the reading
  comprehension they were invented for.)
- **A second upward bias: self-priming.** Even a natural gloss *you wrote* lets
  you recall *your own English choices* rather than produce from Japanese
  competence. An externally generated gloss you've never seen removes this. So
  human-gloss back-translation overestimates ability via two compounding routes
  (leakage + priming); the purest measurement uses a fresh external gloss.
- **Stationarity.** A multi-year dashboard needs a *stationary stimulus process*.
  If your gloss style drifts toward natural English as you mature, divergence
  rises and the dashboard misreads it as production *worsening*. This is the
  strongest argument for eventually standardizing the measurement-track gloss.
- **Structural blind spots no gloss quality can fix.** English glosses cannot
  carry register/politeness (行った vs 行きました vs 参りました), は-vs-が,
  synonym selection (成功した vs うまくいった), sentence-final nuance (ね/よ/んだ),
  or some aspect. So back-translation-from-gloss **cannot fairly test register or
  particle competence** — the very colloquial/written/keigo axis the dashboard
  most wants. That axis needs a *different* mechanism (annotate a target register
  on the card, or a dedicated transformation drill), not a better gloss.

**Proposed resolution (defer building until the confound is felt):** separate the
two glosses by purpose. The human gloss stays in the annotated file (reading aid,
J→E, may be clumsy). A *standardized* prompt-gloss — generated from the original
Japanese to a fixed natural-English, leak-controlled spec — feeds the measurement
deck. This preserves the valued "I read and annotated this myself" engagement
(unchanged upstream) while making the channel stationary and unprimed. Adding an
LLM glosser costs tokens (currently the pipeline is free/deterministic — ask
first), so the near-term move is: collect data with human glosses, introspect
per card on whether it felt like transcription vs real production, and only build
the standardized glosser once the effect size justifies it. A later refinement
could emit a *ladder* of glosses at controlled leakage levels (decoupled default,
more-literal optional reveal-tier), folding into the deferred vocab-hint idea.
