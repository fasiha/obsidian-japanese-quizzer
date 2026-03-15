/**
 * slugify-dbjg.mjs
 * Converts grammar-dbjg.md into grammar-dbjg.tsv matching the Genki/Bunpro TSV format.
 *
 * Each line in the .md file is one of:
 *   1. A main entry: `ageru1 's.o. gives s.t.'` or `ba` or `de1 [location]`
 *   2. A cross-reference (alias): `chau <shimau>` or `da <~ wa ~ da>`
 *   3. A blank line or heading (ignored)
 *
 * Output TSV columns: id, href, option, title-en, alias-of
 *   - id: slugified (spaces → hyphens, keep ~- prefixes, lowercase)
 *   - href: empty (it's a book)
 *   - option: "basic" for all
 *   - title-en: the description in quotes/brackets, or the raw entry text
 *   - alias-of: if this is a cross-reference, the slugified target(s); empty otherwise
 *
 * Usage: node grammar/slugify-dbjg.mjs > grammar/grammar-dbjg.tsv
 */

import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import path from "path";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const input = readFileSync(path.join(__dirname, "grammar-dbjg.md"), "utf8");

function slugify(raw) {
  return raw
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "-");
}

const lines = input.split("\n");
const entries = [];

for (const line of lines) {
  const trimmed = line.trim();
  // Skip blank lines, headings, and parenthetical notes
  if (!trimmed || trimmed.startsWith("#") || trimmed.startsWith("(")) continue;

  // Detect cross-reference: `foo <bar>` or `foo <bar, baz>`
  const crossRefMatch = trimmed.match(/^(.+?)\s*<([^>]+)>\.?$/);
  // Detect description in single quotes: `ageru1 's.o. gives s.t.'`
  const quoteMatch = trimmed.match(/^(.+?)\s+'([^']+)'\.?$/);
  // Detect description in brackets: `de1 [location]`
  const bracketMatch = trimmed.match(/^(.+?)\s+\[([^\]]+)\]\.?$/);

  let rawId, titleEn, aliasOf;

  if (crossRefMatch) {
    rawId = crossRefMatch[1];
    // The cross-reference target(s)
    const targets = crossRefMatch[2].split(",").map((t) => slugify(t.trim()));
    aliasOf = targets.join(",");
    // Also grab any quote/bracket description from the rawId portion
    const subQuote = rawId.match(/^(.+?)\s+'([^']+)'$/);
    const subBracket = rawId.match(/^(.+?)\s+\[([^\]]+)\]$/);
    if (subQuote) {
      rawId = subQuote[1];
      titleEn = subQuote[2];
    } else if (subBracket) {
      rawId = subBracket[1];
      titleEn = subBracket[2];
    } else {
      titleEn = "";
    }
  } else if (quoteMatch) {
    rawId = quoteMatch[1];
    titleEn = quoteMatch[2];
    aliasOf = "";
  } else if (bracketMatch) {
    rawId = bracketMatch[1];
    titleEn = bracketMatch[2];
    aliasOf = "";
  } else {
    // Plain entry like `ba` or `bakari`
    rawId = trimmed.replace(/\.$/, "");
    titleEn = "";
    aliasOf = "";
  }

  const id = slugify(rawId);
  entries.push({ id, titleEn, aliasOf });
}

// Deduplicate: if an alias has the same ID as an earlier main entry, skip it.
// The main entry is the canonical one; the alias just says "also discussed under X".
const seen = new Set();
const deduped = [];
// First pass: collect all main entry IDs
for (const entry of entries) {
  if (!entry.aliasOf) seen.add(entry.id);
}
// Second pass: skip aliases that collide with a main entry
for (const entry of entries) {
  if (entry.aliasOf && seen.has(entry.id)) continue;
  seen.add(entry.id);
  deduped.push(entry);
}

// Output TSV
console.log("id\thref\toption\ttitle-en\talias-of");
for (const { id, titleEn, aliasOf } of deduped) {
  console.log(`${id}\t\tbasic\t${titleEn}\t${aliasOf}`);
}
