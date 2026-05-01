#!/usr/bin/env node
// Audit bccwj-overrides.json: shows JMDict vs BCCWJ forms side-by-side.
// Usage: node .claude/scripts/verify-bccwj-overrides.mjs

import { setup, idsToWords } from "jmdict-simplified-node";
import { wordFormsPart, wordMeanings } from "./shared.mjs";
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, "..", "..");

const { db, tags } = await setup(join(root, "jmdict.sqlite"));
const overrides = JSON.parse(readFileSync(join(root, "bccwj-overrides.json"), "utf-8"));

console.log("| BCCWJ Override | JMDict ID | JMDict Form | JMDict Gloss |");
console.log("|---|-----------|-------------|-------------|");

for (const [id, override] of Object.entries(overrides.overrides)) {
  const words = idsToWords(db, [id]);
  if (words.length === 0) {
    console.log(`| ${override.kanji}【${override.reading}】 | ${id} | NOT FOUND | |`);
    continue;
  }

  const word = words[0];
  const forms = wordFormsPart(word);
  const meanings = wordMeanings(word, { partOfSpeech: true, numbered: false, tags })
    .replace(/\s*\(common\) \(futsuumeishi\)/g, "")
    .split(/\n/)[0]; // Just first sense

  console.log(`| ${override.kanji}【${override.reading}】 | ${id} | ${forms} | ${meanings} |`);
}

process.exit(0);