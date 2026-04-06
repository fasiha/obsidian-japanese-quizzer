/**
 * compound-verbs/write.mjs
 *
 * Writer script for compound-verbs.json. Applies structured operations to the
 * file without requiring a full rerun of all LLM passes. Called by
 * select-examples.mjs and usable directly by hand for incremental tweaks.
 *
 * Usage:
 *   node compound-verbs/write.mjs replace-entry <suffix-id> <entry-json-file>
 *   node compound-verbs/write.mjs add-example <suffix-id> <sense-index> <jmdict-id> [--source vvlexicon|pug-inferred]
 *   node compound-verbs/write.mjs move-example <suffix-id> <from-sense-index> <to-sense-index> <jmdict-id>
 *   node compound-verbs/write.mjs remove-example <suffix-id> <jmdict-id>
 *   node compound-verbs/write.mjs add-sense <suffix-id> <sense-json-file>
 *   node compound-verbs/write.mjs edit-sense-meaning <suffix-id> <sense-index> <new-meaning>
 *
 * For replace-entry and add-sense, the JSON argument is a path to a JSON file.
 * Alternatively, pass the JSON inline as a string (it will be tried as a file
 * path first; if not found, parsed directly as JSON).
 *
 * The compound-verbs.json file lives in the compound-verbs/ directory alongside
 * this script. It is created as an empty array if it does not exist yet.
 */

import { readFileSync, writeFileSync, existsSync } from "fs";
import { join, dirname, resolve } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const cvPath = join(__dirname, "compound-verbs.json");

// --- Helpers ---

function loadCv() {
  if (!existsSync(cvPath)) return [];
  return JSON.parse(readFileSync(cvPath, "utf8"));
}

function saveCv(data) {
  writeFileSync(cvPath, JSON.stringify(data, null, 2) + "\n", "utf8");
}

function findEntry(data, suffixId) {
  const idx = data.findIndex((e) => e.id === suffixId);
  return idx;
}

function requireEntry(data, suffixId) {
  const idx = findEntry(data, suffixId);
  if (idx === -1) {
    console.error(`Suffix entry not found: "${suffixId}"`);
    console.error(`Known IDs: ${data.map((e) => e.id).join(", ") || "(none)"}`);
    process.exit(1);
  }
  return idx;
}

function parseSenseIndex(raw) {
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 0) {
    console.error(`sense-index must be a non-negative integer, got: ${raw}`);
    process.exit(1);
  }
  return n;
}

function parseJmdictId(raw) {
  const s = String(raw).trim();
  if (!/^\d+$/.test(s) || s === "0") {
    console.error(`jmdict-id must be a positive integer string, got: ${raw}`);
    process.exit(1);
  }
  return s;
}

function parseJsonArg(raw) {
  // Try as a file path first, then as inline JSON.
  const resolved = resolve(process.cwd(), raw);
  if (existsSync(resolved)) {
    return JSON.parse(readFileSync(resolved, "utf8"));
  }
  try {
    return JSON.parse(raw);
  } catch {
    console.error(`Could not read as a file or parse as JSON: ${raw}`);
    process.exit(1);
  }
}

// --- Operations ---

function opReplaceEntry(args) {
  if (args.length < 2) {
    console.error("Usage: replace-entry <suffix-id> <entry-json-file>");
    process.exit(1);
  }
  const [suffixId, jsonArg] = args;
  const entry = parseJsonArg(jsonArg);

  if (typeof entry !== "object" || Array.isArray(entry) || !entry.id) {
    console.error("Entry JSON must be an object with an \"id\" field.");
    process.exit(1);
  }

  if (entry.id !== suffixId) {
    console.error(`Entry id "${entry.id}" does not match suffix-id argument "${suffixId}".`);
    process.exit(1);
  }

  const data = loadCv();
  const idx = findEntry(data, suffixId);
  if (idx === -1) {
    data.push(entry);
    saveCv(data);
    console.log(`Added new entry: ${suffixId} (${data.length} total entries)`);
  } else {
    data[idx] = entry;
    saveCv(data);
    console.log(`Replaced entry: ${suffixId}`);
  }
}

const VALID_SOURCES = ["vvlexicon", "pug-inferred"];

function opAddExample(args) {
  if (args.length < 3) {
    console.error("Usage: add-example <suffix-id> <sense-index> <jmdict-id> [--source vvlexicon|pug-inferred]");
    process.exit(1);
  }
  const sourceFlagIndex = args.indexOf("--source");
  const source = sourceFlagIndex >= 0 ? args[sourceFlagIndex + 1] : "vvlexicon";
  if (!VALID_SOURCES.includes(source)) {
    console.error(`Invalid --source "${source}". Must be one of: ${VALID_SOURCES.join(", ")}`);
    process.exit(1);
  }
  const positional = args.filter((_, i) => i !== sourceFlagIndex && i !== sourceFlagIndex + 1);
  const [suffixId, senseIndexRaw, jmdictIdRaw] = positional;
  const senseIndex = parseSenseIndex(senseIndexRaw);
  const jmdictId = parseJmdictId(jmdictIdRaw);

  const data = loadCv();
  const idx = requireEntry(data, suffixId);
  const entry = data[idx];

  if (!Array.isArray(entry.senses) || senseIndex >= entry.senses.length) {
    console.error(`sense-index ${senseIndex} out of range (entry has ${entry.senses?.length ?? 0} senses)`);
    process.exit(1);
  }

  const sense = entry.senses[senseIndex];
  if (!Array.isArray(sense.examples)) sense.examples = [];
  if (sense.examples.some((e) => e.id === jmdictId)) {
    console.log(`JMDict ID ${jmdictId} already present in sense ${senseIndex} — no change.`);
    return;
  }
  sense.examples.push({ id: jmdictId, source });
  saveCv(data);
  console.log(`Added ${jmdictId} to ${suffixId} sense[${senseIndex}] ("${sense.meaning.slice(0, 60)}…")`);
}

