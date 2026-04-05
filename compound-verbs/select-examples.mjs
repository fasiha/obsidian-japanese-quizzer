/**
 * compound-verbs/select-examples.mjs
 *
 * Pass 3: Reads the corrected assignments.json (after Pass 2c), the meanings
 * files, and the survey file. Builds the final suffix entry and upserts it into
 * compound-verbs.json by calling write.mjs replace-entry.
 *
 * Usage:
 *   node compound-verbs/select-examples.mjs <v2>
 *   node compound-verbs/select-examples.mjs 出す
 *   node compound-verbs/select-examples.mjs 上がる --dry-run
 *
 * Steps performed:
 *   1. Load assignments.json — keys are meaning strings (sharpened if sharpened
 *      pass was used, otherwise original), plus a special "_metadata" key.
 *   2. Load meanings.json and meanings-sharpened.json (if present). Match each
 *      assignments key to an original display string by index position. When the
 *      assignments file was built from sharpened meanings, the sharpened strings
 *      are used as keys and the original strings are retrieved by index for display.
 *   3. For each meaning, collect all assigned compounds, resolve each to its
 *      JMDict ID via the survey file, and sort by BCCWJ frequency descending.
 *   4. Derive the lexicalized set: all compounds in the survey file that appear
 *      under no meaning key in assignments.json. Resolve to JMDict IDs and sort
 *      by BCCWJ frequency descending.
 *   5. Build the suffix entry object with one sense per meaning (using the
 *      original display string as meaning text), plus a final "lexicalized" sense
 *      if any unassigned compounds had JMDict IDs.
 *   6. Compounds without JMDict IDs are excluded from all senses.
 *   7. Calls write.mjs replace-entry to upsert the entry into compound-verbs.json.
 *
 * Requires compound-verbs/bccwj.sqlite (build with: node compound-verbs/build-bccwj-db.mjs)
 */

import { readFileSync, writeFileSync, existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { spawnSync } from "child_process";
import Database from "better-sqlite3";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, "..");
const clustersDir = join(__dirname, "clusters");
const surveyDir = join(__dirname, "survey");

// --- Argument parsing ---

const args = process.argv.slice(2);
const v2 = args.find((a) => !a.startsWith("--"));
const dryRun = args.includes("--dry-run");

if (!v2) {
  console.error("Usage: node compound-verbs/select-examples.mjs <v2> [--dry-run]");
  process.exit(1);
}

// --- Load survey ---

const surveyPath = join(surveyDir, `${v2}.json`);
if (!existsSync(surveyPath)) {
  console.error(`Survey file not found: ${surveyPath}`);
  console.error(`Run: node compound-verbs/survey.mjs ${v2}`);
  process.exit(1);
}
const survey = JSON.parse(readFileSync(surveyPath, "utf8"));

// Build a map from headword string → survey entry for fast lookup.
const surveyByHeadword = new Map();
for (const entry of survey) {
  surveyByHeadword.set(entry.headword, entry);
}

// --- Load assignments ---

const assignmentsPath = join(clustersDir, `${v2}-assignments.json`);
if (!existsSync(assignmentsPath)) {
  console.error(`Assignments file not found: ${assignmentsPath}`);
  console.error(`Run: node compound-verbs/assign-examples.mjs ${v2}`);
  process.exit(1);
}

const assignments = JSON.parse(readFileSync(assignmentsPath, "utf8"));
const meaningKeys = Object.keys(assignments).filter((k) => k !== "_metadata");

if (meaningKeys.length === 0) {
  console.error(`assignments.json has no meaning keys (only _metadata): ${assignmentsPath}`);
  process.exit(1);
}

// --- Load meanings (original display strings) and sharpened strings ---

const meaningsPath = join(clustersDir, `${v2}-meanings.json`);
if (!existsSync(meaningsPath)) {
  console.error(`Meanings file not found: ${meaningsPath}`);
  console.error(`Run: node compound-verbs/cluster-meanings.mjs ${v2}`);
  process.exit(1);
}
const originalMeanings = JSON.parse(readFileSync(meaningsPath, "utf8")); // array of { meaning }

const sharpenedPath = join(clustersDir, `${v2}-meanings-sharpened.json`);
const hasSharpened = existsSync(sharpenedPath);
const sharpenedMeanings = hasSharpened
  ? JSON.parse(readFileSync(sharpenedPath, "utf8"))
  : null;

