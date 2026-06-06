/**
 * annotate-vocab-inline.mjs
 *
 * Reads a Markdown file and appends JMDict info (readings, part-of-speech,
 * English glosses) as inline HTML after each vocab bullet inside every
 * <details><summary>Vocab</summary> block.
 *
 * (Expects `vocab.json` to be populated via `prepare-publish.mjs`!)
 *
 * Outputs the modified Markdown to stdout — it never writes to the input file.
 *
 * Usage:
 *   node annotate-vocab-inline.mjs <path-to-markdown-file> [--all-senses]
 *
 * Options:
 *   --all-senses   Include all senses, not just the LLM-selected (or first) one.
 *
 * Example:
 *   node annotate-vocab-inline.mjs "Genki 1/L5.md" | pandoc -s -o /tmp/preview.html
 */

import { readFileSync, existsSync } from "fs";
import path from "path";
import Database from "better-sqlite3";
import { setup, findExactIds, idsToWords } from "jmdict-simplified-node";
import {
  extractJapaneseTokens,
  intersectSets,
  parseFrontmatter,
  projectRoot,
  JMDICT_DB,
} from "./.claude/scripts/shared.mjs";

const args = process.argv.slice(2).filter((a) => a !== "--all-senses");
const allSenses = process.argv.includes("--all-senses");

if (args.length !== 1) {
  console.error(
    "Usage: node annotate-vocab-inline.mjs <markdown-file> [--all-senses]",
  );
  process.exit(1);
}

const filePath = args[0];
const content = readFileSync(filePath, "utf8");

const fm = parseFrontmatter(content);
if (!fm?.["llm-review"]) {
  process.stderr.write(
    `Warning: ${filePath} does not have llm-review: true in frontmatter\n`,
  );
}

const { db } = await setup(JMDICT_DB);
const rawTags = new Database(JMDICT_DB)
  .prepare("select value_json from metadata where key='tags'")
  .pluck()
  .get();
const tags = JSON.parse(rawTags);

// Build maps from JMDict ID → sense indices and BCCWJ frequency.
const senseIndexMap = new Map(); // id (string) → number[]
const bccwjMap = new Map();      // id (string) → perMillionWords (number)
const vocabJsonPath = path.join(projectRoot, "vocab.json");
if (existsSync(vocabJsonPath)) {
  const vocab = JSON.parse(readFileSync(vocabJsonPath, "utf8"));
  for (const word of vocab.words) {
    if (word.bccwjPerMillionWords != null) {
      bccwjMap.set(word.id, word.bccwjPerMillionWords);
    }
    // Count how often each sense_indices combination appears across references.
    const frequency = new Map(); // JSON key → { count, indices }
    for (const refs of Object.values(word.references ?? {})) {
      for (const ref of refs) {
        const indices = ref.llm_sense?.sense_indices;
        if (!Array.isArray(indices) || indices.length === 0) continue;
        const key = JSON.stringify(indices.slice().sort((a, b) => a - b));
        const prev = frequency.get(key) ?? { count: 0, indices };
        frequency.set(key, { count: prev.count + 1, indices });
      }
    }
    if (frequency.size > 0) {
      const best = [...frequency.values()].sort((a, b) => b.count - a.count)[0];
      senseIndexMap.set(word.id, best.indices);
    }
  }
}

// Fall back to a vocab-inline-data.json sidecar (produced by
// `annotate-harness.mjs done --senses`) for words not covered by vocab.json.
// The sidecar lives next to the input file, named <basename>.vocab-inline-data.json.
const sidecarPath = filePath.replace(/\.md$/, ".vocab-inline-data.json");
if (existsSync(sidecarPath)) {
  const sidecar = JSON.parse(readFileSync(sidecarPath, "utf8"));
  for (const [wordId, data] of Object.entries(sidecar.words ?? {})) {
    if (!senseIndexMap.has(wordId) && Array.isArray(data.sense_indices) && data.sense_indices.length > 0) {
      senseIndexMap.set(wordId, data.sense_indices);
    }
    if (!bccwjMap.has(wordId) && data.bccwjPerMillionWords != null) {
      bccwjMap.set(wordId, data.bccwjPerMillionWords);
    }
  }
}

// Resolve a bullet text to a JMDict word object, or null with a warning.
function resolveWord(bullet) {
  const directIdMatch = bullet.match(/^\d+/);
  if (directIdMatch) {
    const [word] = idsToWords(db, [directIdMatch[0]]);
    return word ?? null;
  }

  const tokens = extractJapaneseTokens(bullet);
  if (tokens.length === 0) return null;

  const idSets = tokens.map((t) => new Set(findExactIds(db, t)));
  const matchIds = [...intersectSets(idSets)];

  if (matchIds.length !== 1) {
    process.stderr.write(
      `bullet "${bullet}" matched ${matchIds.length} JMDict entries (skipping)\n`,
    );
    return null;
  }

  const [word] = idsToWords(db, matchIds);
  return word ?? null;
}

