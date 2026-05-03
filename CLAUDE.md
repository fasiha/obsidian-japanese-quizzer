See `README.md` for a full project overview. The bulk of this repo is an iOS app (Pug).
Node.js scripts in `.claude/scripts/` and in `./` exist to support content development.

Claude never writes directly to SQLite and never writes to the user's Markdown content.

The iOS app bundles a complete copy of JMDict (all ~200 k entries) and all of
JmdictFurigana in `jmdict.sqlite`. Any feature that needs dictionary lookups,
readings, or furigana segmentation should query this database rather than
hard-coding or duplicating data. `vocab.json` and `transitive-pairs.json` store
only IDs and user-specific metadata; all linguistic content (senses, kanji
forms, readings) is fetched at runtime from `jmdict.sqlite`.

- See `docs/DATA-FORMATS.md` for the shape of `vocab.json`, `transitive-pairs.json`,
`grammar/grammar-equivalences.json`, and the `entries`/`furigana` tables in
`jmdict.sqlite`.
- `docs/swiftui-architecture.md` — environment vs explicit props rules
- `docs/quiz-architecture.md` — vocabulary quiz facets, grading, multiple choice vs free-answer, prompt variations
- `docs/grammar-architecture.md` — grammar equivalence groups, enrollment, tiers, sub-use diversity
- `docs/feature-parity.md` — required features for every quiz view and detail sheet

## Fuzzers

When edits touch fuzzed code paths, run the relevant fuzzer in the same change
and confirm it passes before reporting done. Triggers:
[`shared.mjs`](.claude/scripts/shared.mjs), [`markdown-ast.mjs`](.claude/scripts/markdown-ast.mjs),
[`prepare-publish.mjs`](prepare-publish.mjs), or other content-pipeline
scripts → `node fuzz.mjs` plus `node fuzz-markdown-golden.mjs` (regenerate the
local golden via `--write` first if missing — see file header). If the edit
changes cache-key construction in `prepare-publish.mjs` (`normalizeContextForCache`,
`refComputedFrom`, or the cache load/lookup sites), also run
`node fuzz-markdown-golden-verify.mjs` to confirm the harness's inlined copy
still mirrors `prepare-publish.mjs`. Edits to
`QuizSession`, `EbisuModel`, `WordCommitment*`, `KanjiInfoCard`, partial-template
code, or counter logic → `swift run TestHarness --fuzz <area>` for the matching
area in [docs/TODO-fuzzing.md](docs/TODO-fuzzing.md). When introducing new
stateful, parser-y, or math-y logic, articulate one or two free-oracle
invariants and add them to the appropriate fuzzer in the same change — that's
where the highest-yield bugs have been found historically. No need to run fuzzers
for unrelated edits (UI tweaks, copy, isolated bug fixes) — the noise trains
everyone to ignore the signal.

## Writing style

Avoid opaque abbreviations in code comments, documentation, and commit messages.
Write out full names like `reading-to-meaning`, `multiple choice`, and
`kanji-to-reading` instead of shorthand like `rtm`, `MCQ`, or `ktr`. This project
aims to be accessible to beginners and non-native English speakers.
