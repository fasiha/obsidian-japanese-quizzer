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

## Writing style

Avoid opaque abbreviations in code comments, documentation, and commit messages.
Write out full names like `reading-to-meaning`, `multiple choice`, and
`kanji-to-reading` instead of shorthand like `rtm`, `MCQ`, or `ktr`. This project
aims to be accessible to beginners and non-native English speakers.
