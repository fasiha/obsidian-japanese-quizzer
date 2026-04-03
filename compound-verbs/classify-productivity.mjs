/**
 * compound-verbs/classify-productivity.mjs
 *
 * Calls an LLM to classify each compound verb as highly-productive, medium, or fully-lexicalized.
 * Processes one compound at a time for clarity and debuggability.
 *
 * Usage:
 *   node compound-verbs/classify-productivity.mjs 立てる
 *   node compound-verbs/classify-productivity.mjs 立てる --max-compounds 3
 *   node compound-verbs/classify-productivity.mjs 立てる --dry-run
 *   node compound-verbs/classify-productivity.mjs 立てる --model claude-opus-4-6
 *
 * Requires ANTHROPIC_API_KEY in .env
 * Requires compound-verbs/nlb-cache.json to have entries for all words in the survey.
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import Anthropic from "@anthropic-ai/sdk";
import { setup, findExact } from "jmdict-simplified-node";

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

const args = process.argv.slice(2);
const v2 = args.find((a) => !a.startsWith("--"));
const dryRun = args.includes("--dry-run");
const maxCompoundsIndex = args.indexOf("--max-compounds");
const maxCompounds = maxCompoundsIndex >= 0 ? parseInt(args[maxCompoundsIndex + 1]) : Infinity;
const modelFlagIndex = args.indexOf("--model");
const modelArg = modelFlagIndex >= 0 ? args[modelFlagIndex + 1] : undefined;
const model = modelArg ?? "claude-haiku-4-5-20251001";

if (!v2) {
  console.error("Usage: node compound-verbs/classify-productivity.mjs <v2> [--dry-run] [--max-compounds N] [--model MODEL]");
  process.exit(1);
}

// Load survey file
const surveyPath = join(__dirname, "survey", `${v2}.json`);
if (!existsSync(surveyPath)) {
  console.error(`Survey file not found: ${surveyPath}`);
  console.error(`Run: node compound-verbs/survey.mjs ${v2}`);
  process.exit(1);
}
const survey = JSON.parse(readFileSync(surveyPath, "utf8"));

// Load NLB cache and check completeness
const cachePath = join(__dirname, "nlb-cache.json");
if (!existsSync(cachePath)) {
  console.error("nlb-cache.json not found. Run: node compound-verbs/fetch-nlb.mjs");
  process.exit(1);
}
const nlbCache = JSON.parse(readFileSync(cachePath, "utf8"));

const missing = survey.filter((e) => e.NLB_link && !nlbCache[e.NLB_link]);
if (missing.length > 0) {
  console.error(`Missing NLB cache entries for ${missing.length} words:`);
  for (const e of missing) console.error(`  ${e.headword} (${e.NLB_link})`);
  console.error("Run: node compound-verbs/fetch-nlb.mjs");
  process.exit(1);
}

// Set up JMDict database for v1/v2 lookups
const { db } = await setup(join(root, "jmdict.sqlite"));

// Helper to look up JMDict definitions for a word
function getJmdictDefinitions(word) {
  const results = findExact(db, word);
  if (results.length === 0) return null;
  const firstResult = results[0];
  const senses = (firstResult.sense || [])
    .map((s, i) => {
      const gloss = s.gloss && s.gloss.length > 0 ? s.gloss[0].text : "";
      return `(${i + 1}) ${gloss}`;
    })
    .filter((s) => s.length > 0);
  return senses.length > 0 ? senses : null;
}

// Ensure output directories exist
const classifyDir = join(__dirname, "classify");
const surveyOutDir = join(__dirname, "survey");
mkdirSync(classifyDir, { recursive: true });
mkdirSync(surveyOutDir, { recursive: true });

// Output file path
const outputPath = join(classifyDir, `${v2}.jsonl`);

// Build prompt for a single compound
function buildPrompt(entry) {
  const jmdictLine = entry.jmdictId
    ? `JMDict "${entry.jmdictId}" senses:\n${entry.jmdictMeanings
        .map((senses, i) => `  (${i + 1}) ${senses.join("; ")}`)
        .join("\n")}`
    : `JMDict: no match found`;

  // Look up v1 and v2 definitions
  const v1Defs = getJmdictDefinitions(entry.v1);
  const v2Defs = getJmdictDefinitions(entry.v2);

  const v1Line = v1Defs
    ? `Base verb (v1): ${entry.v1}\n  JMDict senses:\n${v1Defs.map((s) => `    ${s}`).join("\n")}`
    : `Base verb (v1): ${entry.v1}\n  JMDict: (no entry found — using base meaning from context)`;

  const v2Line = v2Defs
    ? `Suffix (v2): ${entry.v2} (${entry.v2_reading})\n  JMDict senses (standalone):\n${v2Defs.map((s) => `    ${s}`).join("\n")}\n  Note: as a suffix, its meaning often shifts to contribute intensity/emphasis.`
    : `Suffix (v2): ${entry.v2} (${entry.v2_reading})\n  JMDict: (no entry found)`;

  const ninjalSenses = entry.ninjal_senses
    .map((s, i) => {
      const rare = s.definition_en.match(/\(Rare\)/i) ? " [RARE]" : "";
      const exLine = s.example_ja ? `\n    Example: ${s.example_ja} → ${s.example_en}` : "";
      return `  Sense ${i + 1}${rare}: ${s.definition_en}${exLine}`;
    })
    .join("\n");

  const freqNote = entry.NLB_link ? `NLB frequency: ${nlbCache[entry.NLB_link]?.freq ?? 0}/100k` : "NLB frequency: unknown";

  return `You are classifying whether a Japanese compound verb is productive (compositional) or lexicalized.

Compound verb: ${entry.headword} (${entry.reading})
${v1Line}
${v2Line}
${freqNote}

Compound JMDict data:
${jmdictLine}

NINJAL Compound Verb Lexicon:
${ninjalSenses}

## Instruction

Classify this compound as one of:
- **highly-productive**: the compound's meaning is transparently compositional — a learner
  who understands the base verb and the suffix's role can predict the meaning
- **medium**: the meaning is somewhat idiomatic or the pattern is restricted to certain
  verb types, but still somewhat predictable
- **fully-lexicalized**: the compound's meaning is opaque — must be learned as a standalone
  vocabulary item; the suffix's contribution is not predictable

Note: JMDict and the VVLexicon may characterize this compound differently. This is normal
when multiple sources analyze the same word. Your task is not to reconcile them, but to
judge whether this compound follows a **predictable pattern** (base verb + suffix meaning)
or must be learned as a fixed expression.

Think through your reasoning: Does the compound's meaning follow logically from the base
verb + suffix? Is this a common, standard pattern? Or is it more of a fixed expression?

Then provide your final classification.`;
}

// Process compounds
console.log(`Processing ${survey.length} compound(s) from ${v2}...`);
if (maxCompounds < Infinity) {
  console.log(`(Limited to ${maxCompounds} LLM calls; rest will be skipped)`);
}

const results = [];
let llmCount = 0;

for (let i = 0; i < survey.length; i++) {
  const entry = survey[i];
  const prompt = buildPrompt(entry);

  if (dryRun) {
    console.log(`\n========== [DRY RUN] Compound ${i + 1}/${survey.length}: ${entry.headword} ==========\n`);
    console.log(prompt);
    console.log("\n");
    continue;
  }

  if (llmCount >= maxCompounds) {
    console.log(`[${i + 1}/${survey.length}] ${entry.headword} — skipped (--max-compounds limit reached)`);
    continue;
  }

  console.log(`[${i + 1}/${survey.length}] ${entry.headword} — calling ${model}...`);

  try {
    const client = new Anthropic();
    const message = await client.messages.create({
      model,
      max_tokens: 500,
      messages: [{ role: "user", content: prompt }],
    });

    const responseText = message.content[0].text.trim();

    // Save full response to timestamped file
    const isoString = new Date().toISOString();
    const timestamp = isoString.replace(/[:.]/g, "-").replace("T", "_");
    const reasoningFile = join(
      surveyOutDir,
      `${v2}-${entry.headword}-${timestamp}-${model}.txt`
    );
    writeFileSync(reasoningFile, responseText, "utf8");

    // Parse classification from response
    let classification = null;
    const classificationMatch = responseText.match(
      /classification\s*:?\s*(highly-productive|medium|fully-lexicalized)/i
    );
    if (classificationMatch) {
      classification = classificationMatch[1].toLowerCase();
    } else {
      // Try to infer from the text
      if (responseText.match(/highly.productive/i)) classification = "highly-productive";
      else if (responseText.match(/medium/i)) classification = "medium";
      else if (responseText.match(/fully.lexicalized|lexicalized/i)) classification = "fully-lexicalized";
    }

    if (!classification) {
      console.error(`  ERROR: Could not parse classification from response`);
      console.error(`  Response: ${responseText.substring(0, 200)}`);
      process.exit(1);
    }

    results.push({
      headword: entry.headword,
      reading: entry.reading,
      v1: entry.v1,
      classification,
      reasoning: responseText.split("\n")[0].substring(0, 120), // first line as summary
    });

    console.log(`  ✓ ${classification} (saved to ${reasoningFile})`);
    llmCount++;
  } catch (err) {
    console.error(`  ERROR: ${err.message}`);
    process.exit(1);
  }
}

// Write results to jsonl
if (!dryRun) {
  writeFileSync(
    outputPath,
    results.map((r) => JSON.stringify(r)).join("\n") + "\n",
    "utf8"
  );
  console.log(
    `\n✓ Classified ${results.length} compound(s). Output: ${outputPath}`
  );
  console.log(
    `  Reasoning files saved to: compound-verbs/survey/${v2}-*-${model}.txt`
  );

  // Summary
  const counts = {};
  for (const r of results) {
    counts[r.classification] = (counts[r.classification] ?? 0) + 1;
  }
  console.log(`\nSummary:`);
  for (const [cls, count] of Object.entries(counts)) {
    console.log(`  ${cls}: ${count}`);
  }
}
