/**
 * check-compound-verbs.mjs
 *
 * Scans corpus verbs (from vocab.json) that are not yet covered by
 * compound-verbs.json, uses MeCab to detect compound verb structure, then
 * sends candidates to Haiku for sense classification. Appends newly
 * discovered compound verbs as { id, source: "pug-inferred" } entries into
 * compound-verbs.json, and marks non-compound verbs with notCompound: true
 * in vocab.json so future runs skip them.
 *
 * Exported functions:
 *   - parseMecabOutput(output) — parse MeCab tokenization output
 *   - analyzeWithMecab(kanjiForm) — detect compound verb structure
 *   - checkAndUpdateCompoundVerbs(options) — orchestrate detection and persist
 *
 * Usage (as script):
 *   node .claude/scripts/check-compound-verbs.mjs [--dry-run] [--max-llm N]
 *
 * --dry-run: prints MeCab results and LLM prompts, makes no writes and no
 *            LLM calls (does not burn tokens).
 * --max-llm N: stop after N LLM calls
 *
 * Requires ANTHROPIC_API_KEY in .env or environment.
 * Requires MeCab to be installed and on PATH.
 */

import { readFileSync, writeFileSync, renameSync, mkdirSync } from "fs";
import { spawnSync } from "child_process";
import path from "path";
import Anthropic from "@anthropic-ai/sdk";
import { idsToWords, findExactIds } from "jmdict-simplified-node";
import {
  projectRoot,
  openJmdictDb,
  wordMeanings,
} from "./shared.mjs";

// POS tags in jmdict-simplified-node that indicate verbs
const VERB_POS_PREFIXES = ["v1", "v2", "v4", "v5", "vi", "vk", "vn", "vr", "vs", "vt", "vz"];

const model = "claude-haiku-4-5-20251001";

// --- Helper functions ---

function isVerbPos(pos) {
  return VERB_POS_PREFIXES.some((prefix) => pos === prefix || pos.startsWith(prefix + "-") || pos.startsWith(prefix + "_"));
}

function getJmdictEntry(db, id) {
  const results = idsToWords(db, [id]);
  return results.length > 0 ? results[0] : null;
}

/**
 * Parse MeCab tokenization output.
 * MeCab output line format (UniDic, tab-separated):
 *   surface\treading\tpronunciation\tbase_form\tpos\tconjugation_type\tconjugation_form
 * where pos is e.g. "動詞-一般" or "動詞-非自立可能".
 * IPA dict uses comma-separated fields after the tab; we detect which format by checking
 * whether the feature string contains a tab (UniDic) or a comma (IPA).
 */
export function parseMecabOutput(output) {
  const tokens = [];
  for (const line of output.split("\n")) {
    if (line === "EOS" || line.trim() === "") continue;
    const tabIdx = line.indexOf("\t");
    if (tabIdx === -1) continue;
    const surface = line.slice(0, tabIdx);
    const features = line.slice(tabIdx + 1);

    let pos, baseForm;
    if (features.includes("\t")) {
      // UniDic tab-separated: reading, pronunciation, base_form, pos, ...
      const parts = features.split("\t");
      baseForm = parts[2] ?? surface;  // index 2 = base_form (dictionary form)
      pos = parts[3] ?? "";            // index 3 = pos (e.g. "動詞-一般")
    } else {
      // IPA dict comma-separated: POS1,POS2,...,base_form (index 6)
      const parts = features.split(",");
      pos = (parts[0] ?? "") + (parts[1] ? "-" + parts[1] : "");
      baseForm = parts[6] ?? surface;
    }

    tokens.push({ surface, pos, baseForm });
  }
  return tokens;
}

/**
 * Analyze a kanji form to detect compound verb structure.
 * Returns { isCompound: true, v1Surface, suffixBaseForm } if it is a compound verb
 * (v1: 一般, suffix: 非自立可能), otherwise { isCompound: false }.
 */
export function analyzeWithMecab(kanjiForm) {
  const result = spawnSync("mecab", [], {
    input: kanjiForm + "\n",
    encoding: "utf8",
  });
  if (result.error) {
    console.error(`MeCab error for "${kanjiForm}":`, result.error.message);
    return { isCompound: false };
  }
  const tokens = parseMecabOutput(result.stdout);
  if (tokens.length !== 2) return { isCompound: false };
  const [t1, t2] = tokens;
  if (t1.pos !== "動詞-一般") return { isCompound: false };
  if (t2.pos !== "動詞-非自立可能") return { isCompound: false };
  return { isCompound: true, v1Surface: t1.surface, v1BaseForm: t1.baseForm, suffixBaseForm: t2.baseForm };
}

