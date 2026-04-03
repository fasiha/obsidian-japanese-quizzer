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
 * Requires BCCWJ_frequencylist_luw2_ver1_0.tsv in compound-verbs/ directory.
 */

import { readFileSync, writeFileSync, appendFileSync, existsSync, mkdirSync } from "fs";
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
const onlyFlagIndex = args.indexOf("--only");
const onlySet = onlyFlagIndex >= 0
  ? new Set(args[onlyFlagIndex + 1].split(",").map((s) => s.trim()))
  : null;

if (!v2) {
  console.error("Usage: node compound-verbs/classify-productivity.mjs <v2> [--dry-run] [--max-compounds N] [--model MODEL] [--only compound1,compound2]");
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

// Load BCCWJ frequency list (LUW v2)
const bccwjPath = join(__dirname, "BCCWJ_frequencylist_luw2_ver1_0.tsv");
if (!existsSync(bccwjPath)) {
  console.error("BCCWJ frequency list not found: BCCWJ_frequencylist_luw2_ver1_0.tsv");
  console.error("Download from: http://doi.org/10.15084/00003214");
  process.exit(1);
}

const bccwjMap = new Map();
const bccwjLines = readFileSync(bccwjPath, "utf8").trim().split("\n");
bccwjLines.forEach((line, index) => {
  if (index === 0) return; // skip header

  const parts = line.split("\t");
  if (parts.length > 6) {
    const lemma = parts[2].trim(); // column 3: lemma (actual word form)
    const frequency = parseInt(parts[6]); // column 7: raw frequency
    const pmw = parseFloat(parts[7]); // column 8: per-million-words

    if (!isNaN(frequency) && lemma.length > 0) {
      bccwjMap.set(lemma, { frequency, pmw });
    }
  }
});

console.log(`Loaded ${bccwjMap.size} entries from BCCWJ frequency list`);

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

// Build the numbered sense list used in the prompt and returned for parsing
function buildSenseList(entry) {
  const senses = [];

  if (entry.jmdictId) {
    for (const [i, glosses] of entry.jmdictMeanings.entries()) {
      senses.push({ source: "jmdict", index: i + 1, text: glosses.join("; ") });
    }
  }

  for (const [i, s] of entry.ninjal_senses.entries()) {
    const rare = s.definition_en.match(/\(Rare\)/i) ? " [RARE]" : "";
    const exLine = s.example_ja ? ` (e.g. ${s.example_ja} → ${s.example_en})` : "";
    senses.push({ source: "ninjal", index: i + 1, text: `${s.definition_en}${rare}${exLine}` });
  }

  return senses;
}

// Build prompt for a single compound
function buildPrompt(entry, senses) {
  // Look up v1 and v2 definitions
  const v1Defs = getJmdictDefinitions(entry.v1);
  const v2Defs = getJmdictDefinitions(entry.v2);

  const v1Line = v1Defs
    ? `Base verb (v1): ${entry.v1}\n  JMDict senses:\n${v1Defs.map((s) => `    ${s}`).join("\n")}`
    : `Base verb (v1): ${entry.v1}\n  JMDict: (no entry found — using base meaning from context)`;

  const v2Line = v2Defs
    ? `Suffix (v2): ${entry.v2} (${entry.v2_reading})\n  JMDict senses (standalone):\n${v2Defs.map((s) => `    ${s}`).join("\n")}\n  Note: as a suffix, its meaning often shifts to contribute intensity/emphasis.`
    : `Suffix (v2): ${entry.v2} (${entry.v2_reading})\n  JMDict: (no entry found)`;

  const bccwjData = bccwjMap.get(entry.headword);
  const freqNote = bccwjData
    ? `BCCWJ frequency: ${bccwjData.frequency} occurrences (${bccwjData.pmw.toFixed(2)} per million words)`
    : "BCCWJ frequency: not found in corpus";

  const sensesText = senses
    .map((s, i) => `  ${i + 1}. [${s.source.toUpperCase()}] ${s.text}`)
    .join("\n");

  return `You are classifying whether each sense of a Japanese compound verb is productive (compositional) or lexicalized.

Compound verb: ${entry.headword} (${entry.reading})
${v1Line}
${v2Line}
${freqNote}

All senses (JMDict and NINJAL combined):
${sensesText}

## Instruction

For each numbered sense above, classify it as one of:
- **highly-productive**: the sense is transparently compositional — a learner who understands
  the base verb and the suffix's role can predict this meaning
- **medium**: the sense is somewhat idiomatic or restricted, but still somewhat predictable
- **fully-lexicalized**: the sense is opaque — must be learned as a standalone expression;
  the suffix's contribution is not predictable for this sense

Note: JMDict and NINJAL may characterize the compound differently. Your task is not to
reconcile them, but to judge each sense independently.

Respond with one line per sense in this exact format:
  Sense 1: <highly-productive|medium|fully-lexicalized> — <one-sentence reasoning>
  Sense 2: <highly-productive|medium|fully-lexicalized> — <one-sentence reasoning>
  ...`;
}

// Filter to --only targets if specified
const filteredSurvey = onlySet ? survey.filter((e) => onlySet.has(e.headword)) : survey;
if (onlySet) {
  const notFound = [...onlySet].filter((h) => !survey.some((e) => e.headword === h));
  if (notFound.length > 0) {
    console.error(`Unknown headwords in --only: ${notFound.join(", ")}`);
    process.exit(1);
  }
  console.log(`Processing ${filteredSurvey.length} compound(s) from --only filter (${survey.length} total in survey)...`);
} else {
  console.log(`Processing ${filteredSurvey.length} compound(s) from ${v2}...`);
}
if (maxCompounds < Infinity) {
  console.log(`(Limited to ${maxCompounds} LLM calls; rest will be skipped)`);
}

const productivityRank = { "highly-productive": 2, "medium": 1, "fully-lexicalized": 0 };

// Read existing output file to know which headwords are already classified.
// Comment lines (starting with # or //) are preserved in place on append.
const alreadyDone = new Set();
if (!dryRun && existsSync(outputPath)) {
  for (const line of readFileSync(outputPath, "utf8").split("\n")) {
    if (line.startsWith("#") || line.startsWith("//") || line.trim() === "") continue;
    try { alreadyDone.add(JSON.parse(line).headword); } catch {}
  }
}

// Compounds still needing classification: filtered survey minus already-done entries
const todo = filteredSurvey.filter((e) => !alreadyDone.has(e.headword));
const toProcess = maxCompounds < Infinity ? todo.slice(0, maxCompounds) : todo;

if (!dryRun) {
  console.log(`${alreadyDone.size} already classified, ${todo.length} remaining, processing ${toProcess.length}...`);
  if (maxCompounds < Infinity && todo.length > maxCompounds) {
    console.log(`(Limited to ${maxCompounds} by --max-compounds; ${todo.length - maxCompounds} will remain after this run)`);
  }
}

let llmCount = 0;

for (let i = 0; i < (dryRun ? filteredSurvey.length : toProcess.length); i++) {
  const entry = dryRun ? filteredSurvey[i] : toProcess[i];
  const senses = buildSenseList(entry);
  const prompt = buildPrompt(entry, senses);

  if (dryRun) {
    console.log(`\n========== [DRY RUN] Compound ${i + 1}/${filteredSurvey.length}: ${entry.headword} ==========\n`);
    console.log(prompt);
    console.log("\n");
    continue;
  }

  console.log(`[${i + 1}/${toProcess.length}] ${entry.headword} — calling ${model}...`);

  try {
    const client = new Anthropic();
    const message = await client.messages.create({
      model,
      max_tokens: 800,
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

    // Parse per-sense ratings: "Sense N: <label> — <reasoning>"
    const senseRatings = [];
    for (const [j, sense] of senses.entries()) {
      const lineMatch = responseText.match(
        new RegExp(`Sense\\s+${j + 1}\\s*:\\s*(highly-productive|medium|fully-lexicalized)\\s*[—–-]\\s*(.+)`, "i")
      );
      if (lineMatch) {
        senseRatings.push({
          source: sense.source,
          source_index: sense.index,
          sense_text: sense.text,
          rating: lineMatch[1].toLowerCase(),
          reasoning: lineMatch[2].trim(),
        });
      } else {
        console.error(`  WARNING: Could not parse rating for sense ${j + 1} of ${entry.headword}`);
        senseRatings.push({
          source: sense.source,
          source_index: sense.index,
          sense_text: sense.text,
          rating: null,
          reasoning: null,
        });
      }
    }

    if (senseRatings.every((s) => s.rating === null)) {
      console.error(`  ERROR: Could not parse any sense ratings from response`);
      console.error(`  Response: ${responseText.substring(0, 200)}`);
      process.exit(1);
    }

    // Derive compound-level classification as the most productive sense rating
    const classification = senseRatings
      .map((s) => s.rating)
      .filter(Boolean)
      .sort((a, b) => productivityRank[b] - productivityRank[a])[0];

    const result = {
      headword: entry.headword,
      reading: entry.reading,
      v1: entry.v1,
      classification,
      sense_ratings: senseRatings,
    };

    // Append immediately so progress is preserved on Ctrl-C
    appendFileSync(outputPath, JSON.stringify(result) + "\n");

    console.log(`  ✓ ${classification} (saved to ${reasoningFile})`);
    llmCount++;
  } catch (err) {
    console.error(`  ERROR: ${err.message}`);
    process.exit(1);
  }
}

if (!dryRun) {
  console.log(`\n✓ Classified ${llmCount} compound(s). Output: ${outputPath}`);
  console.log(`  Reasoning files saved to: compound-verbs/survey/${v2}-*-${model}.txt`);
}
