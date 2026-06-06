#!/usr/bin/env node
/**
 * Read MeCab output and emit the top N morphemes by lemma frequency.
 * Always skips punctuation, symbols, and whitespace.
 *
 * Usage:
 *   node mecab-top-morphemes.mjs <input-file> [N=50]
 *   node mecab-top-morphemes.mjs <input-file> [N=50] --filter-pos 助詞,助動詞,連体詞
 *   node mecab-top-morphemes.mjs <input-file> [N=50] --only-pos 名詞,動詞,形容詞
 *
 * Generate the input file like this:
 *
 *   cat INPUT.txt | mecab > INPUT.mecab
 *
 * and use INPUT.mecab as the input to this script.
 *
 * When bccwj.sqlite is present in the same directory, adds BCCWJ corpus PMW,
 * document PMW (count normalised to per-million morphemes), and the ratio
 * doc-PMW / BCCWJ-PMW so you can see which words are over- or under-represented
 * in this text relative to the general corpus.
 */

import { readFileSync, existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const BCCWJ_PATH = path.join(__dirname, 'bccwj.sqlite');

const args = process.argv.slice(2);
const inputPath = args[0];
if (!inputPath) {
  console.error('Usage: node mecab-top-morphemes.mjs <input-file> [N=50] [--filter-pos A,B,C | --only-pos A,B,C]');
  process.exit(1);
}

// Parse numbered N
let N = 50;
let filterPos = null;  // Set of POS prefixes to EXCLUDE
let onlyPos = null;    // Set of POS prefixes to INCLUDE (mutually exclusive with filterPos)

for (let i = 1; i < args.length; i++) {
  if (args[i] === '--filter-pos' && args[i + 1]) {
    filterPos = new Set(args[++i].split(',').map(s => s.trim()));
  } else if (args[i] === '--only-pos' && args[i + 1]) {
    onlyPos = new Set(args[++i].split(',').map(s => s.trim()));
  } else if (/^\d+$/.test(args[i])) {
    N = parseInt(args[i], 10);
  }
}

// POS prefixes always filtered (punctuation / format)
const SKIP_POS_PREFIXES = new Set([
  '補助記号',
  '記号',
  '空白',
]);

const text = readFileSync(inputPath, 'utf-8');
const lines = text.split('\n');

// Map<lemma, { count, pronMap<pronunciation, count>, posTag }>
const data = new Map();
// Counts ALL non-punctuation morphemes — used as the denominator for doc PMW
// so it is comparable to the BCCWJ PMW which is normalised over all word types.
let totalMorphemes = 0;

for (const line of lines) {
  const trimmed = line.trim();
  if (!trimmed || trimmed === 'EOS') continue;

  const fields = trimmed.split('\t');
  if (fields.length < 5) continue;

  const pos = fields[4];

  // Always skip punctuation / symbols / whitespace
  let skip = false;
  for (const prefix of SKIP_POS_PREFIXES) {
    if (pos.startsWith(prefix)) { skip = true; break; }
  }
  if (skip) continue;

  // Count all non-punctuation morphemes before applying pos filters,
  // so the doc PMW denominator matches BCCWJ's whole-corpus normalisation.
  totalMorphemes++;

  // --filter-pos: skip if POS matches any given prefix (top-level or subcategory)
  if (filterPos) {
    let matched = false;
    for (const prefix of filterPos) {
      if (pos === prefix || pos.startsWith(prefix + '-') || pos.includes('-' + prefix)) {
        matched = true; break;
      }
    }
    if (matched) continue;
  }

  // --only-pos: skip if POS does NOT match any given prefix (top-level or subcategory)
  if (onlyPos) {
    let matched = false;
    for (const prefix of onlyPos) {
      if (pos === prefix || pos.startsWith(prefix + '-') || pos.includes('-' + prefix)) {
        matched = true; break;
      }
    }
    if (!matched) continue;
  }

  const lemma = (fields[3] || fields[0]).trim();
  if (!lemma) continue;
  const pron = fields[2] || '';

  let entry = data.get(lemma);
  if (!entry) {
    entry = { count: 0, pronMap: new Map(), pos };
    data.set(lemma, entry);
  } else {
    entry.count++;
  }
  entry.count++;
  if (pron) {
    entry.pronMap.set(pron, (entry.pronMap.get(pron) || 0) + 1);
  }
}

function topPron(pronMap) {
  let best = '';
  let bestCount = 0;
  for (const [p, c] of pronMap) {
    if (c > bestCount) { best = p; bestCount = c; }
  }
  return best;
}

// Simplify POS for display: only show the first segment (before '-')
function shortPos(pos) {
  return pos.split('-')[0];
}

// Convert katakana string to hiragana (simple codepoint shift)
function kataToHira(kata) {
  return kata.replace(/[ァ-ヶ]/g, ch => String.fromCodePoint(ch.codePointAt(0) - 0x60));
}

// Open BCCWJ database if available; return a lookup function or null.
function openBccwj() {
  if (!existsSync(BCCWJ_PATH)) return null;
  try {
    const require = createRequire(import.meta.url);
    const Database = require('better-sqlite3');
    const db = new Database(BCCWJ_PATH, { readonly: true });
    const byKanjiReading = db.prepare('SELECT MAX(pmw) AS pmw FROM bccwj WHERE kanji = ? AND reading = ?');
    const byKanji        = db.prepare('SELECT MAX(pmw) AS pmw FROM bccwj WHERE kanji = ?');
    return (lemma, hiraganaReading) => {
      // 1. Exact lemma + reading
      let row = byKanjiReading.get(lemma, hiraganaReading);
      if (row?.pmw != null) return row.pmw;
      // 2. Kana-only entries where kanji column holds the kana spelling
      if (hiraganaReading && hiraganaReading !== lemma) {
        row = byKanjiReading.get(hiraganaReading, hiraganaReading);
        if (row?.pmw != null) return row.pmw;
      }
      // 3. Lemma only (ignores reading ambiguity, picks highest PMW)
      row = byKanji.get(lemma);
      return row?.pmw ?? null;
    };
  } catch (err) {
    console.error('Warning: could not open bccwj.sqlite:', err.message);
    return null;
  }
}

const getBccwjPmw = openBccwj();
const hasBccwj = getBccwjPmw !== null;

const sorted = [...data.entries()]
  .sort((a, b) => b[1].count - a[1].count || a[0].localeCompare(b[0]))
  .slice(0, N);

const fmt = (n) => n == null ? '' : n.toFixed(1);

if (hasBccwj) {
  console.log(`| # | Lemma | Pronunciation | POS | Count | Doc PMW | BCCWJ PMW | Ratio |`);
  console.log(`|---|-------|--------------:|-----|------:|--------:|----------:|------:|`);
} else {
  console.log(`| # | Lemma | Pronunciation | POS | Count |`);
  console.log(`|---|-------|--------------:|-----|------:|`);
}

sorted.forEach(([lemma, entry], i) => {
  const pron = topPron(entry.pronMap);
  if (hasBccwj) {
    const hira = kataToHira(pron);
    // UniDic appends a Latin gloss to some loanword lemmas (e.g. モノレール-monorail).
    // Strip it before the BCCWJ lookup so the kanji column matches.
    const lemmaForLookup = lemma.replace(/-[A-Za-z][\w-]*$/, '');
    const bccwjPmw = getBccwjPmw(lemmaForLookup, hira);
    const docPmw = (entry.count / totalMorphemes) * 1_000_000;
    const ratio = bccwjPmw ? docPmw / bccwjPmw : null;
    const ratioStr = ratio == null ? '' : ratio.toFixed(2);
    console.log(`| ${i + 1} | ${lemma} | ${pron} | ${shortPos(entry.pos)} | ${entry.count} | ${fmt(docPmw)} | ${fmt(bccwjPmw)} | ${ratioStr} |`);
  } else {
    console.log(`| ${i + 1} | ${lemma} | ${pron} | ${shortPos(entry.pos)} | ${entry.count} |`);
  }
});
