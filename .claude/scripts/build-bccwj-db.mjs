#!/usr/bin/env node
// Converts BCCWJ frequency TSV files to bccwj.sqlite.
//
// Get these from https://clrd.ninjal.ac.jp/bccwj/en/freq-list.html
//
// Table bccwj: built from BCCWJ_frequencylist_luw2_ver1_0.tsv
//   columns: kanji TEXT, reading TEXT, frequency INTEGER, pmw REAL
//   "kanji" = lemma column (may be kana-only). "reading" = lForm in hiragana.
//
// Table bccwj_suw_counters: built from BCCWJ_frequencylist_suw_ver1_0.tsv
//   Only rows where pos contains 助数詞 are kept.
//   columns: kanji TEXT, reading TEXT, pos TEXT, frequency INTEGER, pmw REAL
//   pos values:
//     接尾辞-名詞的-助数詞      — pure counter suffix; frequency is unambiguously counter usage
//     名詞-普通名詞-助数詞可能  — counter-capable noun; frequency includes non-counter usages
//
// Usage: node .claude/scripts/build-bccwj-db.mjs

import Database from 'better-sqlite3';
import { createReadStream } from 'fs';
import { createInterface } from 'readline';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, '..', '..');
const TSV     = join(root, 'BCCWJ_frequencylist_luw2_ver1_0.tsv');
const TSV_SUW = join(root, 'BCCWJ_frequencylist_suw_ver1_0.tsv');
const DB      = join(root, 'bccwj.sqlite');

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
    pmw       REAL NOT NULL
  );
`);

const insert = db.prepare('INSERT INTO bccwj (kanji, reading, frequency, pmw) VALUES (?, ?, ?, ?)');

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
  const frequency = parseInt(cols[headers.indexOf('frequency')], 10);
  const pmw = parseFloat(cols[headers.indexOf('pmw')]);
  batch.push([lemma, toHiragana(lForm), frequency, pmw]);
  if (batch.length >= BATCH_SIZE) { insertMany(batch); count += batch.length; batch = []; }
}
if (batch.length) { insertMany(batch); count += batch.length; }

db.exec(`
  CREATE INDEX bccwj_kanji   ON bccwj (kanji);
  CREATE INDEX bccwj_reading ON bccwj (reading);
  CREATE INDEX bccwj_frequency ON bccwj (frequency);
  CREATE INDEX bccwj_pmw ON bccwj (pmw);
`);

db.exec(`
  DROP TABLE IF EXISTS bccwj_suw_counters;
  CREATE TABLE bccwj_suw_counters (
    kanji     TEXT NOT NULL,
    reading   TEXT NOT NULL,
    pos       TEXT NOT NULL,
    frequency INTEGER NOT NULL,
    pmw       REAL NOT NULL
  );
`);

const insertSuw = db.prepare(
  'INSERT INTO bccwj_suw_counters (kanji, reading, pos, frequency, pmw) VALUES (?, ?, ?, ?, ?)'
);
const insertManySuw = db.transaction((rows) => { for (const row of rows) insertSuw.run(row); });

const rlSuw = createInterface({ input: createReadStream(TSV_SUW), crlfDelay: Infinity });
let headersSuw = null;
let countSuw = 0;
let batchSuw = [];

for await (const line of rlSuw) {
  if (!headersSuw) { headersSuw = line.split('\t'); continue; }
  const cols = line.split('\t');
  const pos = cols[headersSuw.indexOf('pos')];
  if (!pos.includes('助数詞')) continue;
  const lemma = cols[headersSuw.indexOf('lemma')];
  const lForm = cols[headersSuw.indexOf('lForm')];
  const frequency = parseInt(cols[headersSuw.indexOf('frequency')], 10);
  const pmw = parseFloat(cols[headersSuw.indexOf('pmw')]);
  batchSuw.push([lemma, toHiragana(lForm), pos, frequency, pmw]);
  if (batchSuw.length >= BATCH_SIZE) { insertManySuw(batchSuw); countSuw += batchSuw.length; batchSuw = []; }
}
if (batchSuw.length) { insertManySuw(batchSuw); countSuw += batchSuw.length; }

db.exec(`
  CREATE INDEX bccwj_suw_counters_kanji   ON bccwj_suw_counters (kanji);
  CREATE INDEX bccwj_suw_counters_reading ON bccwj_suw_counters (reading);
  CREATE INDEX bccwj_suw_counters_pmw     ON bccwj_suw_counters (pmw);
`);

db.close();
console.log(`Wrote ${count} rows to bccwj, ${countSuw} rows to bccwj_suw_counters in ${DB}`);
