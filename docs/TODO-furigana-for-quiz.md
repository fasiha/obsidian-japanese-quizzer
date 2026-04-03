# Furigana for grammar quiz — implementation plan

Goal: show furigana above Japanese text in grammar quiz questions (recognition stem,
production gapped sentence, and vocab glosses), using JmdictFurigana for accuracy
instead of Haiku-generated ruby HTML.

---

## Summary of approach

1. Add a `furigana` table to `jmdict.sqlite` (new Node.js migration step).
2. Open that table in the iOS app alongside the existing JMDict queries.
3. In `fetchAndResolveVocab`, after the JMDict lookup that gives us a reading, look up
   `(word, reading)` in the furigana table → `[FuriganaSegment]`.
4. For words with no JMDict match or no furigana table entry, try `NLTagger` lemma
   segmentation to find sub-word boundaries, then look up each segment.
5. Revert the Haiku prompt change (remove `ruby_html` / `parseRubyHTML`); keep all the
   view-layer work (SentenceFuriganaView, VocabGloss.rubySegments, etc.).

---

## Step 1 — Add `furigana` table to jmdict.sqlite (Node.js) ✅

Write a new script `.claude/scripts/add-furigana-to-jmdict.mjs`:

- Opens `jmdict.sqlite` via `openJmdictDb()`.
- Creates the table if it doesn't exist:
  ```sql
  CREATE TABLE IF NOT EXISTS furigana (
    text    TEXT NOT NULL,   -- written form, e.g. 食べ物
    reading TEXT NOT NULL,   -- kana reading, e.g. たべもの
    segs    TEXT NOT NULL,   -- JSON array of {ruby, rt?} segments
    PRIMARY KEY (text, reading)
  );
  ```
- Reads `JmdictFurigana.json` (UTF-8 BOM file in project root) and bulk-inserts all
  230 000 entries in a single transaction.
- Exits cleanly if the table already exists and is populated (idempotent via `INSERT OR IGNORE`).
- Sets DELETE journal mode before and after (same as the rest of the tooling).

Update **README.md** jmdict.sqlite setup section to include:

```sh
# 2b. Add JmdictFurigana data (requires JmdictFurigana.json in project root)
#     Download from: https://github.com/Doublevil/JmdictFurigana/releases
node .claude/scripts/add-furigana-to-jmdict.mjs

# 3. Copy updated jmdict.sqlite into Resources
cp jmdict.sqlite Pug/Pug/Resources/jmdict.sqlite
```

---

## Step 2 — iOS: expose the furigana table ✅

In `ToolHandler.swift` or wherever the JMDict database reader is opened, confirm the
same `DatabasePool` / `DatabaseQueue` that serves `lookup_jmdict` can also serve simple
`SELECT segs FROM furigana WHERE text=? AND reading=?` queries. No new file needed —
this is the same `jmdict.sqlite` connection.

Add a small helper (probably in `GrammarQuizSession.swift` near `fetchAndResolveVocab`):

```swift
/// Look up pre-computed furigana segments for a written form + reading pair.
/// Returns nil when no entry exists (caller should fall back to NLTagger).
nonisolated func lookupFurigana(
    text: String,
    reading: String,
    db: any DatabaseReader
) -> [FuriganaSegment]?
```

This does a single `SELECT segs FROM furigana WHERE text=? AND reading=?`, decodes the
JSON blob, and returns `[FuriganaSegment]`.

---

## Step 3 — Wire furigana into fetchAndResolveVocab ✅

After the JMDict step already resolves a reading for each word, add:

1. Extract the first kana reading from the matched JMDict entry's JSON blob (`entry["kana"][0]["text"]`).
2. Call `lookupFurigana(text: word, reading: kanaReading, db: db)`.
3. If found → use those segments as `rubySegments`.
4. If not found → fall through to Step 4 (NLTagger fallback, see below).
5. For words with no JMDict match at all, also try Step 4 with the bare word string.

Remove the `ruby_html` field from the Haiku prompt (revert to `[{"word":"...","gloss":"..."}]`,
`maxTokens` back to 128). Remove `parseRubyHTML()` and all `rubySegments` wiring that
came from Haiku. Keep `VocabGloss.rubySegments` and all view-layer code — the field is
now populated by the furigana table instead.

---

## Step 4 — NLTagger fallback for words not in JmdictFurigana

For a word like a compound that Haiku gave us that doesn't appear verbatim in JmdictFurigana:

1. Use `NLTagger` with the `.lemma` scheme on the word string to get iOS-suggested
   sub-word segments (NLTagger does Japanese word segmentation well; `.lemma` gives
   dictionary forms of each token).
2. For each segment returned by NLTagger, look it up in the furigana table (exact match
   on `text`; pick the entry whose `reading` matches the NLTagger lemma if multiple
   entries exist, otherwise pick the first).
3. Concatenate the resulting segment arrays across all sub-words.
4. If NLTagger produces no useful split (single token = original word), fall back to
   returning `nil` for `rubySegments` (plain word display, no furigana).

NLTagger note: `.lemma` requires `NLLanguageHint = .japanese`; set that explicitly.
`.tokenUnit = .word` is the right granularity. Readings are not directly exposed by
NLTagger, so Step 2 (above) uses the furigana table's first available reading for each
segment — which is almost always correct because NLTagger's segmentation aligns with
JMDict entries.

---

## Step 5 — Revert Haiku prompt changes, keep view layer ✅

