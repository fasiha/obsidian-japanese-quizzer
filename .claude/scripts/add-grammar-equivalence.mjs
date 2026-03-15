/**
 * add-grammar-equivalence.mjs
 *
 * Pure graph operation on grammar-equivalences.json.
 *
 * Usage:
 *   node .claude/scripts/add-grammar-equivalence.mjs bunpro:causative
 *     → adds as singleton (if not already present)
 *
 *   node .claude/scripts/add-grammar-equivalence.mjs bunpro:causative genki:causative dbjg:saseru
 *     → merges all three into one equivalence group
 *
 * Idempotent: if all given topics are already in the same group, no change.
 */

import { readFileSync, writeFileSync } from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(__dirname, "../..");
const EQUIV_PATH = path.join(projectRoot, "grammar-equivalences.json");

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

// Load existing equivalences (or start fresh)
let groups;
try {
  groups = JSON.parse(readFileSync(EQUIV_PATH, "utf-8"));
} catch {
  groups = [];
}

// Find which groups contain any of the given topics
const touchedIndices = new Set();
for (let i = 0; i < groups.length; i++) {
  for (const id of args) {
    if (groups[i].includes(id)) {
      touchedIndices.add(i);
    }
  }
}

// Merge: collect all members from touched groups + the new args
const merged = new Set(args);
for (const i of touchedIndices) {
  for (const id of groups[i]) {
    merged.add(id);
  }
}

// Rebuild: untouched groups + the merged group
const newGroups = groups.filter((_, i) => !touchedIndices.has(i));
newGroups.push([...merged].sort());

// Sort groups for stable output (by first element)
newGroups.sort((a, b) => a[0].localeCompare(b[0]));

writeFileSync(EQUIV_PATH, JSON.stringify(newGroups, null, 2) + "\n");

const action =
  touchedIndices.size === 0
    ? "Added singleton"
    : `Merged ${touchedIndices.size + (args.some((id) => !groups.flat().includes(id)) ? 0 : 0)} group(s)`;
console.log(`${action}: [${[...merged].sort().join(", ")}]`);
