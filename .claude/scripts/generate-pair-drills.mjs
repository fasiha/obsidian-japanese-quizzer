/**
 * generate-pair-drills.mjs
 *
 * Generates drill sentence pairs for transitive-intransitive verb pairs
 * using the Anthropic API, one pair at a time.
 *
 *   node generate-pair-drills.mjs --generate [--limit N] [--model MODEL]
 *     Generates drills for the next N unambiguous pairs that lack drills.
 *     Default limit is 10. Writes results directly into transitive-pairs.json
 *     after each successful pair.
 *
 *   node generate-pair-drills.mjs --status
 *     Prints how many pairs have drills vs need them.
 *
 *   node generate-pair-drills.mjs --write
 *     Reads JSON from stdin and merges (kept for manual/bulk use).
 *
 * Requires ANTHROPIC_API_KEY in .env (loaded via dotenv).
 */

import { readFileSync, writeFileSync, readdirSync, unlinkSync } from "fs";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";
import Anthropic from "@anthropic-ai/sdk";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(__dirname, "../..");
const PAIRS_PATH = resolve(PROJECT_ROOT, "transitive-intransitive/transitive-pairs.json");
const ALL_PAIRS_PATH = resolve(PROJECT_ROOT, "transitive-intransitive/all-transitive-pairs.json");

