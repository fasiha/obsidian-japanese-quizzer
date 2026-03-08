/**
 * wanikani-extra-radicals-validation.mjs
 *
 * Validates the three files that together form the WaniKani radical lookup system:
 *   - wanikani-kanji-graph.json
 *   - kanjidic2.sqlite
 *   - wanikani-extra-radicals.json
 *
 * Invariants checked:
 *   1. Graph: every radical listed in kanjiToRadicals values is a key in radicalToKanjis.
 *   2. Graph: every key of radicalToKanjis is a radical used by at least one kanji in
 *      kanjiToRadicals (i.e., no orphan radicals in the reverse index).
 *   3. Coverage: every radical missing from kanjidic2 has an entry in wanikani-extra-radicals.json.
 *   4. No stale: every key in wanikani-extra-radicals.json (excluding "_comment") is actually
 *      absent from kanjidic2 (i.e., it was correctly identified as needing a manual description).
 *
 * Note: IDS sequences (multi-codepoint keys starting with ⿰⿱⿸ etc.) are treated as atomic
 * by WaniKani and by this system — their internal leaf characters are not resolved further.
 *
 * Usage: node wanikani-extra-radicals-validation.mjs
 * Exit 0 = all checks passed; exit 1 = one or more failures.
 */

import Database from "better-sqlite3";
import { readFileSync } from "fs";
import path from "path";
import { fileURLToPath } from "url";

const dir = path.dirname(fileURLToPath(import.meta.url));
const root = dir; // script lives at project root

const graph = JSON.parse(readFileSync(path.join(root, "wanikani-kanji-graph.json"), "utf8"));
const extra = JSON.parse(readFileSync(path.join(root, "wanikani-extra-radicals.json"), "utf8"));
const db    = new Database(path.join(root, "kanjidic2.sqlite"), { readonly: true });
const inKanjidic = db.prepare("SELECT 1 FROM kanji WHERE literal = ?");


const extraKeys = new Set(Object.keys(extra).filter(k => k !== "_comment"));
const { kanjiToRadicals, radicalToKanjis } = graph;

let failures = 0;
function fail(msg) {
  console.error("FAIL:", msg);
  failures++;
}

// --- Check 1: every radical in kanjiToRadicals values is a key in radicalToKanjis ---
{
  const bad = [];
  for (const [kanji, rads] of Object.entries(kanjiToRadicals)) {
    for (const r of rads) {
      if (!(r in radicalToKanjis)) bad.push(`kanjiToRadicals[${kanji}] → "${r}" missing from radicalToKanjis`);
    }
  }
  if (bad.length) {
    bad.forEach(m => fail(m));
  } else {
    console.log("OK  check 1: all kanjiToRadicals values are keys in radicalToKanjis");
  }
}

// --- Check 2: every key in radicalToKanjis is used by at least one entry in kanjiToRadicals ---
{
  const usedRadicals = new Set(Object.values(kanjiToRadicals).flat());
  const orphans = Object.keys(radicalToKanjis).filter(r => !usedRadicals.has(r));
  if (orphans.length) {
    fail(`${orphans.length} radicalToKanjis keys not used by any kanjiToRadicals entry: ${JSON.stringify(orphans.slice(0, 10))}`);
  } else {
    console.log("OK  check 2: all radicalToKanjis keys are referenced in kanjiToRadicals");
  }
}

// --- Collect all unique radicals used across kanjiToRadicals ---
const allRadicals = new Set(Object.values(kanjiToRadicals).flat());

// --- Check 3: every radical missing from kanjidic2 has an entry in wanikani-extra-radicals.json ---
{
  const uncovered = [];
  for (const r of allRadicals) {
    if (!inKanjidic.get(r) && !extraKeys.has(r)) uncovered.push(r);
  }
  if (uncovered.length) {
    fail(`${uncovered.length} radical(s) missing from both kanjidic2 and wanikani-extra-radicals.json: ${JSON.stringify(uncovered)}`);
  } else {
    console.log("OK  check 3: all kanjidic2-missing radicals are covered by wanikani-extra-radicals.json");
  }
}

// --- Check 4: every key in wanikani-extra-radicals.json is absent from kanjidic2 ---
{
  const stale = [];
  for (const k of extraKeys) {
    if (inKanjidic.get(k)) stale.push(k);
  }
  if (stale.length) {
    fail(`${stale.length} wanikani-extra-radicals.json key(s) are actually present in kanjidic2 (should be removed): ${JSON.stringify(stale)}`);
  } else {
    console.log("OK  check 4: all wanikani-extra-radicals.json keys are absent from kanjidic2");
  }
}

db.close();

if (failures === 0) {
  console.log(`\nAll checks passed.`);
} else {
  console.error(`\n${failures} check(s) failed.`);
  process.exit(1);
}
