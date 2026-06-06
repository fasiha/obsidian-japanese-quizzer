#!/usr/bin/env node

/** Usage: node make-proper-noun-csv.mjs <words.tsv> <unidic-mecab-src-dir>

Reads a tab-separated file of proper nouns and compiles a MeCab user dictionary.

TSV format (one entry per line):
  kanji<TAB>katakana[<TAB>type]

where type is one of: 姓 (surname), 名 (given name), 地名 (place), 一般 (default)
If type is omitted, defaults to 一般. Lines starting with # are ignored.

Example words.tsv:
  鴨志田	カモシダ	姓
  松本	マツモト	姓
  いずみ	イズミ	名
  東京	トウキョウ	地名

UniDic source dir: download and unzip unidic-mecab-2.1.2_src.zip (from, e.g., https://clrd.ninjal.ac.jp/unidic_archive/cwj/2.1.2/)

Outputs:
  <words>.csv  — intermediate UniDic-format CSV
  <words>.dic  — compiled MeCab user dictionary (pass to mecab -u)
*/

import * as fs from 'node:fs';
import * as path from 'node:path';
import {execFileSync} from 'node:child_process';

const COST = 100;

// pos3 values for 固有名詞: 人名 subtypes or 地名
function posFields(type) {
  switch (type) {
    case '姓': return ['名詞', '固有名詞', '人名', '姓'];
    case '名': return ['名詞', '固有名詞', '人名', '名'];
    case '地名': return ['名詞', '固有名詞', '地名', '一般'];
    default:   return ['名詞', '固有名詞', '一般', '*'];
  }
}

function makeLine(kanji, katakana, type = '一般') {
  const [pos1, pos2, pos3, pos4] = posFields(type);
  // cType, cForm: no inflection for nouns
  const cType = '*';
  const cForm = '*';
  // lForm: lexical reading (katakana)
  const lForm = katakana;
  // lemma: dictionary form (kanji)
  const lemma = kanji;
  // orth: written form as it appears
  const orth = kanji;
  // pron: pronunciation
  const pron = katakana;
  // orthBase, pronBase: base forms (same as surface for non-inflecting words)
  const orthBase = kanji;
  const pronBase = katakana;
  // goshu: word type — 固 (固有語) for proper nouns
  const goshu = '固';
  // iType, iForm, fType, fForm: initial/final change types — none for nouns
  const iType = '*';
  const iForm = '*';
  const fType = '*';
  const fForm = '*';

  return [
    kanji, -1, -1, COST,
    pos1, pos2, pos3, pos4,
    cType, cForm,
    lForm, lemma, orth, pron, orthBase, pronBase, goshu,
    iType, iForm, fType, fForm,
  ].join(',');
}

const [tsvFile, unidicSrcDir] = process.argv.slice(2);
if (!tsvFile || !unidicSrcDir) {
  process.stderr.write('Usage: node make-proper-noun-csv.mjs <words.tsv> <unidic-mecab-src-dir>\n');
  process.exit(1);
}

const csvFile = tsvFile.replace(/\.[^.]+$/, '') + '.csv';
const dicFile = tsvFile.replace(/\.[^.]+$/, '') + '.dic';

const lines = [];
for (const line of fs.readFileSync(tsvFile, 'utf8').split('\n')) {
  const trimmed = line.trim();
  if (!trimmed || trimmed.startsWith('#')) continue;
  const [kanji, katakana, type] = trimmed.split('\t');
  if (!kanji || !katakana) {
    process.stderr.write(`Skipping malformed line: ${line}\n`);
    continue;
  }
  lines.push(makeLine(kanji, katakana, type?.trim()));
}

fs.writeFileSync(csvFile, lines.join('\n') + '\n');
process.stderr.write(`Wrote ${lines.length} entries to ${csvFile}\n`);

const mecabDictIndex = execFileSync('mecab-config', ['--libexecdir'], {encoding: 'utf8'}).trim() + '/mecab-dict-index';
execFileSync(mecabDictIndex, ['-d', unidicSrcDir, '-u', dicFile, '-f', 'utf8', '-t', 'utf8', csvFile], {stdio: 'inherit'});
process.stderr.write(`Compiled dictionary: ${dicFile}\n`);