// Load .env manually (no dotenv dependency)
try {
  const envFile = readFileSync(resolve(PROJECT_ROOT, ".env"), "utf8");
  for (const line of envFile.split("\n")) {
    const match = line.match(/^\s*([^#=]+?)\s*=\s*(.*?)\s*$/);
    if (match && !process.env[match[1]]) process.env[match[1]] = match[2];
  }
} catch {};

function loadPairs() {
  return JSON.parse(readFileSync(PAIRS_PATH, "utf8"));
}

function savePairs(pairs) {
  writeFileSync(PAIRS_PATH, JSON.stringify(pairs, null, 2) + "\n", "utf8");
}

function needsDrills(pair) {
  return pair.ambiguousReason === null && !pair.drills;
}

function pairLabel(p) {
  const intK = p.intransitive.kanji.length ? p.intransitive.kanji[0] : p.intransitive.kana;
  const traK = p.transitive.kanji.length ? p.transitive.kanji[0] : p.transitive.kana;
  return `${intK}(${p.intransitive.kana}) / ${traK}(${p.transitive.kana})`;
}

// ── --status ──────────────────────────────────────────────────────────
function status() {
  const pairs = loadPairs();
  const unambiguous = pairs.filter((p) => p.ambiguousReason === null);
  const withDrills = unambiguous.filter((p) => p.drills);
  const remaining = unambiguous.filter((p) => !p.drills);
  console.log(`Total pairs: ${pairs.length}`);
  console.log(`Unambiguous: ${unambiguous.length}`);
  console.log(`With drills: ${withDrills.length}`);
  console.log(`Remaining:   ${remaining.length}`);
}

// ── prompt for one pair ───────────────────────────────────────────────
function buildPrompt(pair) {
  const intKanji = pair.intransitive.kanji.length ? pair.intransitive.kanji[0] : pair.intransitive.kana;
  const traKanji = pair.transitive.kanji.length ? pair.transitive.kanji[0] : pair.transitive.kana;

  return `Generate 3 drill sets for this Japanese transitive/intransitive verb pair.

**The pair:**
- Intransitive: ${intKanji} (${pair.intransitive.kana}) — ${pair.examples?.intransitive || "(no example)"}
- Transitive: ${traKanji} (${pair.transitive.kana}) — ${pair.examples?.transitive || "(no example)"}

**Each drill set** has 4 sentences: an English intransitive sentence, its Japanese translation, an English transitive sentence that **continues the story**, and its Japanese translation.

**Rules:**
- Each drill set is a **two-sentence mini story**. The first sentence (intransitive) describes something happening on its own. The second sentence (transitive) continues the narrative with someone deliberately acting. They must be clearly linked — same scene, same moment — but tell different parts of the story.
  - GOOD: "The vase fell off the shelf." / "The cat knocked the other vase off too." (one event leads to the next)
  - GOOD: "The door opened by itself." / "So she opened all the other doors to check." (reaction)
  - BAD: "The window broke." / "The kid broke the window." (same event restated, not a continuation)
  - BAD: "The temperature rose." / "Please raise your hand." (completely unrelated)
- If the verbs have multiple senses, pick the sense where the transitive/intransitive relationship is clearest.
- English sentences: short (under 12 words), concrete, vivid, everyday.
- The 3 drill sets should use **different scenarios** (different nouns/settings).
- Japanese: natural, no furigana, no romaji. Use が for intransitive subjects, を for transitive objects.
- Vary conjugations across drills (た, ている, てください, dictionary form, etc.).

**Output** a JSON array of exactly 3 objects:
[
  {
    "intransitive": { "en": "...", "ja": "..." },
    "transitive": { "en": "...", "ja": "..." }
  },
  ...
]

Return ONLY the JSON array.`;
}

function parseDrills(text) {
  let jsonStr = text.trim();
  // Strip markdown fences if present
  const fenceMatch = jsonStr.match(/```(?:json)?\s*\n([\s\S]*?)\n```/);
  if (fenceMatch) jsonStr = fenceMatch[1];

  const drills = JSON.parse(jsonStr);
  if (!Array.isArray(drills) || drills.length !== 3) {
    throw new Error(`Expected array of 3, got ${Array.isArray(drills) ? drills.length : typeof drills}`);
  }
  for (const drill of drills) {
    for (const side of ["intransitive", "transitive"]) {
      if (!drill[side]?.en || !drill[side]?.ja) {
        throw new Error(`Missing ${side}.en or ${side}.ja`);
      }
    }
  }
  return drills;
}

// ── --generate ────────────────────────────────────────────────────────
async function generate(limit, model) {
  const client = new Anthropic();
  const pairs = loadPairs();
  const todo = [];
  for (let i = 0; i < pairs.length; i++) {
    if (needsDrills(pairs[i])) todo.push(i);
    if (todo.length >= limit) break;
  }

  if (todo.length === 0) {
    console.log("All unambiguous pairs already have drills.");
    return;
  }

  console.log(`Generating drills for ${todo.length} pairs using ${model}...\n`);

  let success = 0;
  let failures = 0;
  for (const idx of todo) {
    const pair = pairs[idx];
    const label = pairLabel(pair);
    process.stdout.write(`  ${label} ... `);

    try {
      const response = await client.messages.create({
        model,
        max_tokens: 1024,
        messages: [{ role: "user", content: buildPrompt(pair) }],
      });

      const text = response.content[0].text;
      const drills = parseDrills(text);
      pairs[idx].drills = drills;
      savePairs(pairs); // save after each so progress isn't lost
      success++;
      console.log("ok");
    } catch (e) {
      failures++;
      console.log(`FAILED: ${e.message}`);
    }
  }

  console.log(`\nDone: ${success} generated, ${failures} failed.`);
  const unambiguous = pairs.filter((p) => p.ambiguousReason === null);
  const withDrills = unambiguous.filter((p) => p.drills);
  console.log(`Progress: ${withDrills.length}/${unambiguous.length} unambiguous pairs have drills.`);
}

// ── --write (stdin bulk merge, kept for manual use) ───────────────────
function write() {
  const input = readFileSync("/dev/stdin", "utf8").trim();
  let jsonStr = input;
  const fenceMatch = jsonStr.match(/```(?:json)?\s*\n([\s\S]*?)\n```/);
  if (fenceMatch) jsonStr = fenceMatch[1];

  let drillData;
  try {
    drillData = JSON.parse(jsonStr);
  } catch (e) {
    console.error("Failed to parse JSON from stdin:", e.message);
    process.exit(1);
  }

  if (!Array.isArray(drillData)) {
    console.error("Expected a JSON array, got:", typeof drillData);
    process.exit(1);
  }

  const pairs = loadPairs();
  const pairIndex = new Map();
  for (let i = 0; i < pairs.length; i++) {
    const id = `${pairs[i].intransitive.jmdictId}-${pairs[i].transitive.jmdictId}`;
    if (!pairIndex.has(id)) pairIndex.set(id, []);
    pairIndex.get(id).push(i);
  }

  let merged = 0;
  let skippedAmbiguous = 0;
  let errors = 0;
  for (const entry of drillData) {
    const indices = pairIndex.get(entry.pairId);
    if (!indices) {
      console.error(`Unknown pairId: ${entry.pairId}`);
      errors++;
      continue;
    }

    if (!Array.isArray(entry.drills) || entry.drills.length !== 3) {
      console.error(`pairId ${entry.pairId}: expected 3 drills, got ${entry.drills?.length}`);
      errors++;
      continue;
    }

    let valid = true;
    for (const drill of entry.drills) {
      for (const side of ["intransitive", "transitive"]) {
        if (!drill[side]?.en || !drill[side]?.ja) {
          console.error(`pairId ${entry.pairId}: missing ${side}.en or ${side}.ja in a drill`);
          valid = false;
        }
      }
    }
    if (!valid) { errors++; continue; }

    for (const idx of indices) {
      if (pairs[idx].ambiguousReason !== null) { skippedAmbiguous++; continue; }
      pairs[idx].drills = entry.drills;
      merged++;
    }
  }

  if (skippedAmbiguous > 0) console.log(`Skipped ${skippedAmbiguous} ambiguous entries.`);
  savePairs(pairs);
  console.log(`Merged drills for ${merged} pairs. Errors: ${errors}.`);
  const unambiguous = pairs.filter((p) => p.ambiguousReason === null);
  const withDrills = unambiguous.filter((p) => p.drills);
  console.log(`Progress: ${withDrills.length}/${unambiguous.length} unambiguous pairs have drills.`);
}

// ── --prompt-for PAIR_ID ──────────────────────────────────────────────
function promptFor(pairId) {
  // Search curated list first, then fall back to candidate pool
  const curated = loadPairs();
  const allPairs = JSON.parse(readFileSync(ALL_PAIRS_PATH, "utf8"));
  const pair =
    curated.find((p) => `${p.intransitive.jmdictId}-${p.transitive.jmdictId}` === pairId) ||
    allPairs.find((p) => `${p.intransitive.jmdictId}-${p.transitive.jmdictId}` === pairId);
  if (!pair) {
    console.error(`Unknown pairId: ${pairId} (searched transitive-pairs.json and all-transitive-pairs.json)`);
    process.exit(1);
  }
  console.log(buildPrompt(pair));
}

// ── --needs-drills [--limit N] ───────────────────────────────────────
function needsDrillsList(limit) {
  const pairs = loadPairs();
  const todo = pairs.filter(needsDrills).slice(0, limit);
  for (const p of todo) {
    const id = `${p.intransitive.jmdictId}-${p.transitive.jmdictId}`;
    const label = pairLabel(p);
    console.log(`${id}\t${label}`);
  }
}

// ── --merge-tmp ──────────────────────────────────────────────────────
function mergeTmpFiles() {
  const tmpFiles = readdirSync("/tmp").filter((f) => f.startsWith("drill-") && f.endsWith(".json"));

  if (tmpFiles.length === 0) {
    console.log("No /tmp/drill-*.json files found.");
    return;
  }

  const pairs = loadPairs();
  const allPairs = JSON.parse(readFileSync(ALL_PAIRS_PATH, "utf8"));

  function buildIndex(arr) {
    const index = new Map();
    for (let i = 0; i < arr.length; i++) {
      const id = `${arr[i].intransitive.jmdictId}-${arr[i].transitive.jmdictId}`;
      if (!index.has(id)) index.set(id, []);
      index.get(id).push(i);
    }
    return index;
  }
  const pairIndex = buildIndex(pairs);
  const allPairIndex = buildIndex(allPairs);

  let merged = 0;
  let mergedIntoAll = 0;
  let skippedAmbiguous = 0;
  let errors = 0;

  for (const file of tmpFiles) {
    const pairId = file.replace("drill-", "").replace(".json", "");

    let drills;
    try {
      let text = readFileSync(`/tmp/${file}`, "utf8").trim();
      // Strip markdown fences
      const fenceMatch = text.match(/```(?:json)?\s*\n([\s\S]*?)\n```/);
      if (fenceMatch) text = fenceMatch[1];
      drills = JSON.parse(text);
    } catch (e) {
      console.error(`Failed to parse ${file}: ${e.message}`);
      errors++;
      continue;
    }

    if (!Array.isArray(drills) || drills.length !== 3) {
      console.error(`${file}: expected array of 3, got ${Array.isArray(drills) ? drills.length : typeof drills}`);
      errors++;
      continue;
    }

    let valid = true;
    for (const drill of drills) {
      for (const side of ["intransitive", "transitive"]) {
        if (!drill[side]?.en || !drill[side]?.ja) {
          console.error(`${file}: missing ${side}.en or ${side}.ja`);
          valid = false;
        }
      }
    }
    if (!valid) { errors++; continue; }

    // Write to curated transitive-pairs.json if found there
    const indices = pairIndex.get(pairId);
    if (indices) {
      for (const idx of indices) {
        if (pairs[idx].ambiguousReason !== null) { skippedAmbiguous++; continue; }
        pairs[idx].drills = drills;
        merged++;
      }
    }

    // Also write to all-transitive-pairs.json so add-pair.mjs can find the drills
    const allIndices = allPairIndex.get(pairId);
    if (allIndices) {
      for (const idx of allIndices) {
        if (allPairs[idx].ambiguousReason !== null) { skippedAmbiguous++; continue; }
        allPairs[idx].drills = drills;
        mergedIntoAll++;
      }
    }

    if (!indices && !allIndices) {
      console.error(`Unknown pairId from file ${file}: ${pairId}`);
      errors++;
    }
  }

  if (skippedAmbiguous > 0) console.log(`Skipped ${skippedAmbiguous} ambiguous entries.`);
  savePairs(pairs);
  writeFileSync(ALL_PAIRS_PATH, JSON.stringify(allPairs, null, 2) + "\n", "utf8");
  console.log(`Merged drills into transitive-pairs.json: ${merged}, into all-transitive-pairs.json: ${mergedIntoAll}. Errors: ${errors}. (${tmpFiles.length} files found)`);

  // Clean up merged files
  for (const file of tmpFiles) {
    try { unlinkSync(`/tmp/${file}`); } catch {}
  }
  console.log(`Cleaned up ${tmpFiles.length} tmp files.`);

  const unambiguous = pairs.filter((p) => p.ambiguousReason === null);
  const withDrills = unambiguous.filter((p) => p.drills);
  console.log(`Curated progress: ${withDrills.length}/${unambiguous.length} unambiguous pairs have drills.`);
}

// ── --dump-drills [--batch N] [--batch-size M] ────────────────────────
function dumpDrills(batchNum, batchSize) {
  const pairs = loadPairs();
  const withDrills = pairs.filter((p) => p.ambiguousReason === null && p.drills);

  if (batchNum !== null) {
    const start = batchNum * batchSize;
    const slice = withDrills.slice(start, start + batchSize);
    if (slice.length === 0) {
      console.error(`Batch ${batchNum} is empty (only ${withDrills.length} pairs with drills, batch size ${batchSize}).`);
      process.exit(1);
    }
    console.log(formatBatch(slice));
    console.error(`Batch ${batchNum}: pairs ${start + 1}–${start + slice.length} of ${withDrills.length}`);
  } else {
    console.log(formatBatch(withDrills));
    console.error(`All ${withDrills.length} pairs dumped.`);
  }
}

function formatBatch(pairsSlice) {
  const items = [];
  for (const p of pairsSlice) {
    const id = `${p.intransitive.jmdictId}-${p.transitive.jmdictId}`;
    const intK = p.intransitive.kanji?.[0] || p.intransitive.kana;
    const traK = p.transitive.kanji?.[0] || p.transitive.kana;
    const sets = p.drills.map((d, i) => ({
      set: i + 1,
      intr_ja: d.intransitive.ja,
      intr_en: d.intransitive.en,
      tr_ja: d.transitive.ja,
      tr_en: d.transitive.en,
    }));
    items.push({ pairId: id, pair: `${intK}(${p.intransitive.kana}) / ${traK}(${p.transitive.kana})`, sets });
  }
  return JSON.stringify(items, null, 2);
}

// ── --review-drills [--batch-size M] ──────────────────────────────────
async function reviewDrills(batchSize) {
  const client = new Anthropic();
  const pairs = loadPairs();
  const withDrills = pairs.filter((p) => p.ambiguousReason === null && p.drills);
  const totalBatches = Math.ceil(withDrills.length / batchSize);

  console.log(`Reviewing ${withDrills.length} pairs in ${totalBatches} batches of ${batchSize}...\n`);

  const allSuggestions = [];

  for (let b = 0; b < totalBatches; b++) {
    const slice = withDrills.slice(b * batchSize, (b + 1) * batchSize);
    const batchJson = formatBatch(slice);

    process.stdout.write(`Batch ${b + 1}/${totalBatches} (${slice.length} pairs) ... `);

    try {
      const response = await client.messages.create({
        model: "claude-opus-4-6",
        max_tokens: 4096,
        messages: [
          {
            role: "user",
            content: `You are reviewing drill sentences for a Japanese transitive/intransitive verb pair quiz app.

Each item has a pairId, a verb pair, and 3 drill sets. Each drill set is a two-sentence mini story: the intransitive sentence sets a scene, the transitive sentence continues it with someone deliberately acting.

Review each drill set for these issues:
1. **Japanese errors**: unnatural phrasing, wrong particle (が for intransitive subjects, を for transitive objects), incorrect verb form, wrong kanji
2. **English errors**: awkward phrasing, mistranslation, too long (should be under 12 words)
3. **Story continuity**: the transitive sentence should continue the same scene, not restate the same event or be unrelated
4. **Wrong verb**: using a different verb than the target pair
5. **Pedagogical issues**: the contrast between intransitive/transitive isn't clear enough

Only flag genuine problems. Most drills are fine — only output suggestions for ones that need fixing.

Output a JSON array of fix objects. If nothing needs fixing, output \`[]\`.

Each fix object:
{
  "pairId": "...",
  "setIndex": 0,  // 0-based index of the drill set
  "field": "intransitive.ja" | "intransitive.en" | "transitive.ja" | "transitive.en",
  "old": "current text",
  "new": "corrected text",
  "reason": "brief explanation"
}

Return ONLY the JSON array.

Here are the drills to review:
${batchJson}`,
          },
        ],
      });

      const text = response.content[0].text;
      let suggestions;
      try {
        let jsonStr = text.trim();
        const fenceMatch = jsonStr.match(/```(?:json)?\s*\n([\s\S]*?)\n```/);
        if (fenceMatch) jsonStr = fenceMatch[1];
        suggestions = JSON.parse(jsonStr);
      } catch (e) {
        console.log(`PARSE ERROR: ${e.message}`);
        writeFileSync(`/tmp/drill-review-raw-${b}.txt`, text, "utf8");
        continue;
      }

      if (suggestions.length === 0) {
        console.log("no issues found");
      } else {
        console.log(`${suggestions.length} suggestions`);
        allSuggestions.push(...suggestions);
      }
    } catch (e) {
      console.log(`API ERROR: ${e.message}`);
    }
  }

  const outPath = "/tmp/drill-review-suggestions.json";
  writeFileSync(outPath, JSON.stringify(allSuggestions, null, 2) + "\n", "utf8");
  console.log(`\nTotal suggestions: ${allSuggestions.length}`);
  console.log(`Saved to ${outPath}`);
  console.log(`Review the file, delete any you disagree with, then run --patch-drills to apply.`);
}

// ── --patch-drills [file] ─────────────────────────────────────────────
function patchDrills(filePath) {
  const suggestionsPath = filePath || "/tmp/drill-review-suggestions.json";
  let suggestions;
  try {
    suggestions = JSON.parse(readFileSync(suggestionsPath, "utf8"));
  } catch (e) {
    console.error(`Failed to read suggestions from ${suggestionsPath}: ${e.message}`);
    process.exit(1);
  }

  if (!Array.isArray(suggestions) || suggestions.length === 0) {
    console.log("No suggestions to apply.");
    return;
  }

  const pairs = loadPairs();
  const pairIndex = new Map();
  for (let i = 0; i < pairs.length; i++) {
    const id = `${pairs[i].intransitive.jmdictId}-${pairs[i].transitive.jmdictId}`;
    pairIndex.set(id, i);
  }

  let applied = 0;
  let skipped = 0;

  for (const s of suggestions) {
    const idx = pairIndex.get(s.pairId);
    if (idx === undefined) {
      console.error(`Unknown pairId: ${s.pairId}`);
      skipped++;
      continue;
    }

    const pair = pairs[idx];
    if (!pair.drills || !pair.drills[s.setIndex]) {
      console.error(`pairId ${s.pairId}: no drill at setIndex ${s.setIndex}`);
      skipped++;
      continue;
    }

    // field is like "intransitive.ja" or "transitive.en"
    const [side, lang] = s.field.split(".");
    const drill = pair.drills[s.setIndex];
    if (!drill[side] || drill[side][lang] === undefined) {
      console.error(`pairId ${s.pairId}: invalid field ${s.field}`);
      skipped++;
      continue;
    }

    const current = drill[side][lang];
    if (s.old && current !== s.old) {
      console.error(`pairId ${s.pairId} set ${s.setIndex} ${s.field}: old value mismatch`);
      console.error(`  expected: ${s.old}`);
      console.error(`  actual:   ${current}`);
      skipped++;
      continue;
    }

    drill[side][lang] = s.new;
    applied++;
  }

  savePairs(pairs);
  console.log(`Applied ${applied} fixes, skipped ${skipped}.`);
}

// ── --add-furigana ────────────────────────────────────────────────────
async function addFurigana(baseUrl) {
  const pairs = loadPairs();

  function buildRubyHtml(tokens) {
    return tokens
      .flat()
      .map((el) => (typeof el === "string" ? el : `<ruby>${el.ruby}<rt>${el.rt}</rt></ruby>`))
      .join("");
  }

  async function fetchFurigana(sentence) {
    const url = baseUrl + encodeURIComponent(sentence);
    const res = await fetch(url);
    if (!res.ok) throw new Error(`HTTP ${res.status} for: ${sentence}`);
    const json = await res.json();
    return buildRubyHtml(json[0].furigana);
  }

  let updated = 0;
  let alreadyDone = 0;
  let noDrills = 0;

  for (const pair of pairs) {
    if (!pair.drills) { noDrills++; continue; }
    for (const drill of pair.drills) {
      for (const side of ["intransitive", "transitive"]) {
        if (drill[side].jaFurigana) { alreadyDone++; continue; }
        const sentence = drill[side].ja;
        process.stderr.write(`  ${sentence}\n`);
        drill[side].jaFurigana = await fetchFurigana(sentence);
        updated++;
      }
    }
  }

  savePairs(pairs);
  console.log(`Added furigana to ${updated} sentences. Already done: ${alreadyDone}. Pairs without drills: ${noDrills}.`);
}

// ── CLI ───────────────────────────────────────────────────────────────
const args = process.argv.slice(2);

if (args.includes("--status")) {
  status();
} else if (args.includes("--generate")) {
  const limitIdx = args.indexOf("--limit");
  const limit = limitIdx !== -1 ? parseInt(args[limitIdx + 1], 10) : 10;
  const modelIdx = args.indexOf("--model");
  const model = modelIdx !== -1 ? args[modelIdx + 1] : "claude-sonnet-4-6";
  generate(limit, model);
} else if (args.includes("--prompt-for")) {
  const idx = args.indexOf("--prompt-for");
  promptFor(args[idx + 1]);
} else if (args.includes("--needs-drills")) {
  const limitIdx = args.indexOf("--limit");
  const limit = limitIdx !== -1 ? parseInt(args[limitIdx + 1], 10) : 999;
  needsDrillsList(limit);
} else if (args.includes("--merge-tmp")) {
  mergeTmpFiles();
} else if (args.includes("--dump-drills")) {
  const batchIdx = args.indexOf("--batch");
  const batchNum = batchIdx !== -1 ? parseInt(args[batchIdx + 1], 10) : null;
  const bsIdx = args.indexOf("--batch-size");
  const batchSize = bsIdx !== -1 ? parseInt(args[bsIdx + 1], 10) : 30;
  dumpDrills(batchNum, batchSize);
} else if (args.includes("--review-drills")) {
  const bsIdx = args.indexOf("--batch-size");
  const batchSize = bsIdx !== -1 ? parseInt(args[bsIdx + 1], 10) : 30;
  reviewDrills(batchSize);
} else if (args.includes("--patch-drills")) {
  const fileIdx = args.indexOf("--patch-drills");
  const file = args[fileIdx + 1]?.startsWith("--") ? null : args[fileIdx + 1] || null;
  patchDrills(file);
} else if (args.includes("--add-furigana")) {
  const urlIdx = args.indexOf("--url");
  const baseUrl = urlIdx !== -1 ? args[urlIdx + 1] : "http://127.0.0.1:8133/api/v1/sentence/";
  addFurigana(baseUrl);
} else if (args.includes("--write")) {
  write();
} else {
  console.error("Usage:");
  console.error("  node generate-pair-drills.mjs --status");
  console.error("  node generate-pair-drills.mjs --generate [--limit N] [--model MODEL]");
  console.error("  node generate-pair-drills.mjs --add-furigana [--url URL]");
  console.error("  node generate-pair-drills.mjs --prompt-for PAIR_ID");
  console.error("  node generate-pair-drills.mjs --needs-drills [--limit N]");
  console.error("  node generate-pair-drills.mjs --merge-tmp");
  console.error("  node generate-pair-drills.mjs --dump-drills [--batch N] [--batch-size M]");
  console.error("  node generate-pair-drills.mjs --review-drills [--batch-size M]");
  console.error("  node generate-pair-drills.mjs --patch-drills [file]");
  console.error("  node generate-pair-drills.mjs --write  < drills.json");
  process.exit(1);
}
