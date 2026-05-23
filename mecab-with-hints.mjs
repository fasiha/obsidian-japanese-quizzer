#!/usr/bin/env node
// Runs MeCab on a sentence and appends a compound-extension hint to each
// content-word line: the count of JMdict entries whose reading *starts with*
// this morpheme's dictionary-form reading and is *longer* than it.
//
// A count > 0 signals to the annotation LLM that a prefix search
// (`node lookup.mjs '{reading}*'`) may surface longer compound entries worth
// considering given the surrounding context.
//
// Usage: node mecab-with-hints.mjs "いきおいよく ぽーんと だたいた"
// Output: same tab-separated lines as MeCab, with an extra field appended to
//         content-word lines: e.g. `[compound_extensions:6]`

import { execSync } from "child_process";
import Database from "better-sqlite3";

const sentence = process.argv[2];
if (!sentence) {
  console.error("Usage: node mecab-with-hints.mjs <sentence>");
  process.exit(1);
}

const db = new Database("jmdict.sqlite", { readonly: true });
db.pragma("journal_mode = WAL");

const countExtensions = db
  .prepare(
    `SELECT COUNT(DISTINCT entry_id) FROM raws WHERE text LIKE ? AND text != ?`,
  )
  .pluck();

function katakanaToHiragana(s) {
  return s.replace(/[ァ-ヶ]/g, (c) =>
    String.fromCharCode(c.charCodeAt(0) - 0x60),
  );
}

// POS prefixes that are purely grammatical — no compound hint needed.
const SKIP_POS = ["助詞", "助動詞", "補助記号", "記号"];
const isContentWord = (pos) => !SKIP_POS.some((p) => pos.startsWith(p));

const mecabOutput = execSync(`echo ${JSON.stringify(sentence)} | mecab`, {
  encoding: "utf8",
});

for (const line of mecabOutput.split("\n")) {
  if (!line || line === "EOS") {
    if (line === "EOS") console.log(line);
    continue;
  }

  const fields = line.split("\t");
  if (fields.length < 5) {
    console.log(line);
    continue;
  }

  const pos = fields[4];
  if (!isContentWord(pos)) {
    console.log(line);
    continue;
  }

  const dictReading = katakanaToHiragana(fields[2]);
  const dictForm = fields[3];
  const readingCount = countExtensions.get(`${dictReading}%`, dictReading);
  const kanjiCount =
    dictForm !== dictReading
      ? countExtensions.get(`${dictForm}%`, dictForm)
      : 0;
  const hint =
    kanjiCount > 0
      ? `[compound_extensions: reading:${readingCount} kanji:${kanjiCount}]`
      : `[compound_extensions: reading:${readingCount}]`;
  console.log(`${line}\t${hint}`);
}
