/**
 * compound-verbs/assign-examples.mjs
 *
 * LLM Pass 2: Given the suffix meanings discovered in Pass 1, asks the LLM to
 * assign compounds to each meaning. One LLM call per meaning, run serially.
 * Each call sees ALL meanings for context to avoid cross-call duplication, but
 * is asked to assign compounds to only ONE specific meaning per call.
 *
 * Usage:
 *   node compound-verbs/assign-examples.mjs 出す
 *   node compound-verbs/assign-examples.mjs 出す --dry-run
 *   node compound-verbs/assign-examples.mjs 出す --model claude-haiku-4-5-20251001
 *
 * Input:
 *   compound-verbs/survey/<v2>.json              (from survey.mjs)
 *   compound-verbs/clusters/<v2>-meanings.json   (from cluster-meanings.mjs)
 *
 * Output per meaning call:
 *   compound-verbs/clusters/<v2>-assignments-<timestamp>-<model>-<index>.txt
 *     (flags + prompt + raw response, one file per LLM call)
 *
 * Final canonical output:
 *   compound-verbs/clusters/<v2>-assignments.json
 *     (object keyed by verbatim meaning string → array of headword strings)
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

// --- Frequency trimming: top ~90% by cumulative frequency, or top 100, whichever includes more ---
// Pass 2 uses broader coverage than Pass 1 (90%/100 vs 75%/50) so the lexicalized
// tail has more candidates to fall out from — compounds not assigned to any meaning
// in Pass 2 become the opaque/lexicalized sense in Pass 3.

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

// --- Build the set of known headwords for hallucination detection ---

const knownHeadwords = new Set(trimmed.map((e) => e.headword));

// --- Prepare shared prompt components ---

const headwordList = trimmed.map((e) => e.headword).join("、");

const meaningsBlock = meanings
  .map((m, i) => `  ${i + 1}. "${m.meaning}"`)
  .join("\n");

// --- Output directory setup ---

const clustersDir = join(__dirname, "clusters");
mkdirSync(clustersDir, { recursive: true });

const isoString = new Date().toISOString();
const timestamp = isoString.replace(/[:.]/g, "-").replace("T", "_").replace("Z", "");
const canonicalPath = join(clustersDir, `${v2}-assignments.json`);

// --- Process each meaning ---

const client = dryRun ? null : new Anthropic();
const assignments = {}; // meaning string → array of headword strings

for (let i = 0; i < meanings.length; i++) {
  const targetMeaning = meanings[i].meaning;

  const prompt = `You are helping a Japanese learner understand the suffix -${v2} in compound verbs.

-${v2} has these distinct meanings when appended to a verb:
${meaningsBlock}

Your task: from the list of compounds below, identify only those that clearly exemplify meaning ${i + 1}: "${targetMeaning}"

Rules:
- Include only clear, prototypical examples where the suffix carries this meaning.
- If a compound better fits a different meaning (${meanings.filter((_, j) => j !== i).map((m, j) => `meaning ${j < i ? j + 1 : j + 2}: "${m.meaning}"`).join("; ")}), skip it here — it will be captured in that meaning's call.
- If a compound is opaque or lexicalized (its meaning cannot be predicted from its parts), skip it entirely — do not assign it to any meaning.
- When uncertain, leave it out.

Compounds ending in -${v2} (${trimmed.length} most common, sorted by corpus frequency):
${headwordList}

Remember: you are only assigning compounds to meaning ${i + 1}: "${targetMeaning}"

Think through the patterns briefly, then end your response with a JSON array of matching headword strings (use the exact kanji forms above). If none clearly fit, return an empty array [].`;

  if (dryRun) {
    console.log(`\n========== [DRY RUN] Prompt for meaning ${i + 1}/${meanings.length} ==========\n`);
    console.log(prompt);
    console.log(`\n========== End of prompt for meaning ${i + 1} ==========\n`);
    continue;
  }

  console.log(`\nCalling ${model} for meaning ${i + 1}/${meanings.length}: "${targetMeaning}"...`);

  const message = await client.messages.create({
    model,
    max_tokens: 2048,
    messages: [{ role: "user", content: prompt }],
  });

  const responseText = message.content[0].text.trim();

  // --- Write archive .txt for this call ---

  const archiveTxtPath = join(
    clustersDir,
    `${v2}-assignments-${timestamp}-${model}-${i + 1}.txt`
  );

  const flagsSummary = [
    `suffix: ${v2}`,
    `model: ${model}`,
    `meaning-index: ${i + 1} of ${meanings.length}`,
    `meaning: ${targetMeaning}`,
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

  // --- Parse JSON array from response ---
  // The model reasons before the JSON array, so extract the last [...] block.

  let parsed;
  try {
    const allArrayLineMatches = [...responseText.matchAll(/^\s*\[/gm)];
    const lastArrayStart = allArrayLineMatches.at(-1);
    const jsonText = lastArrayStart
      ? responseText.slice(lastArrayStart.index).replace(/\n?```$/, "").trim()
      : responseText.replace(/^```(?:json)?\n?/i, "").replace(/\n?```$/, "").trim();
    parsed = JSON.parse(jsonText);
  } catch (err) {
    console.error(`ERROR: Could not parse LLM response as JSON for meaning ${i + 1}.`);
    console.error(`Raw response saved to: ${archiveTxtPath}`);
    console.error("Skipping this meaning — re-run to retry.");
    continue;
  }

  if (!Array.isArray(parsed)) {
    console.error(`ERROR: LLM returned a non-array for meaning ${i + 1}. Skipping.`);
    console.error(`Raw response saved to: ${archiveTxtPath}`);
    continue;
  }

  // --- Validate headwords; warn loudly on hallucinations ---

  const valid = [];
  for (const headword of parsed) {
    if (typeof headword !== "string") {
      console.warn(`WARNING: Non-string entry in LLM response for meaning ${i + 1}: ${JSON.stringify(headword)} — skipping`);
      continue;
    }
    if (!knownHeadwords.has(headword)) {
      console.warn(`WARNING: LLM hallucinated headword "${headword}" for meaning ${i + 1} — not in survey, skipping`);
      continue;
    }
    valid.push(headword);
  }

  assignments[targetMeaning] = valid;
  console.log(`  → ${valid.length} compound(s) assigned: ${valid.join("、") || "(none)"}`);
}

if (dryRun) {
  console.log(`\nDry run complete. ${meanings.length} prompt(s) shown. No LLM calls made.`);
  bccwjDb.close();
  process.exit(0);
}

// --- Write canonical assignments JSON ---

writeFileSync(canonicalPath, JSON.stringify(assignments, null, 2), "utf8");

console.log(`\n✓ Assignments written to: ${canonicalPath}`);
console.log(`  ${Object.keys(assignments).length} meaning(s) processed`);
for (const [meaning, headwords] of Object.entries(assignments)) {
  console.log(`  "${meaning}": ${headwords.length} compound(s)`);
}

bccwjDb.close();