// Determine which meaning array was used as keys in assignments.json.
// The keys in assignments.json are verbatim meaning strings from whichever file
// was passed to assign-examples.mjs. When sharpened meanings exist, that file is
// used automatically. Match each key back to its original display string by index.
//
// Strategy: if all meaningKeys are found in the sharpened array by value, assume
// sharpened strings were used as keys → match by position to get original strings.
// Otherwise, assume original strings were used as keys directly.

let displayStrings; // parallel array to meaningKeys: display string for each meaning

if (hasSharpened) {
  const sharpenedStrings = sharpenedMeanings.map((m) => m.meaning);
  const allInSharpened = meaningKeys.every((k) => sharpenedStrings.includes(k));
  if (allInSharpened) {
    // Keys are sharpened strings — map each to its original by index
    displayStrings = meaningKeys.map((key) => {
      const idx = sharpenedStrings.indexOf(key);
      if (idx === -1 || idx >= originalMeanings.length) {
        // Fallback: use the sharpened string itself as display
        console.warn(`WARNING: sharpened meaning not found in original meanings by index: "${key.slice(0, 60)}…"`);
        return key;
      }
      return originalMeanings[idx].meaning;
    });
    console.log(`Using sharpened meanings as classifier keys; displaying original meaning strings.`);
  } else {
    // Some keys are not in sharpened — assume original strings used directly
    displayStrings = meaningKeys.map((k) => k);
    console.log(`Using original meanings (sharpened file exists but keys did not match it fully).`);
  }
} else {
  displayStrings = meaningKeys.map((k) => k);
  console.log(`Using original meanings (no sharpened file).`);
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

// --- Resolve compounds → JMDict IDs with frequency, sorted descending ---

function resolveAndSort(headwords) {
  const resolved = [];
  for (const hw of headwords) {
    const entry = surveyByHeadword.get(hw);
    if (!entry) {
      console.warn(`WARNING: "${hw}" not found in survey file — skipping`);
      continue;
    }
    if (!entry.jmdictId) {
      // Excluded per spec: compounds without JMDict IDs cannot be linked from the app
      continue;
    }
    resolved.push({
      jmdictId: Number(entry.jmdictId),
      frequency: getBccwjFrequency(hw),
    });
  }
  // Sort by frequency descending; ties keep original order
  resolved.sort((a, b) => b.frequency - a.frequency);
  return resolved.map((r) => r.jmdictId);
}

// --- Build senses for assigned meanings ---

// Collect all assigned headwords across all meanings so we can derive the
// lexicalized tail as the complement within the full survey.
const assignedHeadwords = new Set();
for (const key of meaningKeys) {
  const list = assignments[key];
  if (Array.isArray(list)) {
    for (const hw of list) assignedHeadwords.add(hw);
  }
}

const senses = [];

for (let i = 0; i < meaningKeys.length; i++) {
  const key = meaningKeys[i];
  const display = displayStrings[i];
  const list = assignments[key];
  if (!Array.isArray(list) || list.length === 0) {
    console.warn(`WARNING: meaning "${key.slice(0, 60)}…" has no assigned compounds — skipping sense`);
    continue;
  }
  const examples = resolveAndSort(list);
  if (examples.length === 0) {
    console.warn(`WARNING: meaning "${key.slice(0, 60)}…" had compounds but none resolved to JMDict IDs — skipping sense`);
    continue;
  }
  const sense = { meaning: display, examples };
  // Include the sharpened meaning as an optional specializedMeaning field when
  // the assignments key differs from the original display string (i.e. sharpened
  // meanings were used as classifier keys).
  if (key !== display) {
    sense.specializedMeaning = key;
  }
  senses.push(sense);
}

// --- Derive the lexicalized tail ---

const lexicalizedHeadwords = survey
  .map((e) => e.headword)
  .filter((hw) => !assignedHeadwords.has(hw));

const lexicalizedExamples = resolveAndSort(lexicalizedHeadwords);

if (lexicalizedExamples.length > 0) {
  senses.push({
    meaning: "",
    examples: lexicalizedExamples,
  });
  console.log(`Lexicalized tail: ${lexicalizedExamples.length} compounds with JMDict IDs (out of ${lexicalizedHeadwords.length} unassigned total)`);
}

bccwjDb.close();

// --- Build the suffix entry ---

// Derive the stable kebab-case ID from the v2 reading stored in assignments metadata,
// falling back to romanizing the v2 kanji if not available.
const metadata = assignments._metadata ?? {};
const v2Reading = metadata.v2_reading ?? null;

// Convert hiragana reading to simple ASCII for the ID (katakana and romaji not needed).
// Use the v2 string itself transliterated, or fall back to a slugified kanji form.
function readingToId(kanji, reading) {
  // Build a safe ASCII slug: use the reading if available, otherwise the kanji.
  // Simple hiragana → romaji table (enough for common v2 suffixes).
  const hiraganaToRomaji = {
    あ:"a",い:"i",う:"u",え:"e",お:"o",
    か:"ka",き:"ki",く:"ku",け:"ke",こ:"ko",
    さ:"sa",し:"shi",す:"su",せ:"se",そ:"so",
    た:"ta",ち:"chi",つ:"tsu",て:"te",と:"to",
    な:"na",に:"ni",ぬ:"nu",ね:"ne",の:"no",
    は:"ha",ひ:"hi",ふ:"fu",へ:"he",ほ:"ho",
    ま:"ma",み:"mi",む:"mu",め:"me",も:"mo",
    や:"ya",ゆ:"yu",よ:"yo",
    ら:"ra",り:"ri",る:"ru",れ:"re",ろ:"ro",
    わ:"wa",を:"wo",ん:"n",
    が:"ga",ぎ:"gi",ぐ:"gu",げ:"ge",ご:"go",
    ざ:"za",じ:"ji",ず:"zu",ぜ:"ze",ぞ:"zo",
    だ:"da",ぢ:"di",づ:"du",で:"de",ど:"do",
    ば:"ba",び:"bi",ぶ:"bu",べ:"be",ぼ:"bo",
    ぱ:"pa",ぴ:"pi",ぷ:"pu",ぺ:"pe",ぽ:"po",
    きゃ:"kya",きゅ:"kyu",きょ:"kyo",
    しゃ:"sha",しゅ:"shu",しょ:"sho",
    ちゃ:"cha",ちゅ:"chu",ちょ:"cho",
    にゃ:"nya",にゅ:"nyu",にょ:"nyo",
    ひゃ:"hya",ひゅ:"hyu",ひょ:"hyo",
    みゃ:"mya",みゅ:"myu",みょ:"myo",
    りゃ:"rya",りゅ:"ryu",りょ:"ryo",
    ぎゃ:"gya",ぎゅ:"gyu",ぎょ:"gyo",
    じゃ:"ja",じゅ:"ju",じょ:"jo",
    びゃ:"bya",びゅ:"byu",びょ:"byo",
    ぴゃ:"pya",ぴゅ:"pyu",ぴょ:"pyo",
  };
  if (reading) {
    // Process digraphs before monographs
    let result = reading;
    // Replace two-character sequences first
    for (const [hira, rom] of Object.entries(hiraganaToRomaji)) {
      if (hira.length === 2) result = result.split(hira).join(rom);
    }
    for (const [hira, rom] of Object.entries(hiraganaToRomaji)) {
      if (hira.length === 1) result = result.split(hira).join(rom);
    }
    // Handle long vowel mark (ー) by doubling the preceding vowel
    result = result.replace(/ー/g, "");
    // If fully ASCII now, use it
    if (/^[a-z]+$/.test(result)) return result + "-suffix";
  }
  // Fallback: strip non-ASCII and use whatever remains, or a placeholder
  const ascii = kanji.replace(/[^\x00-\x7F]/g, "");
  return (ascii || "suffix") + "-suffix";
}

// Get v2 reading from the first survey entry that matches the v2
const anyEntry = survey[0];
const detectedReading = anyEntry?.v2_reading ?? v2Reading ?? null;

const suffixId = readingToId(v2, detectedReading);

const entry = {
  id: suffixId,
  kanji: v2,
  reading: detectedReading ?? "",
  role: "suffix",
  senses,
};

console.log(`\nBuilt entry for ${v2} (id: "${suffixId}")`);
console.log(`  ${senses.length} senses:`);
for (const s of senses) {
  console.log(`    - "${s.meaning.slice(0, 70)}${s.meaning.length > 70 ? "…" : ""}" (${s.examples.length} examples)`);
}

if (dryRun) {
  console.log("\n[dry-run] Would write to compound-verbs.json:");
  console.log(JSON.stringify(entry, null, 2));
  process.exit(0);
}

// --- Call write.mjs replace-entry ---

// Pass the entry as an inline JSON string to write.mjs
const entryJson = JSON.stringify(entry);
const writeMjs = join(__dirname, "write.mjs");

const result = spawnSync(
  process.execPath,
  [writeMjs, "replace-entry", suffixId, entryJson],
  { stdio: "inherit" }
);

if (result.status !== 0) {
  console.error("write.mjs exited with an error.");
  process.exit(result.status ?? 1);
}
