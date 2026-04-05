/**
 * compound-verbs/status.mjs
 *
 * Shows pipeline status for one or more v2 suffixes. For each suffix, reports
 * which passes have been completed and what comes next.
 *
 * Usage:
 *   node compound-verbs/status.mjs              # all suffixes with any cluster file
 *   node compound-verbs/status.mjs 上がる 出す  # specific suffixes
 *   node compound-verbs/status.mjs --word 飛び出す  # trace one compound verb end-to-end
 */

import { readFileSync, existsSync, readdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const clustersDir = join(__dirname, "clusters");
const surveyDir = join(__dirname, "survey");

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

function suffixChecks(s) {
  return [
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
}

// --- Argument parsing ---

const rawArgs = process.argv.slice(2);
const wordFlagIndex = rawArgs.indexOf("--word");
const wordArg = wordFlagIndex !== -1 ? rawArgs[wordFlagIndex + 1] : null;
const args = rawArgs.filter((a, i) => a !== "--word" && i !== wordFlagIndex + 1 && !a.startsWith("--"));

// --- --word mode: trace a single compound verb through the pipeline ---

if (wordArg) {
  const headwordsPath = join(__dirname, "headwords.json");
  const headwords = JSON.parse(readFileSync(headwordsPath, "utf8"));
  const hwEntry = headwords.find((h) => h.headword1 === wordArg || h.headword2 === wordArg);

  if (!hwEntry) {
    console.log(`"${wordArg}" not found in headwords.json`);
    process.exit(1);
  }

  const v2 = hwEntry.v2;
  console.log(`Word: ${wordArg}  (v2 suffix: ${v2})\n`);

  // Show overall suffix pipeline status
  const s = checkSuffix(v2);
  console.log(`Suffix ${v2}: ${suffixChecks(s).join("  ")}`);
  const next = nextStep(s, v2);
  if (next) console.log(`  → ${next}`);
  console.log();

  // Check assignments: which sense cluster is this word in?
  if (s.hasAssignments) {
    const assignmentsPath = join(clustersDir, `${v2}-assignments.json`);
    const assignments = JSON.parse(readFileSync(assignmentsPath, "utf8"));
    let assignedSense = null;
    for (const [sense, words] of Object.entries(assignments)) {
      if (sense.startsWith("_")) continue;
      if (words.includes(wordArg)) { assignedSense = sense; break; }
    }
    if (assignedSense) {
      console.log(`Assigned sense cluster:\n  "${assignedSense}"`);
    } else {
      console.log(`Not found in ${v2}-assignments.json`);
    }
    console.log();
  }

  // Check compound-verbs.json: find which sense(s) include this word's JMDict ID
  if (s.written) {
    const surveyPath = join(surveyDir, `${v2}.json`);
    let jmdictId = null;
    if (existsSync(surveyPath)) {
      const survey = JSON.parse(readFileSync(surveyPath, "utf8"));
      const surveyEntry = Object.values(survey).find((e) => e.headword === wordArg);
      jmdictId = surveyEntry?.jmdictId ? Number(surveyEntry.jmdictId) : null;
    }

    const cv = JSON.parse(readFileSync(cvPath, "utf8"));
    const suffixEntry = cv.find((e) => e.kanji === v2);
    if (suffixEntry && jmdictId !== null) {
      const matchingSenses = suffixEntry.senses.filter((sense) =>
        sense.examples.includes(jmdictId)
      );
      if (matchingSenses.length > 0) {
        console.log(`Found in compound-verbs.json under ${v2} sense${matchingSenses.length > 1 ? "s" : ""}:`);
        for (const sense of matchingSenses) {
          console.log(`  "${sense.meaning}"`);
        }
      } else {
        console.log(`${v2} is written to compound-verbs.json, but ${wordArg} (JMDict ID ${jmdictId}) is not among its selected examples.`);
      }
    } else if (jmdictId === null) {
      console.log(`Could not find JMDict ID for ${wordArg} in survey file — cannot check compound-verbs.json examples.`);
    }
  }

  process.exit(0);
}

// --- Suffix list mode ---

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

// --- Print ---

const colWidth = Math.max(...suffixes.map((s) => s.length), 4) + 2;

for (const v2 of suffixes) {
  const s = checkSuffix(v2);
  const label = v2.padEnd(colWidth);
  const next = nextStep(s, v2);

  console.log(`${label} ${suffixChecks(s).join("  ")}`);
  if (s.unappliedTxts.length > 0 && s.hasValidationApplied) {
    // Some applied, some not
    console.log(`${" ".repeat(colWidth)}   unapplied: ${s.unappliedTxts.join(", ")}`);
  }
  if (next) {
    console.log(`${" ".repeat(colWidth)}   → ${next}`);
  }
}
