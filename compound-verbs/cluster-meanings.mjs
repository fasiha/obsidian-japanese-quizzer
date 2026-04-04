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
 *   node compound-verbs/cluster-meanings.mjs 出す --example
 *   node compound-verbs/cluster-meanings.mjs 出す --simple
 *   node compound-verbs/cluster-meanings.mjs 出す --simple-with-senses jmdict
 *   node compound-verbs/cluster-meanings.mjs 出す --simple-with-senses ninjal
 *   node compound-verbs/cluster-meanings.mjs 出す --simple-with-senses both
 *   node compound-verbs/cluster-meanings.mjs 出す --include-freq
 *   node compound-verbs/cluster-meanings.mjs 出す --no-min-max
 *   node compound-verbs/cluster-meanings.mjs 出す --no-productivity
 *   node compound-verbs/cluster-meanings.mjs 出す --allow-reasoning
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

const noMinMax = args.includes("--no-min-max");
const noProductivity = args.includes("--no-productivity");
const allowReasoning = args.includes("--allow-reasoning");
const useExample = args.includes("--example");
const simple = args.includes("--simple");
const simpleWithSensesIndex = args.indexOf("--simple-with-senses");
const simpleWithSenses = simpleWithSensesIndex >= 0 ? args[simpleWithSensesIndex + 1] : null;
if (simpleWithSenses !== null && !["jmdict", "ninjal", "both"].includes(simpleWithSenses)) {
  console.error(`--simple-with-senses requires an argument: jmdict, ninjal, or both`);
  process.exit(1);
}
const meaningRangeIndex = args.indexOf("--meanings-range");
const meaningsMin = meaningRangeIndex >= 0 ? parseInt(args[meaningRangeIndex + 1]) : 3;
const meaningsMax = meaningRangeIndex >= 0 ? parseInt(args[meaningRangeIndex + 2]) : 7;

