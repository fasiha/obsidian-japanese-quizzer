#!/usr/bin/env node
/**
 * Analyze MeCab output to produce a histogram of morpheme counts per input line.
 *
 * Usage: node analyze-mecab-morphemes.mjs <mecab-output.txt>
 *
 * Expects a file containing MeCab output with EOS markers indicating end of each input line.
 */

import { readFileSync } from 'fs';

const args = process.argv.slice(2);
if (args.length === 0) {
  console.log('Usage: node analyze-mecab-morphemes.mjs <mecab-output.txt>');
  process.exit(1);
}

const input = readFileSync(args[0], 'utf-8');

if (!input.trim()) {
  console.log('File is empty');
  process.exit(1);
}

// Split by lines that are exactly "EOS" - each segment is one input word's analysis
const allLines = input.split('\n');
const segments = [];
let currentSegment = [];

for (const line of allLines) {
  if (line.trim() === 'EOS') {
    if (currentSegment.length > 0) {
      segments.push(currentSegment);
      currentSegment = [];
    }
  } else if (line.trim()) {
    currentSegment.push(line);
  }
}

// Count morphemes per segment (each line in a segment is one morpheme)
const morphemeCounts = segments.map(segment => segment.length);

// Build histogram
const histogram = {};
morphemeCounts.forEach(count => {
  const key = count === 1 ? '1 morpheme' : `${count}+ morphemes`;
  histogram[key] = (histogram[key] || 0) + 1;
});

// Print results
console.log(`Total inputs analyzed: ${segments.length}\n`);
console.log('Morpheme count distribution:\n');

Object.entries(histogram).sort((a, b) => a[0].localeCompare(b[0])).forEach(([key, value]) => {
  const percent = ((value / segments.length) * 100).toFixed(1);
  console.log(`  ${key.padEnd(15)}: ${value.toString().padStart(4)} (${percent}%)`);
});

// Also print detailed breakdown for variety
console.log('\nDetailed breakdown:');
const detailed = {};
morphemeCounts.forEach(count => {
  detailed[count] = (detailed[count] || 0) + 1;
});
Object.entries(detailed)
  .sort((a, b) => Number(a[0]) - Number(b[0]))
  .forEach(([count, value]) => {
    console.log(`  ${count} morpheme(s): ${value}`);
  });
