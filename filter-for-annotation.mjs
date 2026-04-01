#!/usr/bin/env node
/**
 * Reads a Markdown file and outputs a JSON array of unique Japanese lines
 * needing vocabulary annotation. Each entry: { id: lineIndex, text: "..." }
 * where text has ruby tags stripped.
 *
 * Skips: YAML frontmatter, blank lines, section headers like [Aメロ],
 * purely English/romanized lines, and duplicate Japanese lines (only the
 * first occurrence of each unique line is included).
 *
 * Usage: node filter-for-annotation.mjs <file>
 */

import { readFileSync } from "fs";

const filePath = process.argv[2];
if (!filePath) {
  console.error("Usage: node filter-for-annotation.mjs <file>");
  process.exit(1);
}

const text = readFileSync(filePath, "utf8");
const lines = text.split("\n");

function isJapaneseLine(line) {
  // Exclude section headers like [Aメロ] even if they contain Japanese characters
  if (/^\s*\[.*\]\s*$/.test(line)) return false;
  return /[\u3040-\u9FFF]/.test(line);
}

function stripRuby(line) {
  // Remove optional ruby parentheses: <rp>（</rp> and <rp>）</rp>
  let result = line.replace(/<rp>[^<]*<\/rp>/g, "");
  // Remove ruby reading annotations: <rt>にほんご</rt>
  result = result.replace(/<rt>[^<]*<\/rt>/g, "");
  // Remove the remaining <ruby> and </ruby> wrapper tags; base text stays
  result = result.replace(/<\/?ruby>/g, "");
  return result;
}

function rubyToAnnotated(line) {
  // Replace each <ruby>base<rt>reading</rt></ruby> with base[reading]
  let result = line.replace(/<rp>[^<]*<\/rp>/g, "");
  result = result.replace(/<ruby>([^<]*)<rt>([^<]*)<\/rt><\/ruby>/g, "$1[$2]");
  // Drop any leftover ruby wrappers
  result = result.replace(/<\/?ruby>/g, "");
  return result;
}

const seen = new Set();
let inFrontmatter = false;
const result = [];

for (let i = 0; i < lines.length; i++) {
  const line = lines[i];

  // Track YAML frontmatter between leading --- delimiters
  if (i === 0 && line.trim() === "---") {
    inFrontmatter = true;
    continue;
  }
  if (inFrontmatter && line.trim() === "---") {
    inFrontmatter = false;
    continue;
  }
  if (inFrontmatter) continue;

  if (!isJapaneseLine(line)) continue;

  // Deduplicate: use original line (with ruby) as the key, consistent with mark-duplicates.mjs
  if (seen.has(line)) continue;
  seen.add(line);

  const hasRuby = /<ruby>/.test(line);
  const entry = { id: i, text: stripRuby(line) };
  if (hasRuby) entry.furigana = rubyToAnnotated(line);
  result.push(entry);
}

console.log(JSON.stringify(result, null, 2));
