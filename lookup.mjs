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

var lookup = process.argv[2];
if (!lookup) {
  console.error("Usage: node lookup.js <word>");
  process.exit(1);
}

var { db } = await setup("jmdict.sqlite");
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

for (const word of deduped.values()) {
  console.log(word.id, wordFormsPart(word), wordMeanings(word, true));
}