/**
 * Main orchestration function: detect compound verbs and persist results.
 *
 * Options:
 *   - dryRun (boolean): if true, print what would be done but make no changes and no LLM calls
 *   - maxLlm (number): maximum number of LLM calls; defaults to Infinity
 *   - db (Database): optional pre-opened jmdict database; if not provided, opens a new connection
 */
export async function checkAndUpdateCompoundVerbs(options = {}) {
  const dryRun = options.dryRun ?? false;
  const maxLlm = options.maxLlm ?? Infinity;

  // Load .env if not in environment
  try {
    const envFile = readFileSync(path.join(projectRoot, ".env"), "utf8");
    for (const line of envFile.split("\n")) {
      const match = line.match(/^\s*([^#=]+?)\s*=\s*(.*?)\s*$/);
      if (match && !process.env[match[1]]) process.env[match[1]] = match[2];
    }
  } catch {}

  const VOCAB_PATH = path.join(projectRoot, "vocab.json");
  const CV_PATH = path.join(projectRoot, "compound-verbs", "compound-verbs.json");
  const CLUSTERS_DIR = path.join(projectRoot, "compound-verbs", "clusters");

  // Create clusters directory if needed (for archive files)
  mkdirSync(CLUSTERS_DIR, { recursive: true });

  // Load data
  const vocabData = JSON.parse(readFileSync(VOCAB_PATH, "utf8"));
  const cvData = JSON.parse(readFileSync(CV_PATH, "utf8"));
  const db = options.db ?? (await openJmdictDb());

  // --- Step 1: Build existing coverage set ---

  const coveredIds = new Set();
  const suffixIds = new Set();

  for (const entry of cvData) {
    if (entry.jmdictId) suffixIds.add(entry.jmdictId);
    for (const sense of entry.senses ?? []) {
      for (const ex of sense.examples ?? []) {
        coveredIds.add(ex.id);
      }
    }
  }

  // --- Step 2: Find candidate verbs from vocab.json ---

  const uncheckedVerbs = [];

  for (const word of vocabData.words) {
    if (word.notCompound === true) continue;
    if (coveredIds.has(word.id) || suffixIds.has(word.id)) continue;

    // Look up in JMDict to check POS
    const entry = getJmdictEntry(db, word.id);
    if (!entry) continue;

    const hasVerbPos = entry.sense.some((s) =>
      s.partOfSpeech.some(isVerbPos)
    );
    if (!hasVerbPos) continue;

    uncheckedVerbs.push({ word, entry });
  }

  console.log(`Checking ${uncheckedVerbs.length} unchecked verb(s) against MeCab...`);

  // --- Step 3: MeCab tokenization ---

  // suffix entry ID → [{ word, entry, kanjiForm, suffixBaseForm }]
  const candidatesBySuffix = new Map();
  const notCompoundIds = new Set();

  for (const { word, entry } of uncheckedVerbs) {
    // Use first kanji form, or first kana form if kana-only
    const kanjiForm =
      (entry.kanji?.[0]?.text) ?? (entry.kana?.[0]?.text);
    if (!kanjiForm) {
      notCompoundIds.add(word.id);
      continue;
    }

    const analysis = analyzeWithMecab(kanjiForm);

    if (!analysis.isCompound) {
      notCompoundIds.add(word.id);
      if (dryRun) {
        console.log(`  [not compound] ${kanjiForm} (${word.id})`);
      }
      continue;
    }

    const { suffixBaseForm, v1BaseForm } = analysis;

    // Find matching suffix entry in compound-verbs.json
    const suffixEntry = cvData.find((e) => e.kanji === suffixBaseForm);
    if (!suffixEntry) {
      console.warn(
        `Unknown suffix: ${suffixBaseForm} (from ${word.id} ${kanjiForm}) — skipped`
      );
      notCompoundIds.add(word.id);
      continue;
    }

    console.log(`  [compound] ${kanjiForm} (${word.id}) → suffix ${suffixBaseForm}`);

    if (!candidatesBySuffix.has(suffixEntry.id)) {
      candidatesBySuffix.set(suffixEntry.id, []);
    }
    candidatesBySuffix.get(suffixEntry.id).push({ word, entry, kanjiForm, v1BaseForm });
  }

  // --- Step 4 & 5: LLM classification per suffix ---

  // suffix entry id → [{ jmdictId, senseIndex | null }]
  const classifications = new Map();
  let llmCallCount = 0;
  const isoString = new Date().toISOString();
  const timestamp = isoString.replace(/[:.]/g, "-").replace("T", "_").replace("Z", "");

  for (const [suffixId, candidates] of candidatesBySuffix) {
    const suffixEntry = cvData.find((e) => e.id === suffixId);

    // Build sense descriptions — prefer specializedMeaning, fall back to meaning.
    // The last sense with meaning === "" is the lexicalized category.
    const senseLines = suffixEntry.senses.map((s, i) => {
      const desc = s.specializedMeaning || s.meaning;
      if (desc === "" || s.meaning === "") {
        return `${i}: (lexicalized — the compound's meaning cannot be predicted from the suffix alone; it must be memorized as a whole word)`;
      }
      return `${i}: ${desc}`;
    });

    const candidateLines = candidates.map(({ word, entry }) => {
      const forms = [
        ...(entry.kanji ?? []).map((k) => k.text),
        ...(entry.kana ?? []).map((k) => k.text),
      ].join(", ");
      const meanings = wordMeanings(entry);
      return `- id: ${word.id}, forms: ${forms}, meanings: ${meanings}`;
    });

    const prompt = `You are classifying Japanese compound verbs by the semantic role of their suffix.

Suffix: ${suffixEntry.kanji} (${suffixEntry.reading})

Senses (0-indexed):
${senseLines.join("\n")}

For each candidate verb below, assign the best sense index (0, 1, 2, ...) or null if you are uncertain.

Candidates:
${candidateLines.join("\n")}

Respond with a JSON object mapping each JMDict ID (as a string key) to the sense index (integer) or null.
Example: { "1234567": 0, "9876543": null }`;

    // Check if we've hit the max LLM calls
    const shouldCallLlm = !dryRun && llmCallCount < maxLlm;

    if (dryRun || !shouldCallLlm) {
      console.log(`\n========== ${dryRun ? "[DRY RUN]" : "[MAX-LLM HIT]"} Prompt for suffix ${suffixEntry.kanji} ==========\n`);
      console.log(prompt);
      console.log(`\n========== End of prompt ==========\n`);
      classifications.set(suffixId, candidates.map(({ word }) => ({ jmdictId: word.id, senseIndex: null })));
      continue;
    }

    console.log(`\nCalling ${model} for suffix ${suffixEntry.kanji} (${candidates.length} candidate(s))...`);

    const client = new Anthropic();
    const message = await client.messages.create({
      model,
      max_tokens: 1024,
      messages: [{ role: "user", content: prompt }],
    });

    const responseText = message.content[0].text.trim();
    llmCallCount++;

    // Save archive file (following pattern from assign-examples.mjs)
    const flagsSummary = [
      `suffix: ${suffixEntry.kanji}`,
      `model: ${model}`,
      `candidates-sent: ${candidates.length}`,
      `timestamp: ${isoString}`,
      `args: node .claude/scripts/check-compound-verbs.mjs ${process.argv.slice(2).join(" ")}`,
    ].join("\n");

    const archiveTxtPath = path.join(CLUSTERS_DIR, `check-compound-${suffixEntry.kanji}-${timestamp}-${model}.txt`);
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
    console.log(`  Saved to: ${path.relative(projectRoot, archiveTxtPath)}`);

    // Extract the last JSON object block from the response (model may reason first)
    // Strip markdown code blocks first
    let cleanResponse = responseText.replace(/^```(?:json)?\n?/i, "").replace(/\n?```$/, "");
    let parsed;
    try {
      const allObjectMatches = [...cleanResponse.matchAll(/\{[\s\S]*\}/gm)];
      const lastMatch = allObjectMatches.at(-1);
      const jsonText = lastMatch ? lastMatch[0] : cleanResponse;
      parsed = JSON.parse(jsonText);
    } catch {
      console.error(`ERROR: Could not parse LLM response for suffix ${suffixEntry.kanji}:`);
      console.error(responseText);
      continue;
    }

    const results = candidates.map(({ word }) => ({
      jmdictId: word.id,
      senseIndex: typeof parsed[word.id] === "number" ? parsed[word.id] : null,
    }));
    classifications.set(suffixId, results);
  }

  // --- Step 6: Persist results ---

  // Update compound-verbs.json with pug-inferred entries via write.mjs
  const writeMjs = path.join(projectRoot, "compound-verbs", "write.mjs");
  let addedCount = 0;
  let skippedNullCount = 0;
  const addedExamples = []; // Track (suffixId, jmdictId, v1BaseForm) tuples to add v1Id

  for (const [suffixId, results] of classifications) {
    const suffixEntry = cvData.find((e) => e.id === suffixId);

    for (const { jmdictId, senseIndex } of results) {
      let targetSenseIndex = senseIndex;

      if (targetSenseIndex === null) {
        // Try to find lexicalized sense (meaning === "")
        const lexIdx = suffixEntry.senses.findIndex((s) => s.meaning === "");
        if (lexIdx === -1) {
          console.warn(
            `No sense assigned and no lexicalized sense for ${jmdictId} in ${suffixId} — skipped`
          );
          skippedNullCount++;
          continue;
        }
        targetSenseIndex = lexIdx;
      }

      const sense = suffixEntry.senses[targetSenseIndex];
      if (!sense) {
        console.warn(`Sense index ${targetSenseIndex} out of range for ${suffixId} — skipped`);
        skippedNullCount++;
        continue;
      }

      if (dryRun) {
        console.log(
          `  [dry-run] Would add ${jmdictId} to ${suffixId} sense[${targetSenseIndex}] ("${sense.meaning.slice(0, 60)}")`
        );
      } else {
        // Find v1BaseForm from the candidate
        const candidateData = [...candidatesBySuffix.get(suffixId) || []]?.find(c => c.word.id === jmdictId);

        const result = spawnSync(
          process.execPath,
          [writeMjs, "add-example", suffixId, String(targetSenseIndex), jmdictId, "--source", "pug-inferred"],
          { stdio: "inherit" }
        );
        if (result.status !== 0) {
          console.error(`write.mjs failed for ${jmdictId} — skipped`);
          skippedNullCount++;
        } else {
          addedCount++;
          if (candidateData?.v1BaseForm) {
            addedExamples.push({ suffixId, jmdictId, v1BaseForm: candidateData.v1BaseForm });
          }
        }
      }
    }
  }

  // --- Step 6b: Add v1Id by looking up v1BaseForm in JMDict ---
  if (!dryRun && addedExamples.length > 0) {
    const updatedCvData = JSON.parse(readFileSync(CV_PATH, "utf8"));
    let v1IdAdded = 0;

    for (const { suffixId, jmdictId, v1BaseForm } of addedExamples) {
      if (!v1BaseForm) continue;

      const suffixEntry = updatedCvData.find((e) => e.id === suffixId);
      if (!suffixEntry) continue;

      // Look up v1BaseForm in JMDict to get its ID
      const v1Ids = findExactIds(db, [v1BaseForm]);
      if (v1Ids.length === 0) continue;

      const v1Id = v1Ids[0];

      // Find the example we just added and set its v1Id
      for (const sense of suffixEntry.senses) {
        const example = sense.examples?.find((e) => e.id === jmdictId);
        if (example) {
          example.v1Id = v1Id;
          v1IdAdded++;
          break;
        }
      }
    }

    if (v1IdAdded > 0) {
      // Atomic write: write to temp file first, then rename
      const tmpPath = CV_PATH + ".tmp";
      writeFileSync(tmpPath, JSON.stringify(updatedCvData, null, 2) + "\n", "utf8");
      renameSync(tmpPath, CV_PATH);
      console.log(`Added v1Id to ${v1IdAdded} example(s) in compound-verbs.json`);
    }
  }

  // Update vocab.json with notCompound flags
  let flaggedCount = 0;

  if (notCompoundIds.size > 0) {
    for (const word of vocabData.words) {
      if (notCompoundIds.has(word.id) && !word.notCompound) {
        word.notCompound = true;
        flaggedCount++;
      }
    }

    if (!dryRun && flaggedCount > 0) {
      // Atomic write: write to temp file first, then rename
      const tmpPath = VOCAB_PATH + ".tmp";
      writeFileSync(tmpPath, JSON.stringify(vocabData, null, 2) + "\n", "utf8");
      renameSync(tmpPath, VOCAB_PATH);
      console.log(`Flagged ${flaggedCount} non-compound verb(s) in vocab.json`);
    } else if (dryRun) {
      console.log(`\n[dry-run] Would flag ${flaggedCount} non-compound verb(s) in vocab.json`);
    }
  }

  // --- Step 7: Summary ---

  if (uncheckedVerbs.length > 0) console.log(`
=== Summary ===
Unchecked verbs examined:  ${uncheckedVerbs.length}
Compound candidates found: ${[...candidatesBySuffix.values()].reduce((n, a) => n + a.length, 0)}
Added to compound-verbs:   ${dryRun ? "(dry-run)" : addedCount}
Skipped (no sense match):  ${skippedNullCount}
Flagged as not-compound:   ${dryRun ? "(dry-run, would flag " + flaggedCount + ")" : flaggedCount}
`);

  return uncheckedVerbs.length;
}

// --- Script entry point ---

if (import.meta.url === `file://${process.argv[1]}`) {
  // Parse command-line arguments
  const args = process.argv.slice(2);
  const dryRun = args.includes("--dry-run");
  const maxLlmIndex = args.indexOf("--max-llm");
  const maxLlm = maxLlmIndex >= 0 ? parseInt(args[maxLlmIndex + 1], 10) : Infinity;

  await checkAndUpdateCompoundVerbs({ dryRun, maxLlm });
}