Changes to revert:
- `GrammarQuizSession.swift`: remove `ruby_html` from prompt string, remove `parseRubyHTML()`,
  remove `rubySegments` field from `haikuWords` tuple type, revert `maxTokens` to 128,
  revert the three `VocabGloss(...)` call sites that pass `haikuRubySegments`.
- The comment block added to the prompt about `ruby_html` and okurigana.

Changes to keep (already correct, no need to undo):
- `VocabGloss.rubySegments: [FuriganaSegment]?` field.
- `FuriganaSegment: Equatable` conformance.
- `SentenceFuriganaView.swift` (new file — flow layout for sentence furigana).
- `GrammarQuizView.swift` changes: `SentenceFuriganaView` in stem display, ruby display in
  vocab gloss list.

---

## Step 6 — Furigana for production-facet choice buttons and cloze template ✅

### What needs annotating

Production questions have three Japanese text surfaces that need furigana:

1. **Gapped sentence** (`displayGappedSentence`) — already done via `stemView` in Step 3.
2. **Cloze template header** (`"\(cloze.prefix)___\(cloze.suffix)"`) — the shared prefix/suffix
   shown above the four buttons. This is a Japanese fragment, not a full sentence.
3. **Choice button labels** — each button shows either the full `choiceDisplay(i)` string, or
   when a cloze template exists, `"…\(core)…"` where `core = cloze.cores[i]`. These are
   Japanese grammar fragments.

### Approach

`SentenceFuriganaView(sentence:glosses:)` scans `sentence` for substrings matching each
`VocabGloss.word`. The glosses come from the stem sentence, but the same vocabulary words
appear verbatim in the choices and cloze fragments — so `SentenceFuriganaView` can be passed
any of these strings directly, no slicing or re-running the extractor needed.

#### 6a — Cloze template header

Replace `Text(template)` with `SentenceFuriganaView(sentence: template, glosses: gs)` where
`template = "\(cloze.prefix)\(grammarGapToken)\(cloze.suffix)"`. Guard on `if let gs = glosses`.

#### 6b — Choice button labels

Replace `Text(coreDisplay ?? question.choiceDisplay(i))` with
`SentenceFuriganaView(sentence: coreDisplay ?? question.choiceDisplay(i), glosses: gs)`.
Same guard. `SentenceFuriganaView` needs to be set `.multilineTextAlignment(.leading)` and
`.frame(maxWidth: .infinity, alignment: .leading)` to match the current `Text` layout.

#### 6c — Fallback while vocab is loading

Both surfaces already fall back gracefully — use the existing `if let gs = session.assumedVocab`
pattern from `stemView`, keeping plain `Text` until the async fetch completes.

### Files touched

| File | Change |
|------|--------|
| `Pug/Pug/Views/GrammarQuizView.swift` | replace `Text(template)` and `Text(coreDisplay)` in `awaitingTapView` with `SentenceFuriganaView` |

---

## Files touched

| File | Change |
|------|--------|
| `.claude/scripts/add-furigana-to-jmdict.mjs` | **new** — one-time migration script |
| `README.md` | document new step 2b in jmdict.sqlite setup section |
| `Pug/Pug/Claude/GrammarQuizSession.swift` | revert Haiku prompt; add `lookupFurigana()`; wire Step 3+4 |
| `Pug/Pug/Models/VocabSync.swift` | no change (Equatable already added) |
| `Pug/Pug/Views/SentenceFuriganaView.swift` | no change |
| `Pug/Pug/Views/GrammarQuizView.swift` | no change |

---

## Out of scope / future

- Adding furigana to the vocab quiz (separate feature; vocab already gets furigana from
  `word_commitment.furigana` at publish time).
- Suppressing furigana for kanji the user already knows (`kanji_knowledge` table — noted
  in README.md as future work).
- Fuzzy/greedy substring search (the original idea): NLTagger covers the same ground
  more reliably and is already on-device, so skip the manual prefix-shrinking loop.
- Can we use iOS local dictionary?

---

## Step 7 — NLTagger-based furigana (further research)

After Step 2 (single-kanji fallback), conjugated verb/adjective forms will still have
unannotated kanji because JmdictFurigana only stores dictionary forms. The recommended
next approach is a two-pass NLTagger pipeline:

### Step 7a — NLTagger tokenization (Approach C)

Use `NLTagger` with `.tokenType = .word` and `NLLanguageHint = .japanese` to segment the
sentence into clean tokens before any lookup. This fixes a correctness problem in Step 1:
substring search can misfire when two words abut. Tokenization gives reliable span
boundaries as a foundation for Step 7b.

For each token whose span is not already annotated and whose text appears verbatim in the
furigana table, do a direct `SELECT segs FROM furigana WHERE text=?` lookup. This gets
hits for uninflected nouns and compound words that the VocabGloss list from Haiku missed.

### Step 7b — Lemmatization + segment remapping (Approach A)

For tokens that still contain unannotated kanji after Step 7a, use `.lemma` to get the
dictionary form, look it up in the furigana table, then remap the lemma's ruby segments
onto the surface token:

- Kanji positions are stable across most conjugations (only the kana suffix changes).
- Strip the lemma's kana suffix from the segments and apply the kanji portion to the
  surface token's kanji prefix.
- Fall back gracefully (no annotation) for irregular verbs where lemma and surface token
  share no kanji prefix (e.g., する→し, くる→き, いい→よ).

### Implementation risks

- Segment remapping index arithmetic — unit-test with する-compounds and i-adjectives,
  which are the most common failure cases in grammar-quiz sentences.
- NLTagger lemmatization is imperfect on unusual or compound forms; silent fallback
  (no annotation) is the correct behavior.
