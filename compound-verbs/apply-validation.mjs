/**
 * compound-verbs/apply-validation.mjs
 *
 * Pass 2c: Applies the advisory flags from a validation txt file (produced by
 * validate-assignments.mjs) to the canonical assignments.json. Human review
 * happens before running this script — delete any flag lines from the txt file
 * that you disagree with, then run this script to apply the rest.
 *
 * Usage:
 *   node compound-verbs/apply-validation.mjs <path-to-validation-txt>
 *
 * Example:
 *   node compound-verbs/apply-validation.mjs \
 *     compound-verbs/clusters/上がる-validation-2026-04-04_23-48-54-513-claude-sonnet-4-6.txt
 *
 * The suffix is read from the "suffix:" line in the flags header of the txt file.
 * The assignments file is derived as:
 *   compound-verbs/clusters/<v2>-assignments.json
 *
 * Each flag has "headword", "suggested" (complete desired meaning list), and
 * "reason". The effect on assignments.json is always the same: remove the
 * compound from all current meaning keys, then add it to all "suggested" meanings.
 * suggested: [] means the compound becomes lexicalized (removed from all keys).
 */

import { readFileSync, writeFileSync, existsSync } from "fs";
import { join, dirname, resolve } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));

// --- Argument parsing ---

const args = process.argv.slice(2);
const txtPathArg = args[0];

if (!txtPathArg || txtPathArg.startsWith("--")) {
  console.error(
    "Usage: node compound-verbs/apply-validation.mjs <path-to-validation-txt>",
  );
  process.exit(1);
}

const txtPath = resolve(process.cwd(), txtPathArg);
if (!existsSync(txtPath)) {
  console.error(`Validation txt file not found: ${txtPath}`);
  process.exit(1);
}

// --- Parse the txt file ---

const txtContent = readFileSync(txtPath, "utf8");

// Extract the suffix from the flags header
const suffixMatch = txtContent.match(/^suffix:\s*(.+)$/m);
if (!suffixMatch) {
  console.error(
    `Could not find "suffix:" line in flags header of: ${txtPath}`,
  );
  process.exit(1);
}
const v2 = suffixMatch[1].trim();

// Extract the JSON blob from the response section.
// The model reasons before the JSON so we want the last top-level { block.
const responseSection = txtContent.split("========== RESPONSE ==========")[1];
if (!responseSection) {
  console.error(`Could not find "========== RESPONSE ==========" section in: ${txtPath}`);
  process.exit(1);
}

let parsedFlags;
try {
  const allObjectLineMatches = [...responseSection.matchAll(/^\{/gm)];
  const lastObjectStart = allObjectLineMatches.at(-1);
  const jsonText = lastObjectStart
    ? responseSection
        .slice(lastObjectStart.index)
        .replace(/\n?```\s*$/, "")
        .trim()
    : responseSection
        .replace(/^```(?:json)?\n?/i, "")
        .replace(/\n?```\s*$/, "")
        .trim();
  parsedFlags = JSON.parse(jsonText);
} catch (err) {
  console.error(`Could not parse JSON from response section of: ${txtPath}`);
  console.error(err.message);
  process.exit(1);
}

if (
  typeof parsedFlags !== "object" ||
  parsedFlags === null ||
  !Array.isArray(parsedFlags.flags)
) {
  console.error(
    `Response section did not contain a {"flags": [...]} object in: ${txtPath}`,
  );
  process.exit(1);
}

const flags = parsedFlags.flags;
console.log(`Parsed ${flags.length} flag(s) from: ${txtPath}`);

if (flags.length === 0) {
  console.log("No flags to apply — assignments.json unchanged.");
  process.exit(0);
}

// --- Load assignments.json ---

const assignmentsPath = join(__dirname, "clusters", `${v2}-assignments.json`);
if (!existsSync(assignmentsPath)) {
  console.error(`Assignments file not found: ${assignmentsPath}`);
  console.error(`Run: node compound-verbs/assign-examples.mjs ${v2}`);
  process.exit(1);
}

const assignments = JSON.parse(readFileSync(assignmentsPath, "utf8"));

if (
  typeof assignments !== "object" ||
  Array.isArray(assignments) ||
  assignments === null ||
  !assignments._metadata
) {
  console.error(`Assignments file is malformed (missing _metadata): ${assignmentsPath}`);
  process.exit(1);
}

// Collect the meaning keys (everything except _metadata)
const meaningKeys = Object.keys(assignments).filter((k) => k !== "_metadata");
const knownMeanings = new Set(meaningKeys);

// --- Apply each flag ---

let appliedCount = 0;
let skippedCount = 0;

for (const flag of flags) {
  const { headword, suggested } = flag;

  if (typeof headword !== "string" || !headword) {
    console.warn(`WARNING: Flag missing valid "headword" — skipping: ${JSON.stringify(flag)}`);
    skippedCount++;
    continue;
  }

  if (!Array.isArray(suggested)) {
    console.warn(`WARNING: "suggested" is not an array for "${headword}" — skipping`);
    skippedCount++;
    continue;
  }

  // Validate that all suggested meanings exist in the assignments file
  const unknownSuggested = suggested.filter((s) => !knownMeanings.has(s));
  if (unknownSuggested.length > 0) {
    console.warn(
      `WARNING: "${headword}" has unrecognized suggested meaning(s): ${unknownSuggested.map((s) => `"${s}"`).join(", ")} — skipping`,
    );
    skippedCount++;
    continue;
  }

  // Remove from all current meaning keys, then add to the suggested set.
  // suggested is the complete desired set, so this handles all cases uniformly.
  for (const key of meaningKeys) {
    const arr = assignments[key];
    if (Array.isArray(arr)) {
      const idx = arr.indexOf(headword);
      if (idx !== -1) arr.splice(idx, 1);
    }
  }

  for (const meaning of suggested) {
    if (!Array.isArray(assignments[meaning])) {
      assignments[meaning] = [];
    }
    if (!assignments[meaning].includes(headword)) {
      assignments[meaning].push(headword);
    }
  }

  if (suggested.length === 0) {
    console.log(`  ${headword}: removed from all meanings (lexicalized)`);
  } else {
    console.log(`  ${headword}: → [${suggested.map((s) => `"${s.slice(0, 40)}…"`).join(", ")}]`);
  }

  appliedCount++;
}

console.log(`\nApplied ${appliedCount} flag(s), skipped ${skippedCount}.`);

if (appliedCount === 0) {
  console.log("No changes made — assignments.json unchanged.");
  process.exit(0);
}

// --- Stamp _metadata with the validation file that was applied ---

const { basename } = await import("path");
if (!Array.isArray(assignments._metadata.validations_applied)) {
  assignments._metadata.validations_applied = [];
}
assignments._metadata.validations_applied.push({
  file: basename(txtPath),
  applied_at: new Date().toISOString(),
});

// --- Write updated assignments.json ---

writeFileSync(assignmentsPath, JSON.stringify(assignments, null, 2), "utf8");
console.log(`\nUpdated: ${assignmentsPath}`);
