/**
 * compound-verbs/cluster-meanings.mjs
 *
 * LLM Pass 1: Given all compounds for a suffix, asks the LLM to identify the
 * distinct meanings the suffix contributes as a component.
 *
 * Usage:
 *   node compound-verbs/cluster-meanings.mjs 出す
 *   node compound-verbs/cluster-meanings.mjs 出す --dry-run
 *   node compound-verbs/cluster-meanings.mjs 出す --model claude-sonnet-4-6
 *
 * Output:
 *   compound-verbs/clusters/<v2>-meanings.json          (canonical, latest run)
 *   compound-verbs/clusters/<v2>-meanings-<timestamp>-<model>.json  (archive)
 *   compound-verbs/clusters/<v2>-meanings-<timestamp>-<model>.txt   (flags + prompt + response)
 *
 * Requires ANTHROPIC_API_KEY in .env
 * Requires bccwj.sqlite at project root (build with: node .claude/scripts/build-bccwj-db.mjs)
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import Anthropic from "@anthropic-ai/sdk";
import Database from "better-sqlite3";

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
const requestedModel = modelFlagIndex >= 0 ? args[modelFlagIndex + 1] : "claude-haiku-4-5-20251001";

if (!v2) {
  console.error("Usage: node compound-verbs/cluster-meanings.mjs <v2> [--dry-run] [--model MODEL]");
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

// --- Load BCCWJ frequency database ---

const bccwjDbPath = join(root, "bccwj.sqlite");
if (!existsSync(bccwjDbPath)) {
  console.error("BCCWJ SQLite database not found: bccwj.sqlite");
  console.error("Build it with: node .claude/scripts/build-bccwj-db.mjs");
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

// --- Frequency trimming: top ~75% by cumulative frequency, or top 50, whichever is higher ---
// "Higher" means more compounds included, so we take the larger of the two counts.

const totalFrequency = withFreq.reduce((sum, e) => sum + e.bccwjFrequency, 0);

let cumulative = 0;
let count75pct = withFreq.length; // default: include all if totalFrequency is 0
if (totalFrequency > 0) {
  for (let i = 0; i < withFreq.length; i++) {
    cumulative += withFreq[i].bccwjFrequency;
    if (cumulative / totalFrequency >= 0.75) {
      count75pct = i + 1;
      break;
    }
  }
}

const cap50 = Math.min(50, withFreq.length);
const trimCount = Math.max(count75pct, cap50);
const trimmed = withFreq.slice(0, trimCount);

console.log(
  `${v2}: ${survey.length} compounds total, sending ${trimCount} to LLM` +
  ` (top-75%-by-freq=${count75pct}, cap-50=${cap50}, using higher=${trimCount})`
);

// --- Build the prompt ---

const headwordList = trimmed.map((e) => e.headword).join("、");

const prompt = `Make a short list of what appending -${v2} to a verb does to it. This is for a Japanese language learning app.

Use 1–4 meanings (4 maximum). Aim for broad recurring roles — not fine-grained sense distinctions, so merge patterns that differ only in degree or nuance. Each meaning must include <verb> explicitly, showing where the prefix verb fits (e.g. "to <verb> and go inside").

For example, -込む has roughly four broad usages:
[
  { "meaning": "to <verb> and go inside" },
  { "meaning": "to <verb> and put inside" },
  { "meaning": "to keep <verb>ing / become settled in a state" },
  { "meaning": "to <verb> thoroughly or to completion" }
]

But -締める has only one meaning across all its compounds:
[
  { "meaning": "to <verb> tightly and hold firm" }
]

Here are the ${trimmed.length} most common compound verbs ending in -${v2} in our Japanese learner corpus, to help ground your answer:
${headwordList}

Think through the patterns before committing to an answer. End your response with a JSON array.`;

// --- Dry run: print prompt and exit ---

if (dryRun) {
  console.log("\n========== [DRY RUN] Prompt ==========\n");
  console.log(prompt);
  console.log("\n========== End of prompt ==========\n");
  console.log(`Would send ${trimmed.length} compounds to ${requestedModel}`);
  process.exit(0);
}

// --- Call LLM ---

console.log(`Calling ${requestedModel}...`);

const client = new Anthropic();
const message = await client.messages.create({
  model: requestedModel,
  max_tokens: 4096,
  messages: [{ role: "user", content: prompt }],
});

const responseText = message.content[0].text.trim();
const actualModel = (message.model || requestedModel)?.replaceAll(/\//g, '-');

// --- Write raw response txt (always, even if JSON parsing fails) ---

const clustersDir = join(__dirname, "clusters");
mkdirSync(clustersDir, { recursive: true });

const isoString = new Date().toISOString();
const timestamp = isoString.replace(/[:.]/g, "-").replace("T", "_").replace("Z", "");
const archivePath = join(clustersDir, `${v2}-meanings-${timestamp}-${actualModel}.json`);
const canonicalPath = join(clustersDir, `${v2}-meanings.json`);
const rawResponsePath = join(clustersDir, `${v2}-meanings-${timestamp}-${actualModel}.txt`);

const flagsSummary = [
  `suffix: ${v2}`,
  `model: ${actualModel}`,
  `compounds-sent: ${trimmed.length}`,
  `timestamp: ${isoString}`,
  `args: node compound-verbs/cluster-meanings.mjs ${args.join(" ")}`,
].join("\n");

const rawResponseContent = [
  "========== FLAGS ==========",
  flagsSummary,
  "",
  "========== PROMPT ==========",
  prompt,
  "",
  "========== RESPONSE ==========",
  responseText,
].join("\n");

writeFileSync(rawResponsePath, rawResponseContent, "utf8");

// --- Parse JSON response ---
// The model reasons before the JSON array, so extract the last [...] block.
// Match the last "[" that appears at the start of a line to avoid matching
// "[...]" fragments inside prose or string values.

let parsed;
try {
  const allArrayLineMatches = [...responseText.matchAll(/^\s*\[/gm)];
  const lastArrayStart = allArrayLineMatches.at(-1);
  const jsonText = lastArrayStart
    ? responseText.slice(lastArrayStart.index).replace(/\n?```$/, "").trim()
    : responseText.replace(/^```(?:json)?\n?/i, "").replace(/\n?```$/, "").trim();
  parsed = JSON.parse(jsonText);
} catch (err) {
  console.error("ERROR: Could not parse LLM response as JSON.");
  console.error(`Raw response saved to: ${rawResponsePath}`);
  process.exit(1);
}

if (!Array.isArray(parsed) || parsed.length === 0) {
  console.error("ERROR: LLM returned an empty or non-array response.");
  console.error(`Raw response saved to: ${rawResponsePath}`);
  process.exit(1);
}

for (const item of parsed) {
  if (typeof item.meaning !== "string") {
    console.error(`ERROR: Malformed entry in LLM response: ${JSON.stringify(item)}`);
    console.error('Each entry must have a "meaning" string.');
    console.error(`Raw response saved to: ${rawResponsePath}`);
    process.exit(1);
  }
}

const output = JSON.stringify(parsed, null, 2);
writeFileSync(archivePath, output, "utf8");
writeFileSync(canonicalPath, output, "utf8");

console.log(`\n✓ Identified ${parsed.length} suffix meaning(s) for ${v2}:`);
for (const item of parsed) {
  console.log(`  ${item.meaning}`);
}
console.log(`\nCanonical output: ${canonicalPath}`);
console.log(`Archive:          ${archivePath}`);
console.log(`Raw response:     ${rawResponsePath}`);

bccwjDb.close();
