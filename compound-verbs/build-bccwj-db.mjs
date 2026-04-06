// Converts BCCWJ_frequencylist_luw2_ver1_0.tsv to bccwj.sqlite
// Table: bccwj(kanji TEXT, reading TEXT, frequency INTEGER, pos TEXT)
// Index on (kanji, reading) and (pos) for fast lookups.
//
// "kanji" is the lemma column (may be kana-only for some entries).
// "reading" is lForm normalized from katakana to hiragana.
// Usage: node build-bccwj-db.mjs

import Database from 'better-sqlite3';
import { createReadStream } from 'fs';
import { createInterface } from 'readline';

const TSV = 'BCCWJ_frequencylist_luw2_ver1_0.tsv';
const DB  = 'bccwj.sqlite';

function toHiragana(s) {
  return s.replace(/[\u30A1-\u30F6]/g, c => String.fromCharCode(c.charCodeAt(0) - 0x60));
}

const db = new Database(DB);
db.exec(`
  DROP TABLE IF EXISTS bccwj;
  CREATE TABLE bccwj (
    kanji     TEXT NOT NULL,
    reading   TEXT NOT NULL,
    frequency INTEGER NOT NULL,
    pos       TEXT NOT NULL
  );
`);

const insert = db.prepare('INSERT INTO bccwj (kanji, reading, frequency, pos) VALUES (?, ?, ?, ?)');

const rl = createInterface({ input: createReadStream(TSV), crlfDelay: Infinity });
let headers = null;
let count = 0;

const insertMany = db.transaction((rows) => {
  for (const row of rows) insert.run(row);
});

let batch = [];
const BATCH_SIZE = 1000;

for await (const line of rl) {
  if (!headers) { headers = line.split('\t'); continue; }
  const cols = line.split('\t');
  const lemma = cols[headers.indexOf('lemma')];
  const lForm = cols[headers.indexOf('lForm')];
  const pos = cols[headers.indexOf('pos')];
  const frequency = parseInt(cols[headers.indexOf('frequency')], 10);
  batch.push([lemma, toHiragana(lForm), frequency, pos]);
  if (batch.length >= BATCH_SIZE) { insertMany(batch); count += batch.length; batch = []; }
}
if (batch.length) { insertMany(batch); count += batch.length; }

db.exec(`
  CREATE INDEX bccwj_kanji   ON bccwj (kanji);
  CREATE INDEX bccwj_reading ON bccwj (reading);
  CREATE INDEX bccwj_pos     ON bccwj (pos);
`);

db.close();
console.log(`Wrote ${count} rows to ${DB}`);
