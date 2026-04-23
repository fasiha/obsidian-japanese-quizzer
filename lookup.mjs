import {
  setup,
  findExact,
  idsToWords,
  readingBeginning,
  kanjiBeginning,
  readingAnywhere,
  kanjiAnywhere,
} from "jmdict-simplified-node";
import { wordFormsPart, wordMeanings } from "./.claude/scripts/shared.mjs";
import { existsSync } from "fs";
import path from "path";
import Database from "better-sqlite3";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const BCCWJ_PATH = path.join(__dirname, "bccwj.sqlite");

var lookup = process.argv[2];
if (!lookup) {
  console.error("Usage: node lookup.js <word>");
  process.exit(1);
}

var { db, tags } = await setup("jmdict.sqlite");
var words = [];

var ids = new Set();
var mapper = (word) => {
  if (!ids.has(word.id)) {
    words.push(word);
    ids.add(word.id);
  }
};

if (lookup.match(/^[0-9]+$/)) {
  words = idsToWords(db, [lookup]);
} else if (lookup.endsWith("*")) {
  readingBeginning(db, lookup.slice(0, -1)).forEach(mapper);
  kanjiBeginning(db, lookup.slice(0, -1)).forEach(mapper);
} else if (lookup.startsWith("*")) {
  readingAnywhere(db, lookup.slice(1)).forEach(mapper);
  kanjiAnywhere(db, lookup.slice(1)).forEach(mapper);
} else {
  words = findExact(db, lookup);
}

if (words.length === 0) {
  console.error("No results found for:", lookup);
  process.exit(1);
}

const deduped = new Map(words.map((word) => [word.id, word]));

// Try to open BCCWJ database if it exists
let bccwjDb = null;
let getBccwjFrequency = null;

if (existsSync(BCCWJ_PATH)) {
  try {
    bccwjDb = new Database(BCCWJ_PATH, { readonly: true });
    const stmt = bccwjDb.prepare("SELECT pmw FROM bccwj WHERE kanji = ? AND reading = ? LIMIT 1");
    getBccwjFrequency = (kanji, reading) => {
      const row = stmt.get(kanji, reading);
      return row ? row.pmw : null;
    };
  } catch (err) {
    console.error("Warning: could not open bccwj.sqlite:", err.message);
  }
}

const results = [];

for (const word of deduped.values()) {
  let frequencyInfo = "";
  let pmw = null;

  // Look up frequency in BCCWJ if database is available
  if (getBccwjFrequency) {
    const kanji = word.kanji.filter((k) => !k.tags.includes("iK")).map((k) => k.text);
    const kana = word.kana.filter((k) => !k.tags.includes("ik")).map((k) => k.text);

    // Try each kanji form
    for (const form of kanji) {
      const result = getBccwjFrequency(form, kana[0]);
      if (result) {
        pmw = result;
        frequencyInfo = `pmw:${result}`;
        break;
      }
    }

    // If no kanji match, try kana forms
    if (!frequencyInfo) {
      for (const form of kana) {
        const result = getBccwjFrequency(form, form);
        if (result) {
          pmw = result.pmw;
          frequencyInfo = `freq:${result.frequency} pmw:${result.pmw}`;
          break;
        }
      }
    }
  }

  results.push({
    id: word.id,
    forms: wordFormsPart(word),
    meanings: wordMeanings(word, { partOfSpeech: true, numbered: true, tags }).replace(
      /\s*\(common\) \(futsuumeishi\)/g,
      "",
    ),
    frequencyInfo,
    pmw,
  });
}

// Sort by pmw descending, with no-pmw at the bottom
results.sort((a, b) => {
  if (a.pmw === null && b.pmw === null) return 0;
  if (a.pmw === null) return 1;
  if (b.pmw === null) return -1;
  return b.pmw - a.pmw;
});

for (const result of results) {
  console.log(result.id, result.forms, result.meanings, result.frequencyInfo);
}

if (bccwjDb) bccwjDb.close();
