/**
 * compound-verbs/sharpen-meanings.mjs
 *
 * LLM Pass 1b (optional): Given the meanings discovered in Pass 1 and the
 * compound list, asks the LLM to rewrite each meaning so its boundaries are
 * precise enough to classify compounds unambiguously. The sharpened meanings
 * replace the originals and become the input to Pass 2 (assign-examples.mjs).
 *
 * The problem this solves: cluster-meanings.mjs optimises for human
 * comprehension — its output is evocative and learner-friendly but the
 * boundaries between meanings can be fuzzy. assign-examples.mjs uses those
 * meanings as classifiers, so fuzzy boundaries cause compounds to land in the
 * wrong bucket. This pass tightens the boundaries while keeping the meanings
 * recognisable to learners.
 *
 * Usage:
 *   node compound-verbs/sharpen-meanings.mjs 出す
 *   node compound-verbs/sharpen-meanings.mjs 出す --dry-run
 *   node compound-verbs/sharpen-meanings.mjs 出す --model claude-haiku-4-5-20251001
 *
 * Input:
 *   compound-verbs/survey/<v2>.json              (from survey.mjs)
 *   compound-verbs/clusters/<v2>-meanings.json   (from cluster-meanings.mjs)
 *
 * Output:
 *   compound-verbs/clusters/<v2>-meanings-sharpened-<timestamp>-<model>.txt
 *     (flags + prompt + raw response, one file per run)
 *   compound-verbs/clusters/<v2>-meanings-sharpened.json
 *     (sharpened meanings as a separate file; original <v2>-meanings.json is left untouched)
 *
 * To promote sharpened meanings to canonical:
 *   cp compound-verbs/clusters/<v2>-meanings-sharpened.json compound-verbs/clusters/<v2>-meanings.json
 *
 * Requires ANTHROPIC_API_KEY in .env
 * Requires compound-verbs/bccwj.sqlite (build with: node compound-verbs/build-bccwj-db.mjs)
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
const reparseJsonIndex = args.indexOf("--reparse-json");
const reparseJsonPath = reparseJsonIndex >= 0 ? args[reparseJsonIndex + 1] : null;

if (!v2) {
  console.error("Usage: node compound-verbs/sharpen-meanings.mjs <v2> [--dry-run] [--model MODEL]");
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

const meaningsPath = join(__dirname, "clusters", `${v2}-meanings.json`);
if (!existsSync(meaningsPath)) {
  console.error(`Meanings file not found: ${meaningsPath}`);
  console.error(`Run: node compound-verbs/cluster-meanings.mjs ${v2}`);
  process.exit(1);
}
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

// --- Frequency trimming: same thresholds as assign-examples.mjs (90% / cap 100) ---

const totalFrequency = withFreq.reduce((sum, e) => sum + e.bccwjFrequency, 0);

let cumulative = 0;
let count90pct = withFreq.length;
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

// --- Build compound list, augmenting rare/unknown entries with NINJAL gloss ---

const compoundLines = trimmed.map((entry) => {
  const needsGloss = entry.bccwjFrequency === 0 || !entry.jmdictId;
  if (needsGloss && entry.ninjal_senses?.[0]?.definition_en) {
    return `${entry.headword}（${entry.ninjal_senses[0].definition_en}）`;
  }
  return entry.headword;
});

const compoundListText = compoundLines.join("\n");

// --- Build meanings block ---

const meaningsBlock = meanings
  .map((m, i) => `  ${i + 1}. "${m.meaning}"`)
  .join("\n");

const exampleOutputEntries = meanings
  .map((m) => `  {"meaning": "${m.meaning}"}`)
  .join(",\n");

// --- Build prompt ---

const prompt = `You are helping design a Japanese learning app. The suffix -${v2} has these draft/proposal meanings for what it does to a prefix verb when
used in a compound verb:

${meaningsBlock}

These meanings will be used to classify the following ${trimmed.length} compounds. Each compound will be assigned to whichever meaning(s) -${v2} clearly contributes.

Compounds ending in -${v2} (sorted by corpus frequency; rare or lesser-known entries include an English gloss):
${compoundListText}

Your task: rewrite each meaning so that a reader or LLM could use it as an unambiguous classification rule. Specifically:

- Each meaning must include <verb> explicitly, showing where the prefix verb fits (e.g. "to <verb> something outward").
- Each meaning must be specific enough that a given compound clearly belongs to at most one meaning. Where two meanings are currently hard to tell apart, add a distinguishing phrase that draws the boundary (e.g. "something that already existed" vs "something new").
- Watch for any meaning that could become a catch-all residual bucket — one that would absorb compounds that don't fit neatly elsewhere. If a meaning uses vague intensifiers like "emphatic," "assertive," or "vigorous," or broad qualifiers like "emotional state" or "magnitude," replace them with concrete, observable properties. Add explicit negative exclusions referencing the other meanings where needed (e.g. "excludes upward spatial movement (meaning 1) and processes that simply reach completion (meaning 2)").
- Exclusions between adjacent meanings must be symmetric: if meaning 3 says "excludes meaning 2", then meaning 2 must also say "excludes meaning 3". Check every pair of meanings and ensure the exclusion boundary is stated in both directions.
- Before writing your answer, scan the compound list for any compound that does not fit any of the draft meanings. Name it and explain why — do not silently assign it to the closest meaning or leave it for the lexicalized bucket when it follows a clear pattern.
- When a meaning involves physical contact or attachment, ensure the wording covers the full range of contact types (tying, placing, writing, coating) and not just adhesive or chemical bonding.
- Technical linguistic terms are allowed and encouraged if they sharpen the boundary (e.g. "inchoative", "causative", "locative extraction"). Learner-friendliness is not a goal here — precision is.
- Do not add or remove meanings; rewrite only.

Reason through any boundaries that seem fuzzy, and identify which meaning (if any) risks becoming a catch-all, before writing your answer. Then end your response with a JSON array of objects in the same order as above:

[
${exampleOutputEntries}
]`;

// --- Dry run: print prompt and exit ---

if (dryRun) {
  console.log("\n========== [DRY RUN] Prompt ==========\n");
  console.log(prompt);
  console.log("\n========== End of prompt ==========\n");
  console.log(`Would send ${trimmed.length} compounds to ${requestedModel}`);
  bccwjDb.close();
  process.exit(0);
}

// --- Call LLM (or reparse from saved JSON) ---

let responseText;
let actualModel;

if (reparseJsonPath) {
  console.log(`Reparsing from saved JSON: ${reparseJsonPath}`);
  responseText = readFileSync(reparseJsonPath, "utf8").trim();
  actualModel = requestedModel;
} else {
  console.log(`Calling ${requestedModel}...`);
  const client = new Anthropic();
  const message = await client.messages.create({
    model: requestedModel,
    max_tokens: 8192,
    messages: [{ role: "user", content: prompt }],
  });
  responseText = message.content[0].text.trim();
  actualModel = (message.model || requestedModel)?.replaceAll(/\//g, "-");
}


// --- Write archive .txt ---

const clustersDir = join(__dirname, "clusters");
mkdirSync(clustersDir, { recursive: true });

const isoString = new Date().toISOString();
const timestamp = isoString.replace(/[:.]/g, "-").replace("T", "_").replace("Z", "");
const archiveTxtPath = join(clustersDir, `${v2}-meanings-sharpened-${timestamp}-${actualModel}.txt`);
const sharpenedPath = join(clustersDir, `${v2}-meanings-sharpened.json`);

const flagsSummary = [
  `suffix: ${v2}`,
  `model: ${actualModel}`,
  `compounds-sent: ${trimmed.length}`,
  `timestamp: ${isoString}`,
  `args: node compound-verbs/sharpen-meanings.mjs ${args.join(" ")}`,
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

// --- Parse JSON array from response ---

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
  console.error(`Raw response saved to: ${archiveTxtPath}`);
  process.exit(1);
}

if (!Array.isArray(parsed) || parsed.length !== meanings.length) {
  console.error(`ERROR: Expected ${meanings.length} meanings in response, got ${Array.isArray(parsed) ? parsed.length : "non-array"}.`);
  console.error(`Raw response saved to: ${archiveTxtPath}`);
  process.exit(1);
}

// --- Validate: each element must have a non-empty meaning string ---

const sharpened = [];
for (let i = 0; i < parsed.length; i++) {
  const item = parsed[i];
  if (typeof item?.meaning !== "string" || !item.meaning.trim()) {
    console.error(`ERROR: Element ${i} in response is missing a "meaning" string.`);
    console.error(`Raw response saved to: ${archiveTxtPath}`);
    process.exit(1);
  }
  sharpened.push({ ...meanings[i], meaning: item.meaning.trim() });
}

// --- Show diff and write canonical meanings JSON ---

console.log("\nSharpened meanings:");
for (let i = 0; i < meanings.length; i++) {
  if (meanings[i].meaning !== sharpened[i].meaning) {
    console.log(`  ${i + 1}. BEFORE: ${meanings[i].meaning}`);
    console.log(`     AFTER:  ${sharpened[i].meaning}`);
  } else {
    console.log(`  ${i + 1}. UNCHANGED: ${sharpened[i].meaning}`);
  }
}

writeFileSync(sharpenedPath, JSON.stringify(sharpened, null, 2), "utf8");

console.log(`\n✓ Sharpened meanings written to: ${sharpenedPath}`);
console.log(`   Original meanings unchanged:   ${meaningsPath}`);
console.log(`   To promote: cp ${sharpenedPath} ${meaningsPath}`);
console.log(`Archive: ${archiveTxtPath}`);

bccwjDb.close();
