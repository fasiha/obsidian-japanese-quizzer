import { setup, findExact } from "jmdict-simplified-node";
import { wordFormsPart, wordMeanings } from "./.claude/scripts/shared.mjs";

var lookup = process.argv[2];
if (!lookup) {
  console.error("Usage: node lookup.js <word>");
  process.exit(1);
}

var { db } = await setup("jmdict.sqlite");
var words = findExact(db, lookup);

if (words.length === 0) {
  console.error("No results found for:", lookup);
  process.exit(1);
}

const deduped = new Map(words.map((word) => [word.id, word]));

for (const word of deduped.values()) {
  console.log(wordFormsPart(word), wordMeanings(word, true));
}
