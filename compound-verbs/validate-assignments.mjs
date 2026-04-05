/**
 * compound-verbs/validate-assignments.mjs
 *
 * LLM Pass 2b (Validation): Given the assignments produced by assign-examples.mjs
 * (Pass 2), asks the LLM to flag suspicious placements before anything is written
 * to compound-verbs.json. This is an advisory pass — it never modifies
 * assignments.json.
 *
 * Usage:
 *   node compound-verbs/validate-assignments.mjs 出す
 *   node compound-verbs/validate-assignments.mjs 出す --dry-run
 *   node compound-verbs/validate-assignments.mjs 出す --model claude-opus-4-6
 *
 * Automatically uses <v2>-meanings-sharpened.json if it exists (logged with a
 * bright notice), otherwise falls back to <v2>-meanings.json.
 *
 * Input:
 *   compound-verbs/clusters/<v2>-assignments.json   (from assign-examples.mjs)
 *   compound-verbs/clusters/<v2>-meanings-sharpened.json (preferred, from sharpen-meanings.mjs)
 *     or <v2>-meanings.json if the sharpened file is absent (from cluster-meanings.mjs)
 *
 * Output:
 *   compound-verbs/clusters/<v2>-validation-<timestamp>-<model>.txt
 *     (flags + prompt + raw LLM response, one file per run)
 *   Flags printed to stdout — no canonical JSON is written by this script.
 *
 * Requires ANTHROPIC_API_KEY in .env
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import Anthropic from "@anthropic-ai/sdk";
import chalk from "chalk";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, "..");

// Load .env
try {
  const envFile = readFileSync(join(root, ".env"), "utf8");
  for (const line of envFile.split("\n")) {
    const match = line.match(/^\s*([^#=]+?)\s*=\s*(.*?)\s*$/);
    if (match && !process.env[match[1]]) process.env[match[1]] = match[2];
  }
} catch {}

// --- Argument parsing ---

const args = process.argv.slice(2);
const v2 = args.find((a) => !a.startsWith("--"));
const dryRun = args.includes("--dry-run");
const modelFlagIndex = args.indexOf("--model");
const model =
  modelFlagIndex >= 0 ? args[modelFlagIndex + 1] : "claude-sonnet-4-6";
const reparseJsonIndex = args.indexOf("--reparse-json");
const reparseJsonPath =
  reparseJsonIndex >= 0 ? args[reparseJsonIndex + 1] : null;

if (!v2) {
  console.error(
    "Usage: node compound-verbs/validate-assignments.mjs <v2> [--dry-run] [--model MODEL]",
  );
  process.exit(1);
}

// --- Load assignments file ---

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
  console.error(
    `Assignments file is malformed (missing _metadata): ${assignmentsPath}`,
  );
  process.exit(1);
}

const { compounds_sent: compoundsSent } = assignments._metadata;

if (!Array.isArray(compoundsSent) || compoundsSent.length === 0) {
  console.error(
    `assignments._metadata.compounds_sent is missing or empty: ${assignmentsPath}`,
  );
  process.exit(1);
}

// --- Load meanings file ---

const sharpenedMeaningsPath = join(
  __dirname,
  "clusters",
  `${v2}-meanings-sharpened.json`,
);
const defaultMeaningsPath = join(__dirname, "clusters", `${v2}-meanings.json`);

let meaningsPath;
if (existsSync(sharpenedMeaningsPath)) {
  meaningsPath = sharpenedMeaningsPath;
} else {
  meaningsPath = defaultMeaningsPath;
  if (!existsSync(meaningsPath)) {
    console.error(`Meanings file not found: ${meaningsPath}`);
    console.error(`Run: node compound-verbs/cluster-meanings.mjs ${v2}`);
    process.exit(1);
  }
  console.log(chalk.redBright(`No sharpened meanings found — using original: ${meaningsPath}`));
  console.log(chalk.redBright(`Run sharpen-meanings.mjs ${v2} to improve validation quality.`));
}

const useSharpened = meaningsPath === sharpenedMeaningsPath;
const meanings = JSON.parse(readFileSync(meaningsPath, "utf8"));

if (!Array.isArray(meanings) || meanings.length === 0) {
  console.error(`Meanings file is empty or malformed: ${meaningsPath}`);
  process.exit(1);
}

// --- Compute assigned and lexicalized sets ---

const knownMeanings = new Set(meanings.map((m) => m.meaning));

// Collect all headwords that appear in at least one meaning's array
const assignedHeadwords = new Set();
const meaningAssignments = {}; // meaning string → array of headwords

for (const [key, value] of Object.entries(assignments)) {
  if (key === "_metadata") continue;
  if (!knownMeanings.has(key)) {
    console.warn(
      `WARNING: assignments.json contains unknown meaning key "${key}" — ignoring`,
    );
    continue;
  }
  if (!Array.isArray(value)) {
    console.warn(
      `WARNING: Value for meaning "${key}" in assignments.json is not an array — ignoring`,
    );
    continue;
  }
  meaningAssignments[key] = value;
  for (const hw of value) {
    assignedHeadwords.add(hw);
  }
}

// Lexicalized = sent to LLM but not assigned to any meaning
const lexicalizedCompounds = compoundsSent.filter(
  (hw) => !assignedHeadwords.has(hw),
);

console.log(
  `${v2}: ${compoundsSent.length} compounds in assignments, ${Object.keys(meaningAssignments).length} meaning(s)`,
);
console.log(
  `  Assigned: ${assignedHeadwords.size} compounds across all meanings`,
);
console.log(
  `  Lexicalized/unassigned: ${lexicalizedCompounds.length} compounds`,
);
console.log(
  `Using meanings: ${useSharpened ? "sharpened" : "original"} (${meaningsPath})`,
);

if (assignedHeadwords.size === 0 && compoundsSent.length > 0) {
  console.error(
    `\nERROR: No compounds matched any meaning. Check that the meanings file matches the one used during assign-examples.mjs.`,
  );
  process.exit(1);
}

// --- Build prompt ---

const meaningsBlock = meanings
  .map((m, i) => `  ${i + 1}. "${m.meaning}"`)
  .join("\n");

const assignmentsBlock = Object.entries(meaningAssignments)
  .map(([meaning, headwords]) => {
    const list = headwords.length > 0 ? headwords.join("、") : "(none)";
    return `  "${meaning}":\n    ${list}`;
  })
  .join("\n\n");

const lexicalizedBlock =
  lexicalizedCompounds.length > 0 ? lexicalizedCompounds.join("、") : "(none)";

const prompt = `You are helping prepare data for an app to teach Japanese to English speakers. You will validate the automated assignment of -${v2} compound verbs to meaning categories.

The suffix -${v2} has these distinct meanings when appended to a prefix verb:
${meaningsBlock}

Below are the current assignments of compounds to meanings, followed by compounds that were not assigned to any meaning (the "lexicalized" or opaque set whose meaning cannot be derived from the parts).

=== CURRENT ASSIGNMENTS ===
${assignmentsBlock}

=== LEXICALIZED / UNASSIGNED ===
${lexicalizedBlock}

Your task: carefully review these assignments and flag any that look wrong. Look for:

1. A compound is listed under a meaning but -${v2} does not contribute that meaning in it; it belongs somewhere else.
2. A compound is in the lexicalized bucket, but -${v2}'s role in it is actually transparent and it should be assigned to one of the meanings above.
3. A compound is assigned to one meaning but clearly fits a second meaning equally well and is missing from it.

Do not flag trivial or borderline cases. Only flag clear errors.

Reason through the assignments, then output a JSON object with a single key "flags" whose value is an array of flag objects. If you find no issues, return {"flags": []}.

Each flag object has these fields:
  "headword": the compound in kanji
  "suggested": the complete list of meanings the compound should be assigned to (including any it is already correctly assigned to). Use [] to indicate the compound should be lexicalized/unassigned.
  "reason": short explanation

The meaning strings in "suggested" must be verbatim from the numbered list above. Use an empty array [] to indicate the compound should be lexicalized.

Example output shape:
{
  "flags": [
    {
      "headword": "取り出す",
      "suggested": ["to <verb> something out; remove or extract it from where it was"],
      "reason": "取り出す means to take something out; -出す here marks extraction, not beginning."
    }
  ]
}`;

// --- Dry run: print prompt and exit ---

if (dryRun) {
  console.log("\n========== [DRY RUN] Prompt ==========\n");
  console.log(prompt);
  console.log("\n========== End of prompt ==========\n");
  console.log(`Would send to ${model}`);
  process.exit(0);
}

// --- Call LLM (or reparse from saved JSON) ---

let responseText;

if (reparseJsonPath) {
  console.log(`Reparsing from saved JSON: ${reparseJsonPath}`);
  const savedJson = readFileSync(reparseJsonPath, "utf8");
  // Wrap in a fake response so the archive-writing + JSON-parsing logic below works unchanged
  responseText = savedJson.trim();
} else {
  console.log(`Calling ${model}...`);
  const client = new Anthropic();
  const message = await client.messages.create({
    model,
    max_tokens: 16000,
    messages: [{ role: "user", content: prompt }],
  });
  responseText = message.content[0].text.trim();
}

// --- Write archive .txt ---

const clustersDir = join(__dirname, "clusters");
mkdirSync(clustersDir, { recursive: true });

const isoString = new Date().toISOString();
const timestamp = isoString
  .replace(/[:.]/g, "-")
  .replace("T", "_")
  .replace("Z", "");
const archiveTxtPath = join(
  clustersDir,
  `${v2}-validation-${timestamp}-${model}.txt`,
);

const flagsSummary = [
  `suffix: ${v2}`,
  `model: ${model}`,
  `compounds-reviewed: ${compoundsSent.length}`,
  `meanings-count: ${meanings.length}`,
  `lexicalized-count: ${lexicalizedCompounds.length}`,
  `use-sharpened: ${useSharpened}`,
  `timestamp: ${isoString}`,
  `args: node compound-verbs/validate-assignments.mjs ${args.join(" ")}`,
].join("\n");

writeFileSync(
  archiveTxtPath,
  [
    "========== FLAGS ==========",
    flagsSummary,
    "",
    "========== PROMPT ==========",
    prompt,
    "",
    "========== RESPONSE ==========",
    responseText,
  ].join("\n"),
  "utf8",
);

console.log(`\nArchive written to: ${archiveTxtPath}`);

// --- Parse JSON object from response ---
// The model reasons before the JSON, so extract the first {...} block
// that starts at the beginning of a line (the outermost object).

let parsed;
try {
  const allObjectLineMatches = [...responseText.matchAll(/^\s*\{/gm)];
  const firstObjectStart = allObjectLineMatches[0];
  const jsonText = firstObjectStart
    ? responseText
        .slice(firstObjectStart.index)
        .replace(/\n?```\s*$/, "")
        .trim()
    : responseText
        .replace(/^```(?:json)?\n?/i, "")
        .replace(/\n?```\s*$/, "")
        .trim();
  parsed = JSON.parse(jsonText);
} catch (err) {
  console.error("ERROR: Could not parse LLM response as JSON.");
  console.error(`Raw response saved to: ${archiveTxtPath}`);
  process.exit(1);
}

if (
  typeof parsed !== "object" ||
  Array.isArray(parsed) ||
  parsed === null ||
  !Array.isArray(parsed.flags)
) {
  console.error(
    'ERROR: LLM response did not contain a top-level {"flags": [...]} object.',
  );
  console.error(`Raw response saved to: ${archiveTxtPath}`);
  process.exit(1);
}

// --- Validate each flag ---
// suggested values must be known meaning strings; empty array means lexicalized

const validValues = new Set(knownMeanings);

const validFlags = [];

for (const flag of parsed.flags) {
  if (typeof flag !== "object" || flag === null) {
    console.warn(`WARNING: Non-object entry in flags array — skipping`);
    continue;
  }

  const { headword, suggested, reason } = flag;

  if (typeof headword !== "string" || !headword) {
    console.warn(
      `WARNING: Flag missing valid "headword" field — skipping: ${JSON.stringify(flag)}`,
    );
    continue;
  }

  if (!Array.isArray(suggested)) {
    console.warn(
      `WARNING: Flag for "${headword}" has non-array "suggested" field — skipping`,
    );
    continue;
  }

  const validSuggested = [];
  let suggestedOk = true;
  for (const s of suggested) {
    if (!validValues.has(s)) {
      console.warn(
        `WARNING: Flag for "${headword}" has unrecognized "suggested" value "${s}" — skipping entire flag`,
      );
      suggestedOk = false;
      break;
    }
    validSuggested.push(s);
  }
  if (!suggestedOk) continue;

  validFlags.push({ headword, suggested: validSuggested, reason });
}

// --- Print flags to stdout ---

console.log(`\n========== Validation Flags for -${v2} ==========\n`);

if (validFlags.length === 0) {
  console.log("No issues found — all assignments look correct.");
} else {
  console.log(`${validFlags.length} flag(s) found:\n`);
  for (const flag of validFlags) {
    console.log(`  Headword:  ${flag.headword}`);
    if (flag.suggested.length > 0) {
      console.log(
        `  Suggested: ${flag.suggested.map((s) => `"${s}"`).join(", ")}`,
      );
    } else {
      console.log(`  Suggested: (lexicalized — remove from all meanings)`);
    }
    console.log(`  Reason:    ${flag.reason}`);
    console.log();
  }
}

console.log(`Archive: ${archiveTxtPath}`);