// Build a compact human-readable annotation string from a JMDict word object.
// Returns an HTML <span> with the info, or empty string if nothing useful found.
function buildAnnotation(word, bullet) {
  if (!word) return "";

  // Readings: show all kana readings that apply to the matched kanji form.
  // If the bullet has no kanji (kana-only word), show kana forms from kanji[].
  const _matchedToken = extractJapaneseTokens(bullet)[0];
  const _isKanaOnly = word.kanji.length === 0;

  let readings = [];

  // Prefer LLM-selected sense indices from vocab.json; fall back to first sense.
  let sensesToShow;
  if (allSenses) {
    sensesToShow = word.sense;
  } else {
    const llmIndices = senseIndexMap.get(word.id);
    if (llmIndices && llmIndices.length > 0) {
      sensesToShow = llmIndices
        .map((i) => word.sense[i])
        .filter(Boolean);
    }
    if (!sensesToShow || sensesToShow.length === 0) {
      sensesToShow = word.sense.slice(0, 1);
    }
  }

  const cleanPos = (pos) => {
    return pos.startsWith('Godan verb') ? pos.replace(/(Godan verb).*/, '$1') : pos.replaceAll(/\s*\(.*?\)\s*/g, '');
  };

  const seenPos = new Set();
  
  const parts = sensesToShow.map((sense, i) => {
    const posLabels = sense.partOfSpeech.map((code) => tags[code] ?? code).map(cleanPos);
    const glosses = sense.gloss
      .filter((g) => g.lang === "eng")
      .map((g) => g.text);
    const infoNotes = sense.info.length ? ` (${sense.info.join("; ")})` : "";
    const posStr = posLabels.length ? `[${posLabels.join(", ")}] ` : "";
    const dedupedPosStr = seenPos.has(posStr) ? '' : posStr;
    seenPos.add(posStr);
    const senseNum = allSenses && word.sense.length > 1 ? `${i + 1}. ` : "";
    return `${senseNum}${dedupedPosStr}${glosses.join("; ")}${infoNotes}`;
  });

  const readingStr = readings.length ? readings.join("・") : "";
  const separator = readingStr && parts.length ? " — " : "";

  const freq = bccwjMap.get(word.id);
  let freqStr = "";
  if (freq != null) {
    const saturation = Math.min(1, Math.log10(1 + freq) / 3);
    const color = `hsl(0deg ${(saturation * 100).toFixed(1)}% 50%)`;
    freqStr = ` <span class="bccwj-freq" style="color:${color};font-size:0.8em">${freq.toFixed(1)}/M</span>`;
  }

  return ` <span class="jmdict-info" style="color:#888;font-size:0.85em">${readingStr}${separator}${parts.join(" / ")}</span>${freqStr}`;
}

// Process the file line-by-line, tracking whether we're inside a Vocab
// <details> block, and appending annotations to bullet lines.
const lines = content.split("\n");
const output = [];
let insideVocab = false;
let vocabDepth = 0; // nesting depth of <details> while inside a Vocab block
let bulletDepth = 0; // depth of nested <details> inside the Vocab block body

for (const line of lines) {
  const trimmed = line.trim();

  // Detect opening of a Vocab details block.
  if (!insideVocab) {
    if (/<details[^>]*>/.test(line) && /<summary[^>]*>\s*Vocab\s*<\/summary>/.test(line)) {
      insideVocab = true;
      vocabDepth = 1;
      bulletDepth = 0;
      output.push(line);
      // Pandoc requires a blank line after the opening tag to treat the
      // contents as Markdown rather than raw HTML.
      output.push("");
      continue;
    }
    output.push(line);
    continue;
  }

  // We are inside a Vocab block. Track nesting to find the closing </details>.
  const opens = (line.match(/<details\b/gi) || []).length;
  const closes = (line.match(/<\/details\b/gi) || []).length;

  // Check for end of this Vocab block before processing the line as a bullet.
  // A close that brings vocabDepth to 0 ends the block.
  const netChange = opens - closes;
  const nextDepth = vocabDepth + netChange;

  if (nextDepth <= 0) {
    // This line contains the closing </details> for the Vocab block itself.
    insideVocab = false;
    output.push(line);
    continue;
  }

  vocabDepth = nextDepth;

  // Track inner nesting depth to skip bullets inside nested <details>.
  // bulletDepth counts opens/closes *excluding* the Vocab block's own open tag
  // (which we already handled before entering this state).
  bulletDepth += opens - closes;
  if (bulletDepth < 0) bulletDepth = 0;

  // Only annotate top-level bullets (not inside nested <details>).
  if (bulletDepth === 0 && trimmed.startsWith("-")) {
    const bullet = trimmed.slice(1).trim();
    if (bullet && !bullet.startsWith("counter:")) {
      const word = resolveWord(bullet);
      const annotation = buildAnnotation(word, bullet);
      if (annotation) {
        // Append annotation after the bullet text, preserving leading whitespace.
        const leadingSpace = line.match(/^(\s*)/)[1];
        output.push(`${leadingSpace}- ${bullet}${annotation}`);
        continue;
      }
    }
  }

  output.push(line);
}

process.stdout.write(output.join("\n"));
