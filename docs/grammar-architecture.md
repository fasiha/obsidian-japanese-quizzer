# Grammar quiz architecture (Pug app)

## Data sources and equivalence groups

- **Three sources**: Genki (~123 topics), Bunpro (~943), DBJG (~370). All topic IDs are source-prefixed: `genki:potential-verbs`, `bunpro:られる-Potential`, `dbjg:rareru2`.
- **Equivalence groups**: Topics across sources covering the same grammar point are clustered in `grammar/grammar-equivalences.json`. Each group has a shared `summary`, `subUses` list, and `cautions` list (generated via `/cluster-grammar-topics` skill). `stub: true` marks groups with no user-annotated content sentences.
- **`grammar.json`**: personal per-user publish artifact (parallel to `vocab.json`), produced by `prepare-publish.mjs`. The iOS app fetches both `grammar.json` and `grammar/grammar-equivalences.json` (descriptions are generic and repo-committed, not personal).

## Enrollment and scheduling

- **Enrollment is equivalence-group-wide**: enrolling any topic creates `ebisu_models` rows for all siblings × both facets (`word_type='grammar'`). Uses existing `ebisu_models` and `reviews` tables.
- **Ebisu propagation at write time**: after reviewing one topic, all sibling rows that already exist in `ebisu_models` are updated with the same score.
- **`GrammarQuizContext.build()`**: ranks enrolled topics by recall probability, collapses equivalence groups (one representative per group per facet, lowest recall wins), selects 3–5 from the top-10 pool.

## Facets and tiers

Only Tier 1 is active in the iOS app. Higher tiers are implemented in `GrammarQuizSession` but gated by review-count/halflife thresholds set absurdly high.

| Facet | Prompt shows | Student produces |
|---|---|---|
| `production` | English context sentence | Japanese using the target grammar |
| `recognition` | Japanese sentence | English meaning |

- **Tier 1** (current): always multiple choice. LLM generates stem + 4 choices + correct index as JSON; app scores instantly (1.0/0.0). LLM then coaches in a chat turn.
- **Tier 2 production**: fill-in-the-blank (cloze). Fast-path pure-Swift string match; fallback Haiku coaching if match fails.
- **Tier 3 production / Tier 2 recognition**: free-text, LLM-graded with `SCORE: X.X`.

## Sub-use diversity

Each question generation call includes `recentNotes` (last 3 `reviews.notes` entries for that topic+facet) and instructs Haiku to target a different sub-use. The LLM response includes `"sub_use"` (JSON) or `SUB_USE:` (free-text) identifying which sub-use was exercised; this is stored in `reviews.notes`.

## Assumed vocabulary ("Show vocabulary" button)

After generating a tier-1 question, a separate async Haiku call identifies N4-unfamiliar content words in the stem sentence. Each word is resolved against JMDict (`findExact`); JMDict's gloss is used when available, Haiku's gloss as fallback.
