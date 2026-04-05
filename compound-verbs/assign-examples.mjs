/**
 * compound-verbs/assign-examples.mjs
 *
 * LLM Pass 2: Given the suffix meanings discovered in Pass 1, asks the LLM to
 * assign compounds to meanings in a single call. The model sees all meanings at
 * once and returns a JSON object mapping each meaning to the compounds that fit
 * it. A compound may appear under more than one meaning.
 *
 * Usage:
 *   node compound-verbs/assign-examples.mjs 出す
 *   node compound-verbs/assign-examples.mjs 出す --dry-run
 *   node compound-verbs/assign-examples.mjs 出す --model claude-haiku-4-5-20251001
 *
 * Automatically uses <v2>-meanings-sharpened.json if it exists (logged with a
 * bright notice), otherwise falls back to <v2>-meanings.json.
 *
 * Input:
 *   compound-verbs/survey/<v2>.json              (from survey.mjs)
 *   compound-verbs/clusters/<v2>-meanings.json   (from cluster-meanings.mjs)
 *
 * Output:
 *   compound-verbs/clusters/<v2>-assignments-<timestamp>-<model>.txt
 *     (flags + prompt + raw response, one file per run)
 *   compound-verbs/clusters/<v2>-assignments.json
 *     (canonical: object keyed by verbatim meaning string → array of headword strings)
 *
 * Requires ANTHROPIC_API_KEY in .env
 * Requires compound-verbs/bccwj.sqlite (build with: node compound-verbs/build-bccwj-db.mjs)
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import Anthropic from "@anthropic-ai/sdk";
import Database from "better-sqlite3";
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
const model = modelFlagIndex >= 0 ? args[modelFlagIndex + 1] : "claude-haiku-4-5-20251001";

if (!v2) {
  console.error("Usage: node compound-verbs/assign-examples.mjs <v2> [--dry-run] [--model MODEL]");
  process.exit(1);
}

// --- Load survey file ---

const surveyPath = join(__dirname, "survey", `${v2}.json`);
if (!existsSync(surveyPath)) {
  console.error(`Survey file not found: ${surveyPath}`);
  console.error(`Run: node compound-verbs/survey.mjs ${v2}`);
  process.exit(1);
}
const survey = JSON.parse(readFileSync(surveyPath, "utf8"));

// --- Load meanings file ---

const sharpenedMeaningsPath = join(__dirname, "clusters", `${v2}-meanings-sharpened.json`);
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
  console.log(chalk.redBright(`Run sharpen-meanings.mjs ${v2} to improve assignment quality.`));
}

const useSharpened = meaningsPath === sharpenedMeaningsPath;
const meanings = JSON.parse(readFileSync(meaningsPath, "utf8"));

if (!Array.isArray(meanings) || meanings.length === 0) {
  console.error(`Meanings file is empty or malformed: ${meaningsPath}`);
  process.exit(1);
}

// --- Load BCCWJ frequency database ---

const bccwjDbPath = join(__dirname, "bccwj.sqlite");
if (!existsSync(bccwjDbPath)) {
  console.error("BCCWJ SQLite database not found: compound-verbs/bccwj.sqlite");
  console.error("Build it with: node compound-verbs/build-bccwj-db.mjs");
  process.exit(1);
}

const bccwjDb = new Database(bccwjDbPath, { readonly: true });
const bccwjLookup = bccwjDb.prepare("SELECT frequency FROM bccwj WHERE kanji = ? LIMIT 1");

function getBccwjFrequency(word) {
  const row = bccwjLookup.get(word);
  return row ? row.frequency : 0;
}

// --- Attach BCCWJ frequencies and sort descending ---

const withFreq = survey.map((entry) => ({
  ...entry,
  bccwjFrequency: getBccwjFrequency(entry.headword),
}));
withFreq.sort((a, b) => b.bccwjFrequency - a.bccwjFrequency);

// --- Frequency trimming: top ~90% by cumulative frequency, or top 100, whichever includes more ---
// Pass 2 uses broader coverage than Pass 1 (90%/100 vs 75%/50) so the lexicalized
// tail has more candidates to fall out from — compounds not assigned to any meaning
// become the opaque/lexicalized sense in Pass 3.

const totalFrequency = withFreq.reduce((sum, e) => sum + e.bccwjFrequency, 0);

let cumulative = 0;
let count90pct = withFreq.length; // default: include all if totalFrequency is 0
if (totalFrequency > 0) {
  for (let i = 0; i < withFreq.length; i++) {
    cumulative += withFreq[i].bccwjFrequency;
    if (cumulative / totalFrequency >= 0.90) {
      count90pct = i + 1;
      break;
    }
  }
}

const cap100 = Math.min(100, withFreq.length);
const trimCount = Math.max(count90pct, cap100);
const trimmed = withFreq.slice(0, trimCount);

console.log(
  `${v2}: ${survey.length} compounds total, sending ${trimCount} to LLM` +
  ` (top-90%-by-freq=${count90pct}, cap-100=${cap100}, using higher=${trimCount})`
);
console.log(`Using meanings: ${useSharpened ? "sharpened" : "original"} (${meaningsPath})`);

// --- Build compound list, augmenting rare/unknown entries with NINJAL gloss ---
// Compounds with BCCWJ frequency = 0 or no JMDict ID may be unfamiliar to the
// model. Appending their NINJAL English definition inline lets the model categorize
// them confidently without adding noise for well-known words.

const compoundLines = trimmed.map((entry) => {
  const needsGloss = entry.bccwjFrequency === 0 || !entry.jmdictId;
  if (needsGloss && entry.ninjal_senses?.[0]?.definition_en) {
    return `${entry.headword}（${entry.ninjal_senses[0].definition_en}）`;
  }
  return entry.headword;
});

const compoundListText = compoundLines.join("\n");

// --- Build the set of known headwords for hallucination detection ---

const knownHeadwords = new Set(trimmed.map((e) => e.headword));

// --- Build meanings block and expected JSON keys ---

const meaningsBlock = meanings
  .map((m, i) => `  ${i + 1}. "${m.meaning}"`)
  .join("\n");

const exampleOutputEntries = meanings.map((m) => `  "${m.meaning}": ["headword1", "headword2"]`).join(",\n");

// --- Build prompt ---

const prompt = `You are helping a Japanese learner understand the suffix -${v2} in compound verbs.

-${v2} has these distinct meanings when appended to a verb:
${meaningsBlock}

Your task: for each compound below, assign it to whichever meaning(s) -${v2} clearly contributes in it.

Rules:
- Assign a compound to a meaning if -${v2} contributes that meaning in a way a learner could see from the parts.
- Only assign a compound to multiple meanings if each assignment is as obvious as a single-meaning case; do not stretch a meaning to avoid omitting a compound.
- Omit a compound only if -${v2}'s role in it is opaque or fully lexicalized (the compound must be memorized as a whole).

Compounds ending in -${v2} (${trimmed.length} most common, sorted by corpus frequency; rare or lesser-known entries include an English gloss):
${compoundListText}

Reason through each compound. Then end your response with a JSON object whose keys are the exact meaning strings above and whose values are arrays of matching headword strings (kanji only, no glosses). Omit a key entirely if no compounds clearly fit that meaning.

Example output shape (keys must be verbatim from the list above):
{
${exampleOutputEntries}
}`;

// --- Dry run: print prompt and exit ---

if (dryRun) {
  console.log("\n========== [DRY RUN] Prompt ==========\n");
  console.log(prompt);
  console.log("\n========== End of prompt ==========\n");
  console.log(`Would send ${trimmed.length} compounds to ${model}`);
  bccwjDb.close();
  process.exit(0);
}

// --- Call LLM ---

console.log(`Calling ${model}...`);

const client = new Anthropic();
const message = await client.messages.create({
  model,
  max_tokens: 4096,
  messages: [{ role: "user", content: prompt }],
});

const responseText = message.content[0].text.trim();

// --- Write archive .txt ---

const clustersDir = join(__dirname, "clusters");
mkdirSync(clustersDir, { recursive: true });

const isoString = new Date().toISOString();
const timestamp = isoString.replace(/[:.]/g, "-").replace("T", "_").replace("Z", "");
const archiveTxtPath = join(clustersDir, `${v2}-assignments-${timestamp}-${model}.txt`);
const canonicalPath = join(clustersDir, `${v2}-assignments.json`);

const flagsSummary = [
  `suffix: ${v2}`,
  `model: ${model}`,
  `compounds-sent: ${trimmed.length}`,
  `timestamp: ${isoString}`,
  `args: node compound-verbs/assign-examples.mjs ${args.join(" ")}`,
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
  "utf8"
);

// --- Parse JSON object from response ---
// The model reasons before the JSON, so extract the last {...} block.

let parsed;
try {
  const allObjectLineMatches = [...responseText.matchAll(/^\s*\{/gm)];
  const lastObjectStart = allObjectLineMatches.at(-1);
  const jsonText = lastObjectStart
    ? responseText.slice(lastObjectStart.index).replace(/\n?```$/, "").trim()
    : responseText.replace(/^```(?:json)?\n?/i, "").replace(/\n?```$/, "").trim();
  parsed = JSON.parse(jsonText);
} catch (err) {
  console.error("ERROR: Could not parse LLM response as JSON.");
  console.error(`Raw response saved to: ${archiveTxtPath}`);
  process.exit(1);
}

if (typeof parsed !== "object" || Array.isArray(parsed) || parsed === null) {
  console.error("ERROR: LLM returned a non-object response.");
  console.error(`Raw response saved to: ${archiveTxtPath}`);
  process.exit(1);
}

// --- Validate: keys must be known meaning strings, values must be arrays of known headwords ---

const knownMeanings = new Set(meanings.map((m) => m.meaning));
const assignments = {};

for (const [key, value] of Object.entries(parsed)) {
  if (!knownMeanings.has(key)) {
    console.warn(`WARNING: LLM returned unknown meaning key "${key}" — skipping`);
    continue;
  }
  if (!Array.isArray(value)) {
    console.warn(`WARNING: Value for meaning "${key}" is not an array — skipping`);
    continue;
  }
  const valid = [];
  for (const headword of value) {
    if (typeof headword !== "string") {
      console.warn(`WARNING: Non-string entry under "${key}": ${JSON.stringify(headword)} — skipping`);
      continue;
    }
    if (!knownHeadwords.has(headword)) {
      console.warn(`WARNING: LLM hallucinated headword "${headword}" under "${key}" — not in survey, skipping`);
      continue;
    }
    valid.push(headword);
  }
  assignments[key] = valid;
}

// --- Write canonical assignments JSON ---

const output = {
  _metadata: {
    suffix: v2,
    model,
    timestamp: isoString,
    compounds_sent: trimmed.map((e) => e.headword),
  },
  ...assignments,
};

writeFileSync(canonicalPath, JSON.stringify(output, null, 2), "utf8");

console.log(`\n✓ Assignments written to: ${canonicalPath}`);
console.log(`  ${Object.keys(assignments).length} meaning(s) with assignments`);
for (const [meaning, headwords] of Object.entries(assignments)) {
  console.log(`  "${meaning}": ${headwords.length} compound(s) — ${headwords.join("、") || "(none)"}`);
}
console.log(`\nArchive: ${archiveTxtPath}`);

bccwjDb.close();
