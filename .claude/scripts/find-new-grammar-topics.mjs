/**
 * find-new-grammar-topics.mjs
 *
 * Reports grammar topics from grammar.json that are not yet covered by any
 * equivalence group in grammar/grammar-equivalences.json.
 *
 * Usage:
 *   node find-new-grammar-topics.mjs
 *
 * Output (stdout):
 *   If all topics are already grouped: prints the string ALL_UP_TO_DATE
 *   Otherwise: prints JSON { newTopics, existingGroups, allTopics }
 *     - newTopics:     string[]  — prefixed topic IDs not yet in any group
 *     - existingGroups: EquivalenceGroup[] — current contents of grammar/grammar-equivalences.json
 *     - allTopics:     Record<string, { titleJp, titleEn }> — all topics from grammar.json
 */

import { readFileSync } from "fs";
import path from "path";
import { projectRoot, migrateEquivalences, loadGrammarDatabases } from "./shared.mjs";

const grammarPath = path.join(projectRoot, "grammar.json");
const equivPath = path.join(projectRoot, "grammar", "grammar-equivalences.json");

// Load grammar.json
let grammar;
try {
  grammar = JSON.parse(readFileSync(grammarPath, "utf-8"));
} catch (e) {
  process.stderr.write(`Could not read grammar.json: ${e.message}\n`);
  process.exit(1);
}

// Load grammar/grammar-equivalences.json (tolerate missing file)
let existingGroups;
try {
  existingGroups = migrateEquivalences(
    JSON.parse(readFileSync(equivPath, "utf-8")),
  );
} catch {
  existingGroups = [];
}

// Build set of all topic IDs already covered by some equivalence group
const covered = new Set(existingGroups.flatMap((g) => g.topics));

// Build set of alias topic IDs across all grammar databases
const aliasIds = new Set(
  [...loadGrammarDatabases().values()]
    .filter((e) => e.aliasOf)
    .map((e) => e.prefixedId),
);

// Find topics in grammar.json not yet covered and not aliases
const newTopics = Object.keys(grammar.topics).filter(
  (id) => !covered.has(id) && !aliasIds.has(id),
);

if (newTopics.length === 0) {
  process.stdout.write("ALL_UP_TO_DATE\n");
} else {
  const allTopics = Object.fromEntries(
    Object.entries(grammar.topics).map(([id, v]) => [
      id,
      { titleJp: v.titleJp ?? "", titleEn: v.titleEn ?? "" },
    ]),
  );
  process.stdout.write(
    JSON.stringify({ newTopics, existingGroups, allTopics }, null, 2) + "\n",
  );
}
