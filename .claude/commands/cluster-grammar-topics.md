---
description: Find new grammar topics and cluster them into equivalence groups
---

This skill updates `grammar-equivalences.json` by finding grammar topics in
`grammar.json` that are not yet in any equivalence group, then using LLM
knowledge to decide if they match existing topics.

## Step 1: Find new topics

Run:
```bash
node -e "
const g = JSON.parse(require('fs').readFileSync('grammar.json','utf-8'));
let eq;
try { eq = JSON.parse(require('fs').readFileSync('grammar-equivalences.json','utf-8')); } catch { eq = []; }
const existing = new Set(eq.flat());
const newTopics = Object.keys(g.topics).filter(id => !existing.has(id));
if (newTopics.length === 0) { console.log('ALL_UP_TO_DATE'); }
else { console.log(JSON.stringify({newTopics, existingGroups: eq, allTopics: Object.fromEntries(Object.entries(g.topics).map(([k,v]) => [k, {titleJp: v.titleJp, titleEn: v.titleEn}]))})); }
"
```

If the output is `ALL_UP_TO_DATE`, tell the user all grammar topics are already
in equivalence groups and stop.

## Step 2: Decide equivalences

For each new topic, consider whether it is equivalent to any topic already in
`grammar-equivalences.json` OR to any other new topic. Two topics are equivalent
if they teach the same grammatical concept (even if from different databases or
with slightly different scope).

Also consult the three grammar databases to find potential matches the user
hasn't annotated yet:
- `grammar/grammar-stolaf-genki.tsv` (Genki textbook topics)
- `grammar/grammar-bunpro.tsv` (Bunpro topics with Japanese + English titles)
- `grammar/grammar-dbjg.tsv` (Dictionary of Basic Japanese Grammar)

If a new topic matches an entry in another database that ISN'T in grammar.json,
note it for the user but do NOT add it to equivalences (only annotated topics
get grouped).

## Step 3: Apply equivalences

For each new topic:

- If it matches one or more existing topics, run:
  ```bash
  node .claude/scripts/add-grammar-equivalence.mjs <new-topic> <matching-topic1> [matching-topic2 ...]
  ```

- If it has no match (singleton), run:
  ```bash
  node .claude/scripts/add-grammar-equivalence.mjs <new-topic>
  ```

## Step 4: Report

Show the user a summary:
- Which topics were added as singletons
- Which topics were merged into existing groups
- Any cross-database matches found in the TSVs that the user might want to
  annotate in their Markdown files

Remind the user to review the diff of `grammar-equivalences.json` before committing.
