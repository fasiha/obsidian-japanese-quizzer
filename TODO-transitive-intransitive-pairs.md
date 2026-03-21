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

231 curated verb pairs in `transitive-intransitive/transitive-pairs.json`, built from [sljfaq.org](https://www.sljfaq.org/afaq/jitadoushi.html) (154 linguist-curated pairs as the verified spine) and a filtered [Anki deck](https://ankiweb.net/shared/info/92409330) (additional pairs), enriched with JMDict IDs (verified against definitions at build time), and reviewed by Opus which classified each as VALID or AMBIGUOUS. 12 BAD_PAIRs were evicted; 18 AMBIGUOUS pairs are retained with `ambiguousReason` notes.

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

## Future steps (after enrollment UI)

4. **Implement the pair quiz card**: two answer fields on one card with agency-cue prompts; decide on exact English cue phrasing
5. **Wire up Ebisu scheduling**: on pair review, full Ebisu update on both individual word models if enrolled; on individual word review, passive Ebisu update on any associated pair model
6. **Cross-link word detail sheets**: show pair partner info (and a tap target to it) on each word's detail sheet

- [ ] Consider how to add new transitive-intransitive pairs into this dataset.
