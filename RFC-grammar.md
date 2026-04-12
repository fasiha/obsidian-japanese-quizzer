# RFC: Simplifying Grammar Clustering Workflow for Smaller LLMs

The current `cluster-grammar-topics.md` workflow is designed for frontier models (like Claude 3.5 Sonnet) that can handle complex "discovery" tasks—searching across multiple database formats and managing high-dimensional linguistic constraints in a single session.

Smaller local LLMs (e.g., Gemma-4-31b) struggle with "discovery" (guessing IDs) and "drift" (quality loss during batch processing). To resolve this, we propose moving from an **Agent-led Skill** (prose instructions) to a **Script-led Pipeline** (deterministic sequence of calls).

> Background on the grammar databases is given in [Grammar.md](./grammar/Grammar.md)
>
> The current equivalences file is in [grammar-equivalences.json](./grammar/grammar-equivalences.json) and you can see the current list of equivalent grammar topics found by running `cat grammar/grammar-equivalences.json | jq '.[].topics'`.

## Implemented Pipeline Architecture

Instead of a single large prompt, the workflow is decomposed into a series of atomic Node.js scripts. This transforms the LLM's role from a "Searcher" (trying to find needles in a haystack) to a "Verifier" (confirming if a provided candidate is a match).

### 1. Sequence of Operations

| Step | Script / Action | Input | Intermediate Output | LLM Role |
| :--- | :--- | :--- | :--- | :--- |
| **1. Filter** | `find-new-grammar-topics.mjs` | `grammar-equivalences.json` | `new-topics.json` | None |
| **2. Discover** | `suggest-grammar-matches.mjs` | Topic ID + Slug + Web Content + All TSVs | `potential-matches.json` | **Search Strategist** |
| **3. Gather** | `gather-references.mjs` | `potential-matches.json` | `reference-content.json` | None (HTTP Fetch) |
| **4. Decide** | `verify-equivalences.mjs` | `potential-matches` + `reference-content` | `equivalence-decision.json` | **Verifier** (Yes/No match) |
| **5. Commit** | `apply-equivalence.mjs` | `equivalence-decision.json` | $\rightarrow$ `grammar-equivalences.json` | None |
| **6. Enrich** | `generate-description.mjs` | `reference-content` + User Sentences | `description-draft.json` | **Linguist** (Drafting) |
| **7. Apply** | `write-description.mjs` | `description-draft.json` | $\rightarrow$ `grammar-equivalences.json` | None |

### 2. Execution

The pipeline is orchestrated by a master script that ensures sequential execution:

```bash
node grammar/scripts/cluster-grammar.mjs
```

LLM interactions are handled via the `@anthropic-ai/sdk`, supporting both frontier models (like Claude 3.5 Sonnet) and local LLM endpoints compatible with the Anthropic API.

---

### 2. Intermediate File Definitions

To ensure transparency and allow for manual overrides, the pipeline uses structured intermediate JSON files:

- **`potential-matches.json`**: A list of candidates found via aggressive keyword search (ID, Title-JP, Title-EN, Gloss).
  ```json
  {
    "target": "genki:naru-to-become",
    "candidates": [
      { "id": "dbjg:naru", "reason": "exact id match" },
      { "id": "bunpro:になる-くなる", "reason": "keyword 'become' in title-en" }
    ]
  }
  ```
- **`reference-content.json`**: The raw context extracted from reference URLs for the target and all candidates.
- **`equivalence-decision.json`**: The LLM's binary verification output.
  ```json
  {
    "group": ["genki:naru-to-become", "dbjg:naru", "bunpro:になる-くなる"],
    "confidence": "high",
    "reasoning": "All three describe the basic change-of-state verb 'naru'..."
  }
  ```
- **`description-draft.json`**: The linguistic enrichment produced by the "Linguist" pass.

---

### 3. Refined LLM Roles

By isolating the LLM calls, we can apply specific prompting strategies to each role:

#### Role A: The Search Strategist (`suggest-grammar-matches.mjs`)
The discovery phase is no longer a simple string match, but a linguistic search. The LLM analyzes the target topic's context to generate a broad list of potential search fragments.
- **Knowledge Ingest**: The script fetches the `href` content. The LLM is provided with the `slug`, `titleJP`, `titleEN`, and the full web content.
- **Failure Mode**: If the `href` fetch fails, or if the LLM determines the web content is empty or irrelevant to the grammar topic, the script must fail loudly.
- **Task**: Generate a list of search fragments (stems, kanji variations, related terms, and Romaji) that would likely appear in other grammar databases.
- **Execution**: The script then performs a case-insensitive search of these fragments across all `titleJP` and `titleEN` fields in the grammar TSVs to identify candidates.

#### Role B: The Verifier (`verify-equivalences.mjs`)
The task is binary. The prompt focuses on comparing two reference texts to see if they describe the same grammatical mechanism.
- **Constraint**: Do not hallucinate IDs; only select from the provided `candidates` list.
- **Benefit**: Extremely high accuracy even for small models.

#### Role B: The Linguist (`generate-description.mjs`)
The task is creative synthesis. We use an atomic, multi-step Chain-of-Thought pipeline for *each* group:
1. **Analysis**: Extract core grammatical mechanism from reference content.
2. **Drafting**: Write summary and sub-uses.
3. **Example Creation**: Draft original examples (strictly avoiding copyright).
4. **Caution Identification**: Draft "positive" rules to avoid priming errors.
5. **Self-Correction**: Review draft against the "Priming Risk" and "Copyright" checklist.

## Comparison Summary

| Feature | Current Workflow (Frontier) | Proposed Pipeline (Local LLM) |
| :--- | :--- | :--- |
| **Logic Flow** | Agent-led (Prose $\rightarrow$ Tool $\rightarrow$ Prose) | Script-led (Input $\rightarrow$ Transform $\rightarrow$ Output) |
| **Search Method** | LLM guessing IDs/slugs | Keyword-based Candidate Generation |
| **Matching Role** | Discovery $\rightarrow$ Decision | Verification $\rightarrow$ Decision |
| **Enrichment** | Batch generation | Atomic, multi-step pipeline per group |
| **Reliability** | High (depends on model intelligence) | Very High (deterministic discovery + focused verification) |
