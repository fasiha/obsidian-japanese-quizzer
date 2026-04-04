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
 *   node compound-verbs/cluster-meanings.mjs 出す --meanings-range 3 7
 *   node compound-verbs/cluster-meanings.mjs 出す --include-freq
 *
 * Output:
 *   compound-verbs/clusters/<v2>-meanings.json          (canonical, latest run)
 *   compound-verbs/clusters/<v2>-meanings-<timestamp>-<model>.json  (archive)
 *
 * Requires ANTHROPIC_API_KEY in .env
 * Requires BCCWJ_frequencylist_luw2_ver1_0.tsv in compound-verbs/ directory.
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

const includeFreq = args.includes("--include-freq");

const modelFlagIndex = args.indexOf("--model");
const model = modelFlagIndex >= 0 ? args[modelFlagIndex + 1] : "claude-haiku-4-5-20251001";

const meaningRangeIndex = args.indexOf("--meanings-range");
const meaningsMin = meaningRangeIndex >= 0 ? parseInt(args[meaningRangeIndex + 1]) : 3;
const meaningsMax = meaningRangeIndex >= 0 ? parseInt(args[meaningRangeIndex + 2]) : 7;

if (!v2) {
  console.error(
    "Usage: node compound-verbs/cluster-meanings.mjs <v2> [--dry-run] [--model MODEL] [--meanings-range MIN MAX] [--include-freq]"
  );
  process.exit(1);
}

if (isNaN(meaningsMin) || isNaN(meaningsMax) || meaningsMin < 1 || meaningsMax < meaningsMin) {
  console.error(`Invalid --meanings-range: ${meaningsMin} ${meaningsMax}. MIN must be >= 1, MAX >= MIN.`);
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

const withFreq = survey.map((entry) => {
  const frequency = getBccwjFrequency(entry.headword);
  return { ...entry, bccwjFrequency: frequency };
});
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

function formatEntry(entry, index) {
  const freqNote =
    includeFreq
      ? entry.bccwjFrequency > 0
        ? `BCCWJ frequency: ${entry.bccwjFrequency}`
        : "BCCWJ frequency: not in corpus"
      : null;

  const lines = [`${index + 1}. ${entry.headword} (${entry.reading}) — v1: ${entry.v1}`];
  if (freqNote) lines.push(`   ${freqNote}`);

  if (entry.jmdictMeanings && entry.jmdictMeanings.length > 0) {
    for (const [i, glosses] of entry.jmdictMeanings.entries()) {
      lines.push(`   JMDict sense ${i + 1}: ${glosses.join("; ")}`);
    }
  }

  for (const [i, sense] of entry.ninjal_senses.entries()) {
    const exPart = sense.example_ja
      ? ` (e.g. ${sense.example_ja} → ${sense.example_en})`
      : "";
    lines.push(`   NINJAL sense ${i + 1}: ${sense.definition_en}${exPart}`);
  }

  return lines.join("\n");
}

const compoundBlock = trimmed.map(formatEntry).join("\n\n");

const rangeInstruction =
  meaningsMin === meaningsMax
    ? `Identify exactly ${meaningsMin} distinct meanings.`
    : `Identify between ${meaningsMin} and ${meaningsMax} distinct meanings.`;

const prompt = `You are a Japanese linguistics expert analyzing the suffix verb ${v2} (${trimmed[0]?.v2_reading ?? ""}) as it appears in compound verbs (複合動詞).

Below are ${trimmed.length} compound verbs that use ${v2} as their suffix (v2 component), listed in descending order by BCCWJ corpus frequency. Each entry shows its JMDict senses and NINJAL VV Lexicon senses.

${compoundBlock}

---

## Your task

A suffix meaning is *productive* when knowing it lets a learner predict the compound's meaning from the base verb alone. Productive meanings come in two grades:
- "high" — fully predictable: a learner who knows the base verb and this suffix role can derive the compound's meaning
- "medium" — partially predictable: the pattern exists but is restricted to certain verb types or contexts, making it less transparent

Analyze the senses above and identify the distinct productive roles that ${v2} plays as a suffix component across all these compounds.

${rangeInstruction} Merge roles that are essentially the same pattern even if worded differently across compounds. Split roles only when the suffix is genuinely contributing something structurally different.

For each distinct suffix role:
- Write a short English description of what the suffix contributes (not the compound's meaning as a whole)
- Rate it as "high" or "medium" as defined above

Respond with a JSON array and nothing else (no markdown fences, no explanation outside the JSON):
[
  { "meaning": "<suffix meaning description>", "productivity": "high" },
  { "meaning": "<suffix meaning description>", "productivity": "medium" }
]`;

// --- Dry run: print prompt and exit ---

if (dryRun) {
  console.log("\n========== [DRY RUN] Prompt ==========\n");
  console.log(prompt);
  console.log("\n========== End of prompt ==========\n");
  console.log(`Would send ${trimmed.length} compounds to ${model}`);
  console.log(`Meanings range: ${meaningsMin}–${meaningsMax}`);
  console.log(`Include frequency in prompt: ${includeFreq}`);
  process.exit(0);
}

// --- Call LLM ---

console.log(`Calling ${model}...`);

const client = new Anthropic();
const message = await client.messages.create({
  model,
  max_tokens: 1024,
  messages: [{ role: "user", content: prompt }],
});

const responseText = message.content[0].text.trim();

// --- Parse JSON response ---
// Strip markdown code fences if the model wraps the output despite instructions.

let parsed;
try {
  const jsonText = responseText.replace(/^```(?:json)?\n?/i, "").replace(/\n?```$/, "").trim();
  parsed = JSON.parse(jsonText);
} catch (err) {
  console.error("ERROR: Could not parse LLM response as JSON.");
  console.error("Raw response:\n" + responseText);
  process.exit(1);
}

if (!Array.isArray(parsed) || parsed.length === 0) {
  console.error("ERROR: LLM returned an empty or non-array response.");
  console.error("Raw response:\n" + responseText);
  process.exit(1);
}

for (const item of parsed) {
  if (typeof item.meaning !== "string" || !["high", "medium"].includes(item.productivity)) {
    console.error(`ERROR: Malformed entry in LLM response: ${JSON.stringify(item)}`);
    console.error('Each entry must have a "meaning" string and "productivity" of "high" or "medium".');
    process.exit(1);
  }
}

// --- Write output ---

const clustersDir = join(__dirname, "clusters");
mkdirSync(clustersDir, { recursive: true });

const isoString = new Date().toISOString();
const timestamp = isoString.replace(/[:.]/g, "-").replace("T", "_").replace("Z", "");
const archivePath = join(clustersDir, `${v2}-meanings-${timestamp}-${model}.json`);
const canonicalPath = join(clustersDir, `${v2}-meanings.json`);
const rawResponsePath = join(clustersDir, `${v2}-meanings-${timestamp}-${model}.txt`);

writeFileSync(rawResponsePath, responseText, "utf8");
const output = JSON.stringify(parsed, null, 2);
writeFileSync(archivePath, output, "utf8");
writeFileSync(canonicalPath, output, "utf8");

console.log(`\n✓ Identified ${parsed.length} suffix meaning(s) for ${v2}:`);
for (const item of parsed) {
  console.log(`  [${item.productivity}] ${item.meaning}`);
}
console.log(`\nCanonical output: ${canonicalPath}`);
console.log(`Archive:          ${archivePath}`);
console.log(`Raw response:     ${rawResponsePath}`);

bccwjDb.close();
