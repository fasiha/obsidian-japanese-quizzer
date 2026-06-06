#!/usr/bin/env node
/**
 * Read MeCab output and emit the top N morphemes by lemma frequency.
 * Always skips punctuation, symbols, and whitespace.
 *
 * Usage:
 *   node mecab-top-morphemes.mjs <input-file> [N=50]
 *   node mecab-top-morphemes.mjs <input-file> [N=50] --filter-pos 助詞,助動詞,連体詞
 *   node mecab-top-morphemes.mjs <input-file> [N=50] --only-pos 名詞,動詞,形容詞
 */

import { readFileSync } from 'node:fs';

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

const sorted = [...data.entries()]
  .sort((a, b) => b[1].count - a[1].count || a[0].localeCompare(b[0]))
  .slice(0, N);

console.log(`| # | Lemma | Pronunciation | POS | Count |`);
console.log(`|---|-------|--------------:|-----|------:|`);
sorted.forEach(([lemma, entry], i) => {
  console.log(`| ${i + 1} | ${lemma} | ${topPron(entry.pronMap)} | ${shortPos(entry.pos)} | ${entry.count} |`);
});
