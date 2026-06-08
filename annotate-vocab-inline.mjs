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
import { setup, idsToWords } from "jmdict-simplified-node";
import {
  extractJapaneseTokens,
  resolveTokensToIds,
  isKanjiChar,
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
const rawDb = new Database(JMDICT_DB);
const rawTags = rawDb
  .prepare("select value_json from metadata where key='tags'")
  .pluck()
  .get();
const tags = JSON.parse(rawTags);
const furiganaStmt = rawDb.prepare(
  "SELECT segs FROM furigana WHERE text = ? AND reading = ?",
);

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

// Load the vocab-inline-data.json sidecar (produced by `annotate-harness.mjs done`)
// for per-occurrence sense indices and BCCWJ frequency.
// Keyed as `${sentenceId}|${wordId}` so the same word can show different senses
// in different sentences rather than using a single aggregated index.
const sidecarOccurrenceSenses = new Map(); // `${sentenceId}|${wordId}` → number[]
const sidecarPath = filePath.replace(/\.md$/, ".vocab-inline-data.json");
if (existsSync(sidecarPath)) {
  const sidecar = JSON.parse(readFileSync(sidecarPath, "utf8"));
  for (const [sentenceId, entries] of Object.entries(sidecar.sentences ?? {})) {
    for (const entry of entries) {
      if (typeof entry === "object" && entry.wordId && Array.isArray(entry.sense_indices)) {
        sidecarOccurrenceSenses.set(`${sentenceId}|${entry.wordId}`, entry.sense_indices);
      }
    }
  }
  for (const [wordId, data] of Object.entries(sidecar.words ?? {})) {
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

  const matchIds = resolveTokensToIds(db, tokens);

  if (matchIds.length !== 1) {
    process.stderr.write(
      `bullet "${bullet}" matched ${matchIds.length} JMDict entries (skipping)\n`,
    );
    return null;
  }

  const [word] = idsToWords(db, matchIds);
  return word ?? null;
}

// --- Toggle-furigana feature: build-time sentence ruby resolution ----------
//
// For each Vocab block, we resolve a fully ruby-annotated copy of the
// preceding sentence and embed it as a hidden <span>. A pandoc-header script
// swaps it in on click, so no dictionary lookups happen at runtime.
//
// The resolution mirrors `sentenceFuriganaSegments` in SentenceFuriganaView.swift:
//   Step 1 — exact-form match: each vocab word's specific (kanji-form, kana
//            reading) pair — taken straight from the bullet, the same
//            per-occurrence resolution `lookupFurigana(text:reading:db:)`
//            performs on the iOS side — is searched for verbatim; first-found
//            wins and overlapping matches are skipped.
//   Step 2 — single-kanji fallback: any kanji still unannotated that appears
//            exactly once and has one agreed reading across all candidates is
//            annotated individually, covering conjugated forms whose full
//            dictionary form does not appear verbatim.


// Resolves furigana segments for one vocab bullet by looking up each
// kanji-bearing leading token's (kanji-form, kana-reading) pair — taken from
// the bullet text itself — in the furigana table. Following the same
// disambiguation convention as `resolveFormToWordId` in annotate-harness.mjs
// (and prepare-publish.mjs), the bullet's leading Japanese tokens — those
// before the first non-Japanese character — may list any mix of kanji forms
// and kana readings, in any order, e.g. to disambiguate between JMDict
// entries that share a (kanji, kana) pair via a second valid kanji form.
// Returns one candidate per kanji-bearing token that resolves to furigana
// segments (a sentence may use any of the listed kanji forms), or [] if none
// resolve.
function buildFuriganaCandidates(word, bullet) {
  if (!word || word.kanji.length === 0) return [];
  const tokens = extractJapaneseTokens(bullet);
  if (tokens.length === 0) return [];

  const kanjiTokens = tokens.filter((t) => [...t].some(isKanjiChar));
  const kanaTokens = tokens.filter((t) => ![...t].some(isKanjiChar));
  if (kanjiTokens.length === 0) return [];
  const reading = kanaTokens.length === 1 ? kanaTokens[0] : word.kana[0]?.text;
  if (!reading) return [];

  const candidates = [];
  for (const text of kanjiTokens) {
    const row = furiganaStmt.get(text, reading);
    if (!row) continue;
    try {
      const segs = JSON.parse(row.segs);
      if (Array.isArray(segs) && segs.some((s) => s.rt)) candidates.push({ text, segs });
    } catch {
      // Skip malformed furigana rows.
    }
  }
  return candidates;
}

// Splits a sentence into alternating plain-text and pre-existing-<ruby> chunks.
// Pre-existing <ruby> spans (inserted by an earlier annotation pass) are kept
// verbatim and never re-annotated; only the plain-text chunks between them are
// candidates for new furigana.
function splitRubyChunks(sentence) {
  const chunks = [];
  const re = /<ruby>.*?<\/ruby>/gis;
  let last = 0;
  let m;
  while ((m = re.exec(sentence))) {
    if (m.index > last) chunks.push({ ruby: false, text: sentence.slice(last, m.index) });
    chunks.push({ ruby: true, text: m[0] });
    last = m.index + m[0].length;
  }
  if (last < sentence.length) chunks.push({ ruby: false, text: sentence.slice(last) });
  return chunks;
}

// Applies the two-step resolution to one plain-text chunk, returning HTML
// with new <ruby> spans spliced in around the matched substrings.
function annotateChunk(text, candidates) {
  const matches = [];
  for (const { text: form, segs } of candidates) {
    let from = 0;
    let idx;
    while ((idx = text.indexOf(form, from)) >= 0) {
      const end = idx + form.length;
      if (!matches.some((m) => idx < m.end && end > m.start)) {
        matches.push({ start: idx, end, segs });
      }
      from = idx + 1;
    }
  }

  // Step 2: build a kanji → reading map from every candidate's segments, then
  // annotate single-character kanji that occur exactly once and have one
  // agreed-upon reading across all candidates that mention them.
  const kanjiReadings = new Map(); // kanji char -> Set<reading>
  for (const { segs } of candidates) {
    for (const seg of segs) {
      if (seg.rt && [...seg.ruby].length === 1 && isKanjiChar(seg.ruby)) {
        if (!kanjiReadings.has(seg.ruby)) kanjiReadings.set(seg.ruby, new Set());
        kanjiReadings.get(seg.ruby).add(seg.rt);
      }
    }
  }
  for (const [kanji, readings] of kanjiReadings) {
    if (readings.size !== 1) continue;
    const occurrences = [];
    let from = 0;
    let idx;
    while ((idx = text.indexOf(kanji, from)) >= 0) {
      occurrences.push(idx);
      from = idx + 1;
    }
    if (occurrences.length !== 1) continue;
    const [start] = occurrences;
    const end = start + kanji.length;
    if (matches.some((m) => start < m.end && end > m.start)) continue;
    matches.push({ start, end, segs: [{ ruby: kanji, rt: [...readings][0] }] });
  }

  matches.sort((a, b) => a.start - b.start);

  let html = "";
  let pos = 0;
  for (const { start, end, segs } of matches) {
    html += text.slice(pos, start);
    for (const seg of segs) {
      html += seg.rt ? `<ruby>${seg.ruby}<rt>${seg.rt}</rt></ruby>` : seg.ruby;
    }
    pos = end;
  }
  html += text.slice(pos);
  return html;
}

// Resolves a fully ruby-annotated copy of `sentence`, merging furigana from
// every vocab bullet's candidate. Pre-existing <ruby> spans are preserved
// verbatim; new <ruby> spans are spliced into the plain-text chunks between them.
// Returns null when there is no sentence or no candidates to annotate with.
function resolveSentenceFurigana(sentence, candidates) {
  if (!sentence || candidates.length === 0) return null;
  return splitRubyChunks(sentence)
    .map((chunk) => (chunk.ruby ? chunk.text : annotateChunk(chunk.text, candidates)))
    .join("");
}

// Build a compact human-readable annotation string from a JMDict word object.
// sentenceId is the source-file line index of the containing sentence, used to
// look up per-occurrence sense indices from the sidecar (most specific source).
// Returns an HTML <span> with the info, or empty string if nothing useful found.
function buildAnnotation(word, bullet, sentenceId) {
  if (!word) return "";

  // Readings: show all kana readings that apply to the matched kanji form.
  // If the bullet has no kanji (kana-only word), show kana forms from kanji[].
  const _matchedToken = extractJapaneseTokens(bullet)[0];
  const _isKanaOnly = word.kanji.length === 0;

  let readings = [];

  // Sense lookup priority:
  //   1. sidecar per-occurrence (most specific — same word can have different
  //      senses in different sentences)
  //   2. vocab.json majority-vote across all files (word-level fallback)
  //   3. first sense (default when nothing else is available)
  let sensesToShow;
  if (allSenses) {
    sensesToShow = word.sense;
  } else {
    const sidecarKey = sentenceId != null ? `${sentenceId}|${word.id}` : null;
    const sidecarIndices = sidecarKey ? sidecarOccurrenceSenses.get(sidecarKey) : undefined;
    const llmIndices = sidecarIndices ?? senseIndexMap.get(word.id);
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
    const saturation = Math.min(1, Math.log10(1 + freq) / 2.5);
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
// Translation and Grammar <details> blocks are also inserted by
// `annotate-harness.mjs done`, right after the source sentence (before the Vocab
// block). Like Vocab blocks, their lines must not be counted toward
// sourceLineIndex, otherwise the reconstructed sentence ID drifts and the
// per-occurrence sidecar lookup fails. We skip any non-Vocab <details> block
// generically so future block types don't reintroduce this drift.
let insideSkipBlock = false;
let skipBlockDepth = 0; // nesting depth of <details> while inside a skipped block
// sourceLineIndex counts every source line (not <details> block lines).
// When a Vocab block opens, sourceLineIndex - 1 is the sentence ID (the
// line index of the preceding Japanese sentence in the original source file).
let sourceLineIndex = 0;
let currentSentenceId = null; // sentence ID for the Vocab block being processed
// Most recent non-blank "real" source line — the sentence the next Vocab
// (or skipped Grammar/Translation) block annotates. Used to resolve the
// toggle-furigana <span> for the Vocab block.
let lastProseLine = null;
let vocabSentenceText = null; // sentence text captured when the current Vocab block opened
let vocabFuriganaCandidates = []; // accumulated furigana candidates for the current Vocab block

for (const line of lines) {
  const trimmed = line.trim();

  // Pass non-Vocab <details> blocks (Translation, Grammar, …) through verbatim
  // without annotating, and without counting their lines toward sourceLineIndex
  // (they are insertions, not original source lines).
  if (insideSkipBlock) {
    const opens = (line.match(/<details\b/gi) || []).length;
    const closes = (line.match(/<\/details\b/gi) || []).length;
    skipBlockDepth += opens - closes;
    output.push(line);
    if (skipBlockDepth <= 0) insideSkipBlock = false;
    continue;
  }
  if (!insideVocab) {
    // A <details> opening whose summary is not "Vocab" is an inserted block to skip.
    const isDetailsOpen = /<details[^>]*>/.test(line);
    const isVocabOpen = isDetailsOpen && /<summary[^>]*>\s*Vocab\s*<\/summary>/.test(line);
    if (isDetailsOpen && !isVocabOpen) {
      // Compact one-liner (whole block on one line) needs no state change.
      const opens = (line.match(/<details\b/gi) || []).length;
      const closes = (line.match(/<\/details\b/gi) || []).length;
      if (opens - closes > 0) {
        insideSkipBlock = true;
        skipBlockDepth = opens - closes;
      }
      // Same blank-line separation as for Vocab blocks: ensure prose before
      // a Grammar/Translation block gets wrapped in <p> by pandoc.
      if (output.length && output[output.length - 1] !== "") {
        output.push("");
      }
      output.push(line);
      continue;
    }
  }

  // Detect opening of a Vocab details block.
  if (!insideVocab) {
    if (/<details[^>]*>/.test(line) && /<summary[^>]*>\s*Vocab\s*<\/summary>/.test(line)) {
      insideVocab = true;
      vocabDepth = 1;
      bulletDepth = 0;
      currentSentenceId = sourceLineIndex - 1; // preceding source line is the sentence
      vocabSentenceText = lastProseLine;
      vocabFuriganaCandidates = [];
      // Separate the preceding prose line from this block with a blank line so
      // pandoc wraps the prose in its own <p> element instead of absorbing it as
      // a bare text node into the raw-HTML <details> block. Without a real
      // element between sentences, CSS sibling selectors (used to add
      // margin-bottom after the last <details> of each sentence) cannot see the
      // boundary, because the `+` combinator ignores text nodes.
      if (output.length && output[output.length - 1] !== "") {
        output.push("");
      }
      output.push(line);
      // Pandoc requires a blank line after the opening tag to treat the
      // contents as Markdown rather than raw HTML.
      output.push("");
      continue;
    }
    output.push(line);
    sourceLineIndex++;
    if (trimmed) lastProseLine = line;
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
    // Inject the resolved toggle-furigana sentence (hidden by default; a
    // pandoc-header script swaps it in on click) before closing the block.
    const furiganaHtml = resolveSentenceFurigana(vocabSentenceText, vocabFuriganaCandidates);
    if (furiganaHtml) {
      output.push(`<span class="furigana-sentence" hidden>${furiganaHtml}</span>`);
    }
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
      const annotation = buildAnnotation(word, bullet, currentSentenceId);
      vocabFuriganaCandidates.push(...buildFuriganaCandidates(word, bullet));
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
