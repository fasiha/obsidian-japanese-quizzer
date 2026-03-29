/**
 * add-grammar-equivalence.mjs
 *
 * Pure graph operation on grammar/grammar-equivalences.json.
 *
 * Usage:
 *   node .claude/scripts/add-grammar-equivalence.mjs bunpro:causative
 *     → adds as singleton (if not already present)
 *
 *   node .claude/scripts/add-grammar-equivalence.mjs bunpro:causative genki:causative dbjg:saseru
 *     → merges all three into one equivalence group
 *
 * Idempotent: if all given topics are already in the same group, no change.
 *
 * Format: grammar/grammar-equivalences.json is an array of EquivalenceGroup objects.
 * Old format (array-of-arrays) is read and auto-migrated on load.
 *
 * @typedef {Object} EquivalenceGroup
 * @property {string[]} topics
 *   Prefixed topic IDs in this equivalence group, e.g. ["bunpro:causative", "genki:causative-sentences"].
 *   Always sorted alphabetically. At least one element.
 *
 * @property {string} [summary]
 *   2–3 sentence gloss: what the form looks like (conjugation pattern) and what it means.
 *   Written in plain English, no copyrighted examples. Injected into Haiku's system prompt.
 *
 * @property {string[]} [subUses]
 *   Distinct grammatical sub-uses of this topic, each with a short original example sentence.
 *   Example: ["Sequential actions: 歩いて帰った (walked home on foot)",
 *             "Means/manner: 急いでご飯を食べた (ate in a hurry)"]
 *   Haiku uses this list to vary which sub-use each quiz question exercises.
 *   Recent sub-uses from reviews.notes are fed back so the same sub-use isn't repeated.
 *
 * @property {string[]} [cautions]
 *   Edge cases and confusables Haiku must know about.
 *   Example: ["ら抜き言葉: 食べれる/見れる are colloquially accepted — do not use as distractors or penalize in grading",
 *             "Do not confuse with potential: ことができる is also correct but is a separate grammar point"]
 *
 * @property {boolean} [stub]
 *   True if the description was generated without any user content sentences (based on web
 *   pages and Claude's internal knowledge only). Omitted or false once real content sentences
 *   have been incorporated. Shown as a warning in the TestHarness.
 */

import { readFileSync, writeFileSync } from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { migrateEquivalences, loadGrammarDatabases } from "./shared.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(__dirname, "../..");
const EQUIV_PATH = path.join(projectRoot, "grammar", "grammar-equivalences.json");

const args = process.argv.slice(2);
if (args.length === 0) {
  console.error(
    "Usage: node add-grammar-equivalence.mjs <topic-id> [topic-id ...]",
  );
  console.error("  1 arg  → add as singleton");
  console.error("  2+ args → merge into one equivalence group");
  process.exit(1);
}

// Validate prefixes
const VALID_PREFIXES = ["genki:", "bunpro:", "dbjg:"];
for (const id of args) {
  if (!VALID_PREFIXES.some((p) => id.startsWith(p))) {
    console.error(
      `Error: "${id}" must start with one of: ${VALID_PREFIXES.join(", ")}`,
    );
    process.exit(1);
  }
}

// Resolve DBJG aliases to their canonical entry
const dbMap = loadGrammarDatabases();
const resolvedArgs = [...new Set(args.map((id) => {
  const entry = dbMap.get(id);
  if (entry?.aliasOf) {
    const canonical = entry.aliasOf[0];
    process.stderr.write(`[warn] ${id} is an alias for ${canonical} — using canonical\n`);
    return canonical;
  }
  return id;
}))];

// Load existing equivalences (or start fresh), migrating old array-of-arrays format
function loadEquivalences(filePath) {
  let raw;
  try {
    raw = JSON.parse(readFileSync(filePath, "utf-8"));
  } catch {
    return [];
  }
  return migrateEquivalences(raw);
}

const groups = loadEquivalences(EQUIV_PATH);

// Find which groups contain any of the given topics
const touchedIndices = new Set();
for (let i = 0; i < groups.length; i++) {
  for (const id of resolvedArgs) {
    if (groups[i].topics.includes(id)) {
      touchedIndices.add(i);
    }
  }
}

// Merge: collect all topic members from touched groups + the new args
const mergedTopics = new Set(resolvedArgs);
// Preserve non-topics fields from the first touched group (description data etc.)
let preservedMeta = {};
for (const i of touchedIndices) {
  for (const id of groups[i].topics) {
    mergedTopics.add(id);
  }
  if (Object.keys(preservedMeta).length === 0) {
    const { topics: _, ...rest } = groups[i];
    preservedMeta = rest;
  }
}

// Rebuild: untouched groups + the merged group
const newGroups = groups.filter((_, i) => !touchedIndices.has(i));
newGroups.push({ topics: [...mergedTopics].sort(), ...preservedMeta });

// Sort groups for stable output (by first topic)
newGroups.sort((a, b) => a.topics[0].localeCompare(b.topics[0]));

writeFileSync(EQUIV_PATH, JSON.stringify(newGroups, null, 2) + "\n");

const action =
  touchedIndices.size === 0
    ? "Added singleton"
    : `Merged ${touchedIndices.size} group(s)`;
console.log(`${action}: [${[...mergedTopics].sort().join(", ")}]`);
