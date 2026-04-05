/**
 * compound-verbs/status.mjs
 *
 * Shows pipeline status for one or more v2 suffixes. For each suffix, reports
 * which passes have been completed and what comes next.
 *
 * Usage:
 *   node compound-verbs/status.mjs              # all suffixes with any cluster file
 *   node compound-verbs/status.mjs 上がる 出す  # specific suffixes
 */

import { readFileSync, existsSync, readdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const clustersDir = join(__dirname, "clusters");
const surveyDir = join(__dirname, "survey");
const root = join(__dirname, "..");

// --- Determine which suffixes to check ---

const args = process.argv.slice(2).filter((a) => !a.startsWith("--"));

let suffixes;
if (args.length > 0) {
  suffixes = args;
} else {
  // Discover all suffixes that have any canonical cluster file
  const canonicalPattern = /^(.+)-(?:meanings|assignments)\.json$/;
  const seen = new Set();
  for (const f of readdirSync(clustersDir)) {
    const m = f.match(canonicalPattern);
    if (m) seen.add(m[1]);
  }
  suffixes = [...seen].sort();
}

if (suffixes.length === 0) {
  console.log("No suffixes found. Run survey.mjs and cluster-meanings.mjs first.");
  process.exit(0);
}

// --- Check compound-verbs.json for finished entries ---

const cvPath = join(__dirname, "compound-verbs.json");
const finishedSuffixes = new Set();
if (existsSync(cvPath)) {
  try {
    const cv = JSON.parse(readFileSync(cvPath, "utf8"));
    for (const entry of cv) {
      if (entry.kanji) finishedSuffixes.add(entry.kanji);
    }
  } catch {}
}

// --- Per-suffix status check ---

const STEPS = [
  "survey",
  "meanings",
  "meanings-sharpened",
  "assignments",
  "validation-txt",
  "validation-applied",
  "written",
];

function checkSuffix(v2) {
  const survey = existsSync(join(surveyDir, `${v2}.json`));
  const meanings = existsSync(join(clustersDir, `${v2}-meanings.json`));
  const sharpened = existsSync(join(clustersDir, `${v2}-meanings-sharpened.json`));

  const assignmentsPath = join(clustersDir, `${v2}-assignments.json`);
  const hasAssignments = existsSync(assignmentsPath);

  let assignmentsMeta = null;
  if (hasAssignments) {
    try {
      assignmentsMeta = JSON.parse(readFileSync(assignmentsPath, "utf8"))._metadata;
    } catch {}
  }

  // Find validation txt archives for this suffix
  const validationTxts = readdirSync(clustersDir)
    .filter((f) => f.startsWith(`${v2}-validation-`) && f.endsWith(".txt"))
    .sort();
  const hasValidationTxt = validationTxts.length > 0;

  // Check if any validation has been applied (stamped in _metadata)
  const validationsApplied = assignmentsMeta?.validations_applied ?? [];
  const hasValidationApplied = validationsApplied.length > 0;

  // Check if all validation txt files have been applied
  const appliedFiles = new Set(validationsApplied.map((v) => v.file));
  const unappliedTxts = validationTxts.filter((f) => !appliedFiles.has(f));

  const written = finishedSuffixes.has(v2);

  return {
    survey,
    meanings,
    sharpened,
    hasAssignments,
    assignmentsMeta,
    validationTxts,
    hasValidationTxt,
    hasValidationApplied,
    validationsApplied,
    unappliedTxts,
    written,
  };
}

function nextStep(s, v2) {
  if (!s.survey) return `Pass 0: node survey.mjs ${v2}`;
  if (!s.meanings) return `Pass 1: node cluster-meanings.mjs ${v2}`;
  if (!s.sharpened) return `Pass 1b: node sharpen-meanings.mjs ${v2}`;
  if (!s.hasAssignments) return `Pass 2: node assign-examples.mjs ${v2}`;
  if (!s.hasValidationTxt) return `Pass 2b: node validate-assignments.mjs ${v2}`;
  if (s.unappliedTxts.length > 0) return `Pass 2c: node apply-validation.mjs clusters/${s.unappliedTxts[0]}`;
  if (!s.written) return `Pass 3: node select-examples.mjs ${v2}`;
  return null;
}

// --- Print ---

const colWidth = Math.max(...suffixes.map((s) => s.length), 4) + 2;

for (const v2 of suffixes) {
  const s = checkSuffix(v2);

  const checks = [
    s.survey          ? "✓ survey"      : "· survey",
    s.meanings        ? "✓ meanings"    : "· meanings",
    s.sharpened       ? "✓ sharpened"   : "· sharpened",
    s.hasAssignments  ? "✓ assignments" : "· assignments",
    s.hasValidationTxt
      ? `✓ validation (${s.validationTxts.length} run${s.validationTxts.length !== 1 ? "s" : ""})`
      : "· validation",
    s.hasValidationApplied
      ? `✓ applied (${s.validationsApplied.length}/${s.validationTxts.length})`
      : "· applied",
    s.written         ? "✓ written"     : "· written",
  ];

  const label = v2.padEnd(colWidth);
  const next = nextStep(s, v2);

  console.log(`${label} ${checks.join("  ")}`);
  if (s.unappliedTxts.length > 0 && s.hasValidationApplied) {
    // Some applied, some not
    console.log(`${" ".repeat(colWidth)}   unapplied: ${s.unappliedTxts.join(", ")}`);
  }
  if (next) {
    console.log(`${" ".repeat(colWidth)}   → ${next}`);
  }
}