function opMoveExample(args) {
  if (args.length < 4) {
    console.error("Usage: move-example <suffix-id> <from-sense-index> <to-sense-index> <jmdict-id>");
    process.exit(1);
  }
  const [suffixId, fromRaw, toRaw, jmdictIdRaw] = args;
  const fromIndex = parseSenseIndex(fromRaw);
  const toIndex = parseSenseIndex(toRaw);
  const jmdictId = parseJmdictId(jmdictIdRaw);

  const data = loadCv();
  const idx = requireEntry(data, suffixId);
  const entry = data[idx];

  if (!Array.isArray(entry.senses)) {
    console.error("Entry has no senses array.");
    process.exit(1);
  }
  if (fromIndex >= entry.senses.length) {
    console.error(`from-sense-index ${fromIndex} out of range (entry has ${entry.senses.length} senses)`);
    process.exit(1);
  }
  if (toIndex >= entry.senses.length) {
    console.error(`to-sense-index ${toIndex} out of range (entry has ${entry.senses.length} senses)`);
    process.exit(1);
  }

  const fromSense = entry.senses[fromIndex];
  if (!Array.isArray(fromSense.examples)) fromSense.examples = [];
  const pos = fromSense.examples.findIndex((e) => e.id === jmdictId);
  if (pos === -1) {
    console.error(`JMDict ID ${jmdictId} not found in sense ${fromIndex}.`);
    process.exit(1);
  }
  const [movedExample] = fromSense.examples.splice(pos, 1);

  const toSense = entry.senses[toIndex];
  if (!Array.isArray(toSense.examples)) toSense.examples = [];
  if (!toSense.examples.some((e) => e.id === jmdictId)) {
    toSense.examples.push(movedExample);
  }

  saveCv(data);
  console.log(`Moved ${jmdictId} in ${suffixId}: sense[${fromIndex}] → sense[${toIndex}]`);
}

function opRemoveExample(args) {
  if (args.length < 2) {
    console.error("Usage: remove-example <suffix-id> <jmdict-id>");
    process.exit(1);
  }
  const [suffixId, jmdictIdRaw] = args;
  const jmdictId = parseJmdictId(jmdictIdRaw);

  const data = loadCv();
  const idx = requireEntry(data, suffixId);
  const entry = data[idx];

  let removed = false;
  for (let si = 0; si < (entry.senses?.length ?? 0); si++) {
    const sense = entry.senses[si];
    if (!Array.isArray(sense.examples)) continue;
    const pos = sense.examples.findIndex((e) => e.id === jmdictId);
    if (pos !== -1) {
      sense.examples.splice(pos, 1);
      console.log(`Removed ${jmdictId} from ${suffixId} sense[${si}] ("${sense.meaning.slice(0, 60)}…")`);
      removed = true;
    }
  }

  if (!removed) {
    console.log(`JMDict ID ${jmdictId} not found in any sense of ${suffixId} — no change.`);
    return;
  }
  saveCv(data);
}

function opAddSense(args) {
  if (args.length < 2) {
    console.error("Usage: add-sense <suffix-id> <sense-json-file>");
    process.exit(1);
  }
  const [suffixId, jsonArg] = args;
  const sense = parseJsonArg(jsonArg);

  if (typeof sense !== "object" || Array.isArray(sense) || typeof sense.meaning !== "string") {
    console.error("Sense JSON must be an object with a \"meaning\" string field.");
    process.exit(1);
  }

  const data = loadCv();
  const idx = requireEntry(data, suffixId);
  const entry = data[idx];

  if (!Array.isArray(entry.senses)) entry.senses = [];
  entry.senses.push(sense);
  saveCv(data);
  console.log(`Added sense[${entry.senses.length - 1}] to ${suffixId}: "${sense.meaning.slice(0, 60)}…"`);
}

function opEditSenseMeaning(args) {
  if (args.length < 3) {
    console.error("Usage: edit-sense-meaning <suffix-id> <sense-index> <new-meaning>");
    process.exit(1);
  }
  const [suffixId, senseIndexRaw, ...meaningParts] = args;
  const senseIndex = parseSenseIndex(senseIndexRaw);
  const newMeaning = meaningParts.join(" ");

  const data = loadCv();
  const idx = requireEntry(data, suffixId);
  const entry = data[idx];

  if (!Array.isArray(entry.senses) || senseIndex >= entry.senses.length) {
    console.error(`sense-index ${senseIndex} out of range (entry has ${entry.senses?.length ?? 0} senses)`);
    process.exit(1);
  }

  const oldMeaning = entry.senses[senseIndex].meaning;
  entry.senses[senseIndex].meaning = newMeaning;
  saveCv(data);
  console.log(`Updated ${suffixId} sense[${senseIndex}]:`);
  console.log(`  old: "${oldMeaning}"`);
  console.log(`  new: "${newMeaning}"`);
}

// --- Dispatch ---

const args = process.argv.slice(2);
const operation = args[0];
const opArgs = args.slice(1);

const OPERATIONS = {
  "replace-entry": opReplaceEntry,
  "add-example": opAddExample,
  "move-example": opMoveExample,
  "remove-example": opRemoveExample,
  "add-sense": opAddSense,
  "edit-sense-meaning": opEditSenseMeaning,
};

if (!operation || !OPERATIONS[operation]) {
  console.error("Usage: node compound-verbs/write.mjs <operation> [args...]");
  console.error("");
  console.error("Operations:");
  for (const op of Object.keys(OPERATIONS)) {
    console.error(`  ${op}`);
  }
  process.exit(1);
}

OPERATIONS[operation](opArgs);
