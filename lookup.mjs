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
const BCCWJ_PATH = path.join(__dirname, "compound-verbs", "bccwj.sqlite");

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
  console.log("ID?");
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
    const stmt = bccwjDb.prepare("SELECT frequency FROM bccwj WHERE kanji = ? AND reading = ? LIMIT 1");
    getBccwjFrequency = (kanji, reading) => {
      const row = stmt.get(kanji, reading);
      return row ? row.frequency : null;
    };
  } catch (err) {
    console.error("Warning: could not open bccwj.sqlite:", err.message);
  }
}

for (const word of deduped.values()) {
  let frequencyInfo = "";

  // Look up frequency in BCCWJ if database is available
  if (getBccwjFrequency) {
    const kanji = word.kanji.filter((k) => !k.tags.includes("iK")).map((k) => k.text);
    const kana = word.kana.filter((k) => !k.tags.includes("ik")).map((k) => k.text);

    // Try each kanji form
    for (const form of kanji) {
      const freq = getBccwjFrequency(form, kana[0]);
      if (freq) {
        frequencyInfo = `freq:${freq}`;
        break;
      }
    }

    // If no kanji match, try kana forms
    if (!frequencyInfo) {
      for (const form of kana) {
        const freq = getBccwjFrequency(form, form);
        if (freq) {
          frequencyInfo = `freq:${freq}`;
          break;
        }
      }
    }
  }

  console.log(
    word.id,
    wordFormsPart(word),
    wordMeanings(word, { partOfSpeech: true, numbered: true, tags }).replace(
      /\s*\(common\) \(futsuumeishi\)/g,
      "",
    ),
    frequencyInfo,
  );
}

if (bccwjDb) bccwjDb.close();