if (!v2) {
  console.error(
    "Usage: node compound-verbs/cluster-meanings.mjs <v2> [--dry-run] [--model MODEL] [--meanings-range MIN MAX] [--no-min-max] [--include-freq]"
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

// senseSources controls which senses appear: "jmdict", "ninjal", or "both"
function formatEntry(entry, index, senseSources = "both") {
  const freqNote =
    includeFreq
      ? entry.bccwjFrequency > 0
        ? `BCCWJ frequency: ${entry.bccwjFrequency}`
        : "BCCWJ frequency: not in corpus"
      : null;

  const lines = [`${index + 1}. ${entry.headword} (${entry.reading}) — v1: ${entry.v1}`];
  if (freqNote) lines.push(`   ${freqNote}`);

  if (senseSources !== "ninjal" && entry.jmdictMeanings && entry.jmdictMeanings.length > 0) {
    for (const [i, glosses] of entry.jmdictMeanings.entries()) {
      lines.push(`   JMDict sense ${i + 1}: ${glosses.join("; ")}`);
    }
  }

  if (senseSources !== "jmdict") {
    for (const [i, sense] of entry.ninjal_senses.entries()) {
      const exPart = sense.example_ja
        ? ` (e.g. ${sense.example_ja} → ${sense.example_en})`
        : "";
      lines.push(`   NINJAL sense ${i + 1}: ${sense.definition_en}${exPart}`);
    }
  }

  return lines.join("\n");
}

const headwordList = trimmed.map((e) => e.headword).join("、");
const compoundBlock = trimmed.map((e, i) => formatEntry(e, i, "both")).join("\n\n");

const rangeInstruction = noMinMax
  ? `Identify as many distinct roles as a learner would find useful — no minimum or maximum.`
  : meaningsMin === meaningsMax
    ? `Identify exactly ${meaningsMin} distinct roles.`
    : `Identify between ${meaningsMin} and ${meaningsMax} distinct roles.`;

// --- Prompt building helpers ---

// Returns the JSON schema line(s) used in the "Respond with..." block.
function jsonSchemaExample(suffix) {
  if (noProductivity) {
    return `[\n  { "meaning": "<what -${suffix} does to the verb>" },\n  { "meaning": "<what -${suffix} does to the verb>" }\n]`;
  }
  return `[\n  { "meaning": "<what -${suffix} does to the verb>", "productivity": "high" },\n  { "meaning": "<what -${suffix} does to the verb>", "productivity": "medium" }\n]`;
}

// Returns the closing instruction that asks the model to emit JSON.
function respondInstruction(schemaExample) {
  if (allowReasoning) {
    return `Think through the patterns before committing to an answer. End your response with a JSON array (no markdown fences):\n${schemaExample}`;
  }
  return `Respond with a JSON array and nothing else (no markdown fences):\n${schemaExample}`;
}

const simpleCorpusLine = `Here are the ${trimmed.length} most common compound verbs ending in -${v2} in our Japanese learner corpus, to help ground your answer:`;

const komuSimpleExample = noProductivity
  ? `[
  { "meaning": "to <verb> and go inside" },
  { "meaning": "to <verb> and put inside" },
  { "meaning": "to keep <verb>ing / become settled in a state" },
  { "meaning": "to <verb> thoroughly or to completion" }
]`
  : `[
  { "meaning": "to <verb> and go inside", "productivity": "high" },
  { "meaning": "to <verb> and put inside", "productivity": "high" },
  { "meaning": "to keep <verb>ing / become settled in a state", "productivity": "medium" },
  { "meaning": "to <verb> thoroughly or to completion", "productivity": "medium" }
]`;

const simplePromptBase = `Make a short list (2-4) of what appending -${v2} to a verb does to it. This is for Japanese learners at the N4–N5 level.

For example, -込む falls into roughly four categories:
${komuSimpleExample}

${simpleCorpusLine}`;

const simpleProductivityLine = noProductivity
  ? ""
  : `\nUse "high" for roles where the compound meaning is fully predictable from the base verb, "medium" where the pattern is real but less transparent.`;

const simplePrompt = `${simplePromptBase}
${headwordList}

${respondInstruction(jsonSchemaExample(v2))}${simpleProductivityLine}`;

const simpleWithSensesBlock = trimmed.map((e, i) => formatEntry(e, i, simpleWithSenses ?? "both")).join("\n\n");

const simpleWithSensesPrompt = `${simplePromptBase}

${simpleWithSensesBlock}

${respondInstruction(jsonSchemaExample(v2))}${simpleProductivityLine}`;

// 込む example entries, with or without productivity labels.
const komuExampleEntries = noProductivity
  ? `[
  { "meaning": "going into or inside something (e.g. 飛び込む to plunge in, 転がり込む to roll in, 攻め込む to invade)" },
  { "meaning": "putting or pressing something inside (e.g. 詰め込む to cram in, 追い込む to corner into, 誘い込む to entice into)" },
  { "meaning": "remaining in a state or becoming settled (e.g. 座り込む to sit down and stay, 塞ぎ込む to mope, 老け込む to age)" },
  { "meaning": "doing something thoroughly or to completion (e.g. 煮込む to boil well, 教え込む to drill into someone)" }
]`
  : `[
  { "meaning": "going into or inside something (e.g. 飛び込む to plunge in, 転がり込む to roll in, 攻め込む to invade)", "productivity": "high" },
  { "meaning": "putting or pressing something inside (e.g. 詰め込む to cram in, 追い込む to corner into, 誘い込む to entice into)", "productivity": "high" },
  { "meaning": "remaining in a state or becoming settled (e.g. 座り込む to sit down and stay, 塞ぎ込む to mope, 老け込む to age)", "productivity": "medium" },
  { "meaning": "doing something thoroughly or to completion (e.g. 煮込む to boil well, 教え込む to drill into someone)", "productivity": "medium" }
]`;

const fullSchemaExample = noProductivity
  ? `[\n  { "meaning": "<suffix meaning description>" },\n  { "meaning": "<suffix meaning description>" }\n]`
  : `[\n  { "meaning": "<suffix meaning description>", "productivity": "high" },\n  { "meaning": "<suffix meaning description>", "productivity": "medium" }\n]`;

const productivityGradesBlock = noProductivity
  ? ""
  : `Productive roles come in two grades:
- "high" — fully predictable across multiple compounds: a learner who knows the base verb and this suffix role can derive each compound's meaning
- "medium" — partially predictable across multiple compounds: the pattern recurs but is restricted to certain verb types or contexts, making it less transparent

`;

const rateProductivityLine = noProductivity
  ? ""
  : `\n- Rate it as "high" or "medium" as defined above`;

const fullPrompt = `You are helping build a Japanese learning app. Your output will be shown to learners to help them orient themselves to the suffix verb ${v2} (${trimmed[0]?.v2_reading ?? ""}) and understand how it behaves across different compound verbs (複合動詞).

Below are ${trimmed.length} compound verbs that use ${v2} as their suffix (v2 component), listed in descending order by BCCWJ corpus frequency. Each entry shows its JMDict senses and NINJAL VV Lexicon senses.

${compoundBlock}

---

## Your task

A suffix role is *productive* when knowing it lets a learner predict many compounds' meanings from their base verbs alone — it must be a genuine recurring pattern across multiple compounds, not a description that fits only one or two cases. ${productivityGradesBlock}Analyze the senses above and identify the distinct productive roles that ${v2} plays as a suffix component across all these compounds. Your goal is to help learners orient themselves — prefer broad roles that cover many compounds over narrow roles that fit only a few. Err on the side of merging.

${rangeInstruction} Merge roles that are essentially the same pattern even if worded differently across compounds. Split roles only when the suffix is genuinely contributing something structurally different that a learner would benefit from knowing separately.

Two constraints:
- Each role must cover at least 3 compounds from the input list. A role that fits fewer than 3 compounds is not a learner-useful pattern — omit it entirely.
- Assign each compound to at most one role — the role that best describes the suffix's contribution for its primary sense. Roles must be disjoint.
${useExample ? `
## Example of the desired granularity

Here is a well-calibrated example for a different suffix, 込む (こむ), to show the level of breadth and abstraction we are aiming for:

${komuExampleEntries}

Notice: four broad roles, each covering many compounds. Not fine-grained distinctions like "entering a building" vs "entering a container" — those would be merged into one role.
` : ""}
For each distinct suffix role:
- Write a short English description of what the suffix contributes (not the compound's meaning as a whole)${rateProductivityLine}

${respondInstruction(fullSchemaExample)}`;

const prompt = simple ? simplePrompt : simpleWithSenses ? simpleWithSensesPrompt : fullPrompt;

// --- Dry run: print prompt and exit ---

if (dryRun) {
  console.log("\n========== [DRY RUN] Prompt ==========\n");
  console.log(prompt);
  console.log("\n========== End of prompt ==========\n");
  console.log(`Would send ${trimmed.length} compounds to ${model}`);
  console.log(`Prompt mode: ${simple ? "simple" : simpleWithSenses ? `simple-with-senses:${simpleWithSenses}` : `full${useExample ? " + example" : ""}`}`);
  console.log(`Meanings range: ${noMinMax ? "unconstrained (--no-min-max)" : `${meaningsMin}–${meaningsMax}`}`);
  console.log(`Include frequency in prompt: ${includeFreq}`);
  console.log(`No productivity labels: ${noProductivity}`);
  console.log(`Allow reasoning before JSON: ${allowReasoning}`);
  process.exit(0);
}

// --- Call LLM ---

console.log(`Calling ${model}...`);

const client = new Anthropic();
const message = await client.messages.create({
  model,
  max_tokens: allowReasoning ? 4096 : 1024,
  messages: [{ role: "user", content: prompt }],
});

const responseText = message.content[0].text.trim();

// --- Parse JSON response ---
// Strip markdown code fences if the model wraps the output despite instructions.

let parsed;
try {
  // When --allow-reasoning the model may reason before the JSON array.
  // Extract the last [...] block to handle both cases uniformly.
  const lastArrayMatch = responseText.match(/(\[[\s\S]*\])[^[]*$/);
  const jsonText = lastArrayMatch
    ? lastArrayMatch[1].trim()
    : responseText.replace(/^```(?:json)?\n?/i, "").replace(/\n?```$/, "").trim();
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
  const meaningOk = typeof item.meaning === "string";
  const productivityOk = noProductivity || ["high", "medium"].includes(item.productivity);
  if (!meaningOk || !productivityOk) {
    console.error(`ERROR: Malformed entry in LLM response: ${JSON.stringify(item)}`);
    console.error(
      noProductivity
        ? 'Each entry must have a "meaning" string.'
        : 'Each entry must have a "meaning" string and "productivity" of "high" or "medium".'
    );
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

const flagsSummary = [
  `suffix: ${v2}`,
  `model: ${model}`,
  `prompt-mode: ${simple ? "simple" : simpleWithSenses ? `simple-with-senses:${simpleWithSenses}` : `full${useExample ? "+example" : ""}`}`,
  `meanings-range: ${noMinMax ? "unconstrained (--no-min-max)" : `${meaningsMin}–${meaningsMax}`}`,
  `include-freq: ${includeFreq}`,
  `no-productivity: ${noProductivity}`,
  `allow-reasoning: ${allowReasoning}`,
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
