/**
 * compound-verbs/analyze-assignments.mjs
 *
 * Quick analysis: for a given v2 suffix, show how many meanings each compound
 * was assigned to (0, 1, 2, 3…) based on the canonical assignments.json.
 * The list of compounds that were sent to the LLM is read from the
 * _metadata.compounds_sent field in the assignments file, so this script has
 * no dependency on the survey file or BCCWJ database.
 *
 * Usage:
 *   node compound-verbs/analyze-assignments.mjs 返す
 */

import { readFileSync, existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const v2 = process.argv[2];
if (!v2) {
  console.error("Usage: node compound-verbs/analyze-assignments.mjs <v2>");
  process.exit(1);
}

const assignmentsPath = join(__dirname, "clusters", `${v2}-assignments.json`);
if (!existsSync(assignmentsPath)) {
  console.error(`Assignments file not found: ${assignmentsPath}`);
  console.error(`Run: node compound-verbs/assign-examples.mjs ${v2}`);
  process.exit(1);
}

const data = JSON.parse(readFileSync(assignmentsPath, "utf8"));
const { _metadata, ...assignments } = data;

if (!_metadata?.compounds_sent) {
  console.error("assignments.json is missing _metadata.compounds_sent — re-run assign-examples.mjs to regenerate it");
  process.exit(1);
}

const sent = _metadata.compounds_sent;
const meanings = Object.keys(assignments);

// Count how many meanings each sent compound was assigned to
const meaningCount = new Map(sent.map((hw) => [hw, 0]));
for (const headwords of Object.values(assignments)) {
  for (const headword of headwords) {
    if (meaningCount.has(headword)) {
      meaningCount.set(headword, meaningCount.get(headword) + 1);
    }
  }
}

// Build histogram: count → [headwords]
const histogram = new Map();
for (const [headword, count] of meaningCount) {
  if (!histogram.has(count)) histogram.set(count, []);
  histogram.get(count).push(headword);
}

console.log(`\n-${v2}: ${sent.length} compounds sent to LLM, ${meanings.length} meanings`);
console.log(`Meanings:`);
for (const meaning of meanings) {
  console.log(`  "${meaning}" → ${assignments[meaning].length} compounds`);
}

console.log(`\nHistogram (# of meanings assigned):`);
for (const count of [...histogram.keys()].sort((a, b) => a - b)) {
  const headwords = histogram.get(count);
  const label = count === 0 ? "0 (lexicalized / unassigned)" : `${count}`;
  console.log(`  ${label}: ${headwords.length} compound(s)`);
  for (const hw of headwords) {
    console.log(`    ${hw}`);
  }
}
