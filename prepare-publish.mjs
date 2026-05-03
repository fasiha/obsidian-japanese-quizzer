/**
 * prepare-publish.mjs
 * Validates all llm-review Markdown files, compiles a single vocab.json,
 * detects compound verbs, and updates grammar mappings.
 *
 * Requirements per file:
 *   - `llm-review: true` in YAML frontmatter
 *   - All vocab bullets must resolve to exactly one JMDict entry
 *
 * Output: vocab.json, grammar.json, corpus.json at project root
 *
 * Ctrl-C safety: vocab.json is written incrementally after every LLM call
 * (both sense analysis and kanji meanings). Interrupting the script mid-run
 * preserves all work completed so far; the next run reloads from vocab.json
 * and skips already-analyzed entries. Any new LLM step added to this script
 * must honor this guarantee by writing vocab.json after each successful call.
 *
 * Workflow:
 *   1. Validate and extract vocab/grammar from all Markdown files
 *   2. Run sense analysis on vocab via LLM (unless --no-llm)
 *   3. Compile grammar equivalence groups
 *   4. Detect compound verbs and update compound-verbs.json (unless --no-llm)
 *
 * Flags:
 *   --no-llm              : skip LLM calls for both sense analysis and compound verb detection
 *   --max-senses N        : only run sense analysis for at most N words
 *   --max-compound-verbs N: only run compound verb detection for at most N suffix categories
 *   --max-kanji-senses N  : only run kanji meanings analysis for at most N words
 *
 * Usage: node prepare-publish.mjs [--no-llm] [--max-senses N] [--max-compound-verbs N] [--max-kanji-senses N]
 */

import { setup, findExactIds, idsToWords, kanjiAnywhere } from "jmdict-simplified-node";
import { readFileSync, writeFileSync, existsSync } from "fs";
import Anthropic from "@anthropic-ai/sdk";
import Database from "better-sqlite3";
import path from "path";
import {
  findMdFiles,
  extractJapaneseTokens,
  isJapanese,
  intersectSets,
  parseFrontmatter,
  projectRoot,
  JMDICT_DB,
  KANJIDIC2_DB,
  loadGrammarDatabases,
  extractGrammarBullets,
  extractDetailsBlocks,
  toHiragana,
  isFuriganaParent,
  buildFuriganaForWord,
  extractContextBefore,
} from "./.claude/scripts/shared.mjs";
import { checkAndUpdateCompoundVerbs } from "./.claude/scripts/check-compound-verbs.mjs";

// --- JmdictFurigana enrichment ---


/**
 * Load JmdictFurigana.json and return a Map<text, entry[]> for fast lookup by
 * written form.
 */
function loadJmdictFurigana() {
  const raw = readFileSync(
    path.join(projectRoot, "JmdictFurigana.json"),
    "utf8",
  ).trim(); // .trim() strips BOM
  const entries = JSON.parse(raw);
  const map = new Map();
  for (const entry of entries) {
    const arr = map.get(entry.text);
    if (arr) arr.push(entry);
    else map.set(entry.text, [entry]);
  }
  return map;
}




// Like shared.extractVocabBullets but also returns 1-indexed line numbers,
// bullet narration text (non-Japanese text after the Japanese tokens), and
// the context paragraph preceding the <details> block.
function extractVocabBullets(content) {
  const bullets = [];
  for (const { stripped, fileOffset, blockLine } of extractDetailsBlocks(content, "Vocab")) {
    const { text: context, line: sentenceLine } = extractContextBefore(content, fileOffset);
    const line = sentenceLine ?? blockLine;
    const innerLines = stripped.split("\n");
    let depth = 0;
    for (const innerLine of innerLines) {
      if (depth === 0) {
        const trimmed = innerLine.trim();
        if (trimmed.startsWith("-")) {
          const bullet = trimmed.slice(1).trim();
          if (bullet && !bullet.startsWith("counter:")) {
            // Narration = text after the leading Japanese tokens (or after the bare ID).
            const parts = bullet.split(/\s+/);
            let j = 0;
            if (/^\d+$/.test(parts[0])) j = 1; // skip bare JMDict ID prefix
            while (j < parts.length && parts[j] && isJapanese(parts[j])) j++;
            const narration = parts.slice(j).join(" ").trim() || null;
            bullets.push({ bullet, line, context, narration });
          }
        }
      }
      const opens = (innerLine.match(/<details\b/gi) || []).length;
      const closes = (innerLine.match(/<\/details\b/gi) || []).length;
      depth += opens - closes;
      if (depth < 0) depth = 0;
    }
  }
  return bullets;
}

// Extract counter IDs from `- counter:id` bullets in <details><summary>Vocab</summary> blocks.
// Returns { counterId, line, context } for each counter bullet found.
function extractCounterBullets(content) {
  const counters = [];
  for (const { stripped, fileOffset, blockLine } of extractDetailsBlocks(content, "Vocab")) {
    const { text: context, line: sentenceLine } = extractContextBefore(content, fileOffset);
    const line = sentenceLine ?? blockLine;
    const innerLines = stripped.split("\n");
    let depth = 0;
    for (const innerLine of innerLines) {
      if (depth === 0) {
        const trimmed = innerLine.trim();
        if (trimmed.startsWith("-")) {
          const bullet = trimmed.slice(1).trim();
          if (bullet.startsWith("counter:")) {
            const counterId = bullet.slice("counter:".length).trim();
            if (counterId) counters.push({ counterId, line, context });
          }
        }
      }
      const opens = (innerLine.match(/<details\b/gi) || []).length;
      const closes = (innerLine.match(/<\/details\b/gi) || []).length;
      depth += opens - closes;
      if (depth < 0) depth = 0;
    }
  }
  return counters;
}

// --- Command-line flags ---
// --no-llm              : skip all LLM sense-analysis calls and compound verb detection
// --dry-run             : skip all LLM calls entirely (no token burn); don't write output files
// --max-senses N        : only run LLM analysis for at most N words (useful for spot-checking)
// --max-compound-verbs N: only run compound verb LLM analysis for at most N suffixes
const args = process.argv.slice(2);
const noLlm = args.includes("--no-llm");
const dryRun = args.includes("--dry-run");
const maxSensesIdx = args.indexOf("--max-senses");
const maxSenses =
  maxSensesIdx !== -1 ? parseInt(args[maxSensesIdx + 1], 10) : Infinity;
const maxCompoundVerbsIdx = args.indexOf("--max-compound-verbs");
const maxCompoundVerbs =
  maxCompoundVerbsIdx !== -1 ? parseInt(args[maxCompoundVerbsIdx + 1], 10) : Infinity;
const maxKanjiSensesIdx = args.indexOf("--max-kanji-senses");
const maxKanjiSenses =
  maxKanjiSensesIdx !== -1 ? parseInt(args[maxKanjiSensesIdx + 1], 10) : Infinity;

// Define output paths
const outPath = path.join(projectRoot, "vocab.json");

// Load existing vocab.json to seed the in-memory sense cache and preserve
// word-level flags (like notCompound) that are written by other scripts.
// Cache key: "<wordId>|<JSON(sorted deduplicated [context, narration])>"
// Value: the llm_sense object { sense_indices, computed_from, reasoning? }
const existingRefSense = new Map();
// Map from word id → set of word-level boolean flags to carry forward
const existingWordFlags = new Map();
if (existsSync(outPath)) {
  try {
    const existing = JSON.parse(readFileSync(outPath, "utf8"));
    for (const w of existing.words ?? []) {
      for (const refs of Object.values(w.references ?? {})) {
        for (const ref of refs) {
          if (ref.llm_sense) {
            const normalizedContext = normalizeContextForCache(ref.context);
            const computedFrom = [normalizedContext, ref.narration].filter((v) => v != null);
            const key = `${w.id}|${JSON.stringify([...new Set(computedFrom)].sort())}`;
            existingRefSense.set(key, ref.llm_sense);
          }
        }
      }
      if (w.notCompound === true) {
        existingWordFlags.set(w.id, { notCompound: true });
      }
      if (w.kanjiMeanings) {
        existingWordFlags.set(w.id, { ...existingWordFlags.get(w.id), kanjiMeanings: w.kanjiMeanings });
      }
    }
  } catch {
    // Corrupt or missing vocab.json — start fresh
  }
}

const { db } = await setup(JMDICT_DB);
const grammarDb = loadGrammarDatabases();
const mdFiles = findMdFiles(projectRoot);

// Build a map from JMDict ID -> array of counter info for counter detection.
// Maps JMDict ID to array of { id, whatItCounts, senseIndex }.
// Most JMDict IDs map to 1 counter, but ambiguous cases like かい (階 vs 回) have 2+.
// senseIndex is an array of 0-based indices (usually length 1; length 2 for 着 which
// counts both clothing and race placement). null means JMDict has no ctr-tagged sense.
const hasSenseIndices = (c) => Array.isArray(c.senseIndex) && c.senseIndex.length > 0;
const countersByJmdictId = new Map();
// Maps counter id (e.g. "くみ-クラス") → jmdict id string, for resolving counter bullets to vocab entries.
const counterIdToJmdictId = new Map();
const countersJsonPath = path.join(projectRoot, "Counters", "counters.json");
let countersJsonData = [];
if (existsSync(countersJsonPath)) {
  try {
    countersJsonData = JSON.parse(readFileSync(countersJsonPath, "utf8"));
    for (const counter of countersJsonData) {
      if (counter.jmdict && counter.jmdict.id) {
        const jmdictId = counter.jmdict.id;
        if (!countersByJmdictId.has(jmdictId)) {
          countersByJmdictId.set(jmdictId, []);
        }
        countersByJmdictId.get(jmdictId).push({
          id: counter.id,
          whatItCounts: counter.whatItCounts,
          senseIndex: counter.jmdict.senseIndex,
        });
        counterIdToJmdictId.set(counter.id, jmdictId);
      }
    }
  } catch (e) {
    console.warn(`Could not load counters.json for counter detection: ${e.message}`);
  }
}

const errors = [];
const stories = [];
// Map from word id -> { id, sources: Set<title>, refs: Map<title, Set<lineNumber>> }
const wordMap = new Map();
// Map from grammar topicId -> { topicId, sources: Set<title>, sentences: [] }
const grammarMap = new Map();
const grammarErrors = [];

// Map: title → (line → counterId) for manual counter annotations
const countersByTitleLine = new Map();

for (const filePath of mdFiles) {
  const content = readFileSync(filePath, "utf8");
  const fm = parseFrontmatter(content);
  if (!fm?.["llm-review"]) continue;

  const relPath = path.relative(projectRoot, filePath);

  const title = relPath.replace(/\.md$/i, "");
  if (!stories.find((s) => s.title === title)) {
    stories.push({ title, content });
  }

  // --- Grammar extraction ---
  for (const { topicId, note, line, matchIndex } of extractGrammarBullets(content)) {
    const colonIdx = topicId.indexOf(":");
    if (colonIdx === -1) {
      grammarErrors.push(
        `${relPath}:${line}: grammar tag "${topicId}" missing source prefix`,
      );
      continue;
    }
    if (!grammarDb.has(topicId)) {
      grammarErrors.push(
        `${relPath}:${line}: grammar tag "${topicId}" not found in database`,
      );
      continue;
    }

    const { text: context, line: sentenceLine } = extractContextBefore(content, matchIndex);
    // Use the sentence line number so that line points to the same line as context.
    // Fallback to the bullet line from extractGrammarBullets if no sentence found.
    const occurrence = { line: sentenceLine ?? line, context, narration: note || undefined };

    if (grammarMap.has(topicId)) {
      const entry = grammarMap.get(topicId);
      entry.sources.add(title);
      if (!entry.refs.has(title)) entry.refs.set(title, []);
      entry.refs.get(title).push(occurrence);
    } else {
      grammarMap.set(topicId, {
        topicId,
        sources: new Set([title]),
        refs: new Map([[title, [occurrence]]]),
      });
    }
  }

  // --- Vocab extraction ---
  for (const { bullet, line, context, narration } of extractVocabBullets(content)) {
    // If the bullet starts with a bare JMDict ID (all digits), trust it directly.
    const directIdMatch = bullet.match(/^(\d+)/);
    let wordId;
    let annotatedForms = [];
    if (directIdMatch) {
      wordId = directIdMatch[1];
    } else {
      const tokens = extractJapaneseTokens(bullet);
      if (tokens.length === 0) continue;
      annotatedForms = tokens;

      const idSets = tokens.map((token) => new Set(findExactIds(db, token)));
      const matchIds = [...intersectSets(idSets)];

      if (matchIds.length !== 1) {
        errors.push(
          `${relPath}:${line}: bullet "${bullet}" matched ${matchIds.length} JMDict entries (expected 1)`,
        );
        continue;
      }
      wordId = String(matchIds[0]);
    }

    const occurrence = { line, context, narration, annotated_forms: annotatedForms.length > 0 ? annotatedForms : undefined };
    if (wordMap.has(wordId)) {
      const entry = wordMap.get(wordId);
      entry.sources.add(title);
      if (!entry.refs.has(title)) entry.refs.set(title, []);
      entry.refs.get(title).push(occurrence);
    } else {
      const refs = new Map([[title, [occurrence]]]);
      wordMap.set(wordId, { id: wordId, sources: new Set([title]), refs });
    }
  }

  // --- Counter extraction ---
  // Build a map: title → (line → counterId) for manual counter annotations.
  // Also treat each counter bullet as a vocab entry for its underlying JMDict word,
  // so that counter-only files (e.g. Counters-Must-Know.md) produce word entries in
  // vocab.json. Deduplication: if a regular vocab bullet already added a ref for
  // this word on the same line, skip adding a second one (the counter-matching logic
  // below will attach ref.counter to the existing ref).
  if (!countersByTitleLine.has(title)) {
    countersByTitleLine.set(title, new Map());
  }
  for (const { counterId, line, context } of extractCounterBullets(content)) {
    const lineMap = countersByTitleLine.get(title);
    if (!lineMap.has(line)) lineMap.set(line, new Set());
    lineMap.get(line).add(counterId);

    const wordId = counterIdToJmdictId.get(counterId);
    if (!wordId) continue;
    const existingEntry = wordMap.get(wordId);
    const alreadyOnLine = existingEntry?.refs.get(title)?.some((r) => r.line === line);
    if (alreadyOnLine) continue;
    const occurrence = { line, context, narration: undefined };
    if (existingEntry) {
      existingEntry.sources.add(title);
      if (!existingEntry.refs.has(title)) existingEntry.refs.set(title, []);
      existingEntry.refs.get(title).push(occurrence);
    } else {
      wordMap.set(wordId, { id: wordId, sources: new Set([title]), refs: new Map([[title, [occurrence]]]) });
    }
  }
}

const allErrors = [...errors, ...grammarErrors];
if (allErrors.length > 0) {
  console.error(`\nPublication blocked by ${allErrors.length} error(s):\n`);
  for (const err of allErrors) console.error(`  ✗ ${err}`);
  process.exit(1);
}

// Enrich with JmdictFurigana data
const furiganaMap = loadJmdictFurigana();
const wordIds = [...wordMap.keys()];
const jmdictWords = idsToWords(db, wordIds);
const jmdictById = new Map();
for (const w of jmdictWords) jmdictById.set(w.id, w);

// Open bccwj.sqlite for corpus frequency lookups. Gracefully absent if not built yet.
const bccwjDb = (() => {
  const dbPath = path.join(projectRoot, "bccwj.sqlite");
  if (!existsSync(dbPath)) return null;
  return new Database(dbPath, { readonly: true });
})();
const bccwjPmwQuery = bccwjDb
  ? bccwjDb.prepare("SELECT pmw FROM bccwj WHERE kanji = ? AND reading = ?")
  : null;

// Manual overrides for words where BCCWJ (UniDic) uses a different canonical
// kanji form than JMDict lists. Keyed by JMDict word ID.
const bccwjOverridesPath = path.join(projectRoot, "bccwj-overrides.json");
const bccwjOverrides = existsSync(bccwjOverridesPath)
  ? JSON.parse(readFileSync(bccwjOverridesPath, "utf8")).overrides
  : {};

// Kanji form tags that indicate a non-standard written spelling.
// Kept in sync with the same constant in kanji-frequency-top10.mjs.
const EXCLUDED_KANJI_TAGS = new Set(["rK", "iK", "sK", "oK", "ateji"]);

function isKanjiChar(ch) {
  const cp = ch.codePointAt(0);
  return (
    (cp >= 0x4e00 && cp <= 0x9fff) ||
    (cp >= 0x3400 && cp <= 0x4dbf) ||
    (cp >= 0x20000 && cp <= 0x2a6df)
  );
}

/**
 * Build the kanji-top-usage data structure.
 *
 * For each kanji character that appears in a normal (non-excluded) kanji form
 * of a corpus word, queries BCCWJ for the top 50 long-unit-word entries by
 * pmw descending, matches each row to a JMDict ID, and checks for JMDict-common
 * words that have no BCCWJ match (possible UniDic canonicalization mismatches).
 *
 * @param {object[]} words - final corpus word array (each has .id)
 * @param {Map<string, object>} jmdictById - JMDict entry map keyed by entry ID
 * @param {Set<string>} corpusWordIds - set of JMDict IDs in the corpus
 * @param {import('better-sqlite3').Database|null} bccwjDatabase - open bccwj.sqlite handle, or null
 * @param {import('better-sqlite3').Database} jmdictDb - open jmdict.sqlite handle
 * @returns {{ [kanjiChar: string]: { totalMatches: number, words: object[] } }}
 */
function buildKanjiTopUsage(words, jmdictById, corpusWordIds, bccwjDatabase, jmdictDb) {
  if (!bccwjDatabase) return {};

  // --- Extract unique kanji characters from non-excluded kanji forms ---
  const kanjiChars = new Set();
  for (const word of words) {
    const jmWord = jmdictById.get(word.id);
    if (!jmWord) continue;
    const normalForms = (jmWord.kanji ?? []).filter(
      (k) => !k.tags.some((t) => EXCLUDED_KANJI_TAGS.has(t))
    );
    for (const form of normalForms) {
      for (const ch of form.text) {
        if (isKanjiChar(ch)) kanjiChars.add(ch);
      }
    }
  }

  // --- Build (kanjiText, hiraganaReading) → JMDict ID lookup per kanji char ---
  // For each kanji character, fetch all JMDict entries that contain it via
  // kanjiAnywhere, then index their non-excluded kanji forms × kana readings.
  const kanjiCharToJmWords = new Map(); // ch → [{id, kanjiText, reading, isCommon}]
  for (const ch of kanjiChars) {
    const entries = kanjiAnywhere(jmdictDb, ch);
    const result = [];
    for (const entry of entries) {
      for (const kf of entry.kanji ?? []) {
        if (kf.tags.some((t) => EXCLUDED_KANJI_TAGS.has(t))) continue;
        if (!kf.text.includes(ch)) continue;
        const isCommon = kf.common || (entry.kana ?? []).some((k) => k.common);
        for (const kana of entry.kana ?? []) {
          result.push({
            id: entry.id,
            kanjiText: kf.text,
            reading: toHiragana(kana.text),
            isCommon,
          });
        }
      }
    }
    kanjiCharToJmWords.set(ch, result);
  }

  // --- Prepare BCCWJ queries ---
  const topQuery = bccwjDatabase.prepare(
    "SELECT kanji, reading, pmw FROM bccwj WHERE kanji LIKE ? ORDER BY pmw DESC LIMIT 50"
  );
  const countQuery = bccwjDatabase.prepare(
    "SELECT count(*) as n FROM bccwj WHERE kanji LIKE ?"
  );
  const exactQuery = bccwjDatabase.prepare(
    "SELECT 1 FROM bccwj WHERE kanji = ? AND reading = ? LIMIT 1"
  );

  // Fallback for BCCWJ rows that use a rare-kanji (rK) or otherwise excluded form
  // that pairToId skips. Looks up by exact (kanji, reading) in jmdict.sqlite
  // regardless of kanji tags, returning the entry ID if found.
  // raws stores every surface form (kanji and kana) with a UNIQUE(text, entry_id) index,
  // so a self-join on entry_id is fast and avoids JSON parsing.
  const jmdictExactQuery = jmdictDb.prepare(`
    SELECT k.entry_id FROM raws k JOIN raws n ON n.entry_id = k.entry_id
    WHERE k.text = ? AND n.text = ?
    LIMIT 1
  `);

  const result = {};

  for (const ch of [...kanjiChars].sort()) {
    const pattern = `%${ch}%`;
    const rows = topQuery.all(pattern);
    const { n: totalMatches } = countQuery.get(pattern);

    if (rows.length === 0) continue; // omit kanji with no BCCWJ data

    // Build a set of (kanjiText\treading) pairs in the top-50 for mismatch check
    const bccwjPairs = new Set(
      rows.map((r) => `${r.kanji}\t${toHiragana(r.reading)}`)
    );

    const jmWords = kanjiCharToJmWords.get(ch) ?? [];

    // Build a lookup map from (kanjiText, hiraganaReading) → JMDict ID.
    // When there are multiple matches prefer corpus words.
    const pairToId = new Map(); // "kanjiText\treading" → id
    for (const { id, kanjiText, reading } of jmWords) {
      const key = `${kanjiText}\t${reading}`;
      const existing = pairToId.get(key);
      if (!existing) {
        pairToId.set(key, id);
      } else if (!corpusWordIds.has(existing) && corpusWordIds.has(id)) {
        // Prefer corpus word when there are multiple matches
        pairToId.set(key, id);
      }
    }

    // Match each BCCWJ row to a JMDict ID
    const wordEntries = rows.map((row) => {
      const hiraganaReading = toHiragana(row.reading);
      const key = `${row.kanji}\t${hiraganaReading}`;
      let id = pairToId.get(key) ?? null;
      if (id === null) {
        // Fallback: BCCWJ may use a rare-kanji (rK) form excluded from pairToId.
        // Query jmdict.sqlite directly by exact (kanji, reading), ignoring tags.
        const hit = jmdictExactQuery.get(row.kanji, hiraganaReading);
        if (hit) id = hit.entry_id;
      }
      if (id === null && row.kanji.endsWith("する") && hiraganaReading.endsWith("する")) {
        // BCCWJ lemmatizes suru-compound verbs as 〜する but JMDict stores the noun stem.
        const stemKanji = row.kanji.slice(0, -2);
        const stemReading = hiraganaReading.slice(0, -2);
        const hit = jmdictExactQuery.get(stemKanji, stemReading);
        if (hit) id = hit.entry_id;
      }
      if (id !== null) {
        return { id, pmw: row.pmw };
      }
      // No JMDict match — include kanji/reading strings so the iOS UI can still display it
      return { id: null, kanji: row.kanji, reading: row.reading, pmw: row.pmw };
    });

    result[ch] = { totalMatches, words: wordEntries };

    // --- Warn about JMDict-common words absent from the top-50 ---
    const seenIds = new Set();
    for (const { id, kanjiText, reading, isCommon } of jmWords) {
      if (!isCommon) continue;
      if (seenIds.has(id)) continue;
      seenIds.add(id);
      // Check all (kanjiText, reading) pairs for this entry
      const matched = jmWords
        .filter((e) => e.id === id)
        .some(
          (e) =>
            bccwjPairs.has(`${e.kanjiText}\t${e.reading}`) ||
            exactQuery.get(e.kanjiText, e.reading)
        );
      if (!matched) {
        console.warn(
          `[kanji-top-usage] ${ch}: common JMDict word ${kanjiText} (${id}) has no BCCWJ match — possible UniDic mismatch?`
        );
      }
    }
  }

  return result;
}

/**
 * Look up the highest BCCWJ frequency for a JMDict word by trying every
 * combination of written form and hiragana-normalized reading.
 * For kana-only words, the written form column in BCCWJ holds the kana text
 * (possibly in katakana), so both original and hiragana-normalized forms are tried.
 * Falls back to bccwj-overrides.json for words where UniDic uses a different
 * canonical kanji than any form listed in JMDict.
 */
function lookupBccwjPerMillionWords(jmWord) {
  if (!bccwjPmwQuery) return null;
  const override = bccwjOverrides[jmWord.id];
  if (override) {
    const row = bccwjPmwQuery.get(override.kanji, override.reading);
    if (row) return row.pmw;
  }
  const kanaTexts = (jmWord.kana ?? []).map((k) => k.text);
  const kanjiTexts = (jmWord.kanji ?? []).map((k) => k.text);
  const searchForms =
    kanjiTexts.length > 0
      ? kanjiTexts
      : [...new Set([...kanaTexts, ...kanaTexts.map(toHiragana)])];
  const hiraganaReadings = [...new Set(kanaTexts.map(toHiragana))];
  let max = null;
  for (const form of searchForms) {
    for (const reading of hiraganaReadings) {
      const row = bccwjPmwQuery.get(form, reading);
      if (row && (max === null || row.pmw > max)) max = row.pmw;
    }
  }
  return max;
}

const words = [...wordMap.values()].map(({ id, sources, refs }) => {
  const references = Object.fromEntries(
    [...refs.entries()].map(([title, occurrences]) => [
      title,
      occurrences.slice().sort((a, b) => a.line - b.line),
    ]),
  );
  // Attach manual counter annotations to refs.
  // countersByTitleLine[title][line] is a Set of counter IDs annotated for that sentence.
  // For each ref, find the annotated counter ID that matches one of this word's known
  // counter IDs (from countersByJmdictId). This correctly assigns ひき to 匹 and とう to
  // 頭 even when both appear in the same sentence with both annotations present.
  for (const [title, refs] of Object.entries(references)) {
    const countersForTitle = countersByTitleLine.get(title);
    if (!countersForTitle) continue;
    const wordCounterIds = (countersByJmdictId.get(id) ?? []).map((c) => c.id);
    for (const ref of refs) {
      const counterSet = countersForTitle.get(ref.line);
      if (!counterSet || counterSet.size === 0) continue;
      const matchingIds = wordCounterIds.filter((cid) => counterSet.has(cid));
      if (matchingIds.length > 0) ref.counter = matchingIds;
    }
  }
  const entry = { id, sources: [...sources], references };
  const jmWord = jmdictById.get(id);
  if (jmWord) {
    entry.writtenForms = buildFuriganaForWord(jmWord, furiganaMap);
    entry.bccwjPerMillionWords = lookupBccwjPerMillionWords(jmWord);
  }
  const flags = existingWordFlags.get(id);
  if (flags?.notCompound) entry.notCompound = true;
  if (flags?.kanjiMeanings) entry.kanjiMeanings = flags.kanjiMeanings;
  return entry;
});

// --- Preserve words from existing vocab.json that aren't in current Markdown ---
// This prevents data loss if the script is interrupted: words not referenced in
// the current Markdown files are preserved as-is from the previous run.
// Exception: references to files that were processed this run are dropped if the
// word wasn't found — the bullet was deleted. Entries with no remaining references
// are dropped entirely.
{
  const currentIds = new Set(words.map((w) => w.id));
  const processedTitles = new Set(stories.map((s) => s.title));
  if (existsSync(outPath)) {
    try {
      const existing = JSON.parse(readFileSync(outPath, "utf8"));
      let droppedEntries = 0;
      let droppedRefs = 0;
      for (const oldWord of existing.words ?? []) {
        if (currentIds.has(oldWord.id)) continue;
        // Drop references to processed files where the word no longer appears.
        // If the bullet were still present, extractVocabBullets would have found it.
        const filteredRefs = {};
        for (const [title, refs] of Object.entries(oldWord.references ?? {})) {
          if (processedTitles.has(title)) {
            droppedRefs += refs.length;
          } else {
            filteredRefs[title] = refs;
          }
        }
        if (Object.keys(filteredRefs).length === 0) {
          droppedEntries++;
          continue;
        }
        const remainingTitles = new Set(Object.keys(filteredRefs));
        const filteredSources = (oldWord.sources ?? []).filter((s) => remainingTitles.has(s));
        words.push({ ...oldWord, sources: filteredSources, references: filteredRefs });
      }
      if (droppedEntries > 0 || droppedRefs > 0) {
        console.log(`  Removed ${droppedRefs} stale reference(s) and ${droppedEntries} orphaned entry/entries from vocab.json`);
      }
    } catch {
      // Corrupt or missing vocab.json — continue with current Markdown only
    }
  }
}

// --- Source ordering ---
// Build a map from source path (or directory path) to an integer sort order.
// Content files contribute their own path using the `order` frontmatter field.
// Directory-level _index.md files contribute the directory path using `order`.
// Files without an `order` field are absent from the map and sort alphabetically
// after all explicitly ordered entries at the same level.
const sourceOrders = {};
for (const filePath of mdFiles) {
  const content = readFileSync(filePath, "utf8");
  const fm = parseFrontmatter(content);
  if (!fm || fm["order"] === undefined) continue;
  const orderVal = parseInt(fm["order"], 10);
  if (isNaN(orderVal)) continue;
  const relPath = path.relative(projectRoot, filePath);
  if (path.basename(relPath) === "_index.md") {
    // Directory entry: key is the directory path (e.g. "Counters")
    const dirPath = path.dirname(relPath);
    if (dirPath !== ".") sourceOrders[dirPath] = orderVal;
  } else if (fm["llm-review"]) {
    // Content file entry: key is the source title (e.g. "Counters/Wago")
    sourceOrders[relPath.replace(/\.md$/i, "")] = orderVal;
  }
}

// --- LLM sense analysis ---

/**
 * Strip HTML ruby markup, keeping the base text (kanji) and discarding
 * the reading annotation. Also strips any remaining HTML tags.
 * Example: <ruby>入り込む<rt>はいりこむ</rt></ruby> → 入り込む
 */
function stripRuby(text) {
  return text
    .replace(/<rt>[^<]*<\/rt>/g, "")
    .replace(/<rp>[^<]*<\/rp>/g, "")
    .replace(/<[^>]+>/g, "");
}

/**
 * Normalize context for cache keying by stripping all HTML tags and trimming
 * whitespace. This ensures that HTML changes (ruby annotations, audio files,
 * etc.) and incidental trailing/leading spaces in the source Markdown don't
 * invalidate cached sense data.
 * Example: また<ruby>夜<rt>よ</rt></ruby>が明ければ <audio .../> → また夜が明ければ
 */
function normalizeContextForCache(context) {
  if (!context) return context;
  return stripRuby(context).trim();
}

/**
 * Compute the per-reference computed_from array: the sorted, deduplicated list
 * of non-null context and narration strings for a single reference object.
 * This is the cache key — recompute when it changes.
 * Contexts are normalized (ruby tags stripped) for cache matching.
 */
function refComputedFrom(ref) {
  const normalizedContext = normalizeContextForCache(ref.context);
  const parts = [normalizedContext, ref.narration].filter((v) => v != null);
  return [...new Set(parts)].sort();
}

/**
 * Build the shared word header used in both single and batch sense prompts.
 */
function buildSensePromptHeader(jmWord) {
  const displayForm =
    jmWord.kanji?.[0]?.text ?? jmWord.kana?.[0]?.text ?? "(unknown)";
  const reading = jmWord.kana?.[0]?.text ?? "";
  const senseList = jmWord.sense
    .map((s, i) => {
      const glosses = s.gloss.map((g) => g.text).join("; ");
      return `${i}: ${glosses}`;
    })
    .join("\n");
  const wordLine = `Word: ${displayForm}${reading && reading !== displayForm ? ` (${reading})` : ""}`;
  return { displayForm, wordLine, senseList };
}

/**
 * Parse and validate the last ```json``` block from a Haiku response,
 * extracting a `sense_indices` array for a single occurrence.
 * Throws on malformed response.
 */
function parseSingleSenseResponse(fullText, displayForm, numSenses) {
  const fenceMatches = [...fullText.matchAll(/```(?:json)?\s*([\s\S]*?)```/gi)];
  if (fenceMatches.length === 0) {
    throw new Error(`Haiku returned no JSON code block for ${displayForm}:\n${fullText}`);
  }
  const jsonText = fenceMatches[fenceMatches.length - 1][1].trim();
  let parsed;
  try {
    parsed = JSON.parse(jsonText);
  } catch {
    throw new Error(`Haiku returned non-JSON for ${displayForm}: ${jsonText}`);
  }
  if (!Array.isArray(parsed.sense_indices)) {
    throw new Error(
      `Haiku response missing sense_indices array for ${displayForm}: ${jsonText}`,
    );
  }
  const senseIndices = parsed.sense_indices.filter(
    (i) => typeof i === "number" && Number.isInteger(i) && i >= 0 && i < numSenses,
  );
  const rawCounter = parsed.counter;
  const counter = Array.isArray(rawCounter) ? rawCounter.filter((c) => typeof c === "string" && c.length > 0) : null;
  return { senseIndices, counter };
}

/**
 * Build the prompt for a single-reference sense analysis call.
 * If counterInfo is provided, also asks whether the word is being used as a counter.
 */
function buildSingleSensePrompt(jmWord, ref, counterInfo = null) {
  const { wordLine, senseList } = buildSensePromptHeader(jmWord);
  const parts = [];
  if (ref.context) parts.push(`Sentence: ${stripRuby(ref.context)}`);
  if (ref.narration) parts.push(`Note: ${ref.narration}`);
  const contextBlock = parts.join("\n");

  let prompt = (
    `You are helping a Japanese language learner understand which sense of a word is used in a specific sentence.\n\n` +
    `${wordLine}\n\n` +
    `JMDict senses (0-indexed):\n${senseList}\n\n` +
    `${contextBlock}\n\n` +
    `Which sense(s) does this specific occurrence of the word use? ` +
    `A sentence may cover more than one sense if it is metaphorical or genuinely ambiguous. ` +
    `Use an empty array if the context is insufficient to determine.\n`
  );

  if (counterInfo && counterInfo.length > 0) {
    const counterList = counterInfo.map((c) => `"${c.id}" (${c.whatItCounts})`).join(", ");
    prompt += (
      `\nAlso: is this word being used as any of these counters? ${counterList} ` +
      `Respond with an array of matching counter ids (e.g., ["${counterInfo[0].id}"]). ` +
      `Multiple counters are allowed if the sentence genuinely uses the word in multiple counter roles. ` +
      `Use an empty array if the word is not being used as a counter here.`
    );
  }

  const exampleJson = counterInfo && counterInfo.length > 0
    ? `{"sense_indices": [0], "counter": []}`
    : `{"sense_indices": [0]}`;
  prompt += `\nThink step by step, then end your response with a JSON code block:\n` +
    `\`\`\`json\n${exampleJson}\n\`\`\``;

  return prompt;
}

/**
 * Call Haiku to determine which JMDict sense(s) a single sentence uses the
 * word in. Returns an array of valid 0-based sense indices and the full raw
 * response text (for the reasoning log).
 * Throws on API error or malformed response (caller handles abort).
 */
async function analyzeReferenceSense(anthropic, jmWord, ref, counterInfo = null) {
  const { displayForm } = buildSensePromptHeader(jmWord);
  const prompt = buildSingleSensePrompt(jmWord, ref, counterInfo);

  const response = await anthropic.messages.create({
    model: "claude-haiku-4-5-20251001",
    max_tokens: 800,
    messages: [{ role: "user", content: prompt }],
  });

  const fullText = response.content[0].text;
  const { senseIndices, counter } = parseSingleSenseResponse(fullText, displayForm, jmWord.sense.length);
  return { senseIndices, counter, reasoning: fullText };
}

/**
 * Call Haiku once to determine which JMDict sense(s) each of several
 * occurrences of the same word uses. Returns one result object per ref
 * (in the same order), each with senseIndices and the shared reasoning text.
 * Throws on API error or malformed response (caller handles abort).
 */
// counterInfoPerRef: array parallel to refs, each element is the counterInfo array for that
// ref (or null if the ref already has a manual counter annotation or isn't counter-capable).
async function analyzeReferencesSenseBatch(anthropic, jmWord, refs, counterInfoPerRef) {
  const { displayForm, wordLine, senseList } = buildSensePromptHeader(jmWord);

  const anyCounterQuestions = counterInfoPerRef.some((ci) => ci && ci.length > 0);

  const occurrenceBlocks = refs
    .map((ref, i) => {
      const parts = [];
      if (ref.context) parts.push(`Sentence: ${stripRuby(ref.context)}`);
      if (ref.narration) parts.push(`Note: ${ref.narration}`);
      let block = `Occurrence ${i}:\n${parts.length ? parts.join("\n") : "(no context)"}`;
      const ci = counterInfoPerRef[i];
      if (ci && ci.length > 0) {
        const list = ci.map((c) => `"${c.id}" (${c.whatItCounts})`).join(", ");
        block += `\n(Also: is this word used as any of these counters? ${list} Set counter to an array of matching ids, or [] if not used as a counter.)`;
      }
      return block;
    })
    .join("\n\n");

  const exampleEntry = anyCounterQuestions
    ? `{"sense_indices": [0], "counter": []}`
    : `{"sense_indices": [0]}`;
  const exampleJson = `{"occurrences": [${exampleEntry}, {"sense_indices": [1, 2]}]}`;

  const prompt =
    `You are helping a Japanese language learner understand which sense of a word is used in each of several sentences.\n\n` +
    `${wordLine}\n\n` +
    `JMDict senses (0-indexed):\n${senseList}\n\n` +
    `${occurrenceBlocks}\n\n` +
    `For each occurrence (in order), which sense(s) does the word use? ` +
    `An occurrence may cover more than one sense if it is metaphorical or genuinely ambiguous. ` +
    `Use an empty array if the context is insufficient to determine. ` +
    `Think step by step for each occurrence, then end your response with a single JSON code block ` +
    `containing an array with exactly ${refs.length} entries (one per occurrence):\n` +
    "```json\n" + exampleJson + "\n```";

  const response = await anthropic.messages.create({
    model: "claude-haiku-4-5-20251001",
    max_tokens: 300 + 400 * refs.length,
    messages: [{ role: "user", content: prompt }],
  });

  const fullText = response.content[0].text;

  const fenceMatches = [...fullText.matchAll(/```(?:json)?\s*([\s\S]*?)```/gi)];
  if (fenceMatches.length === 0) {
    throw new Error(`Haiku returned no JSON code block for ${displayForm} (batch):\n${fullText}`);
  }
  const jsonText = fenceMatches[fenceMatches.length - 1][1].trim();
  let parsed;
  try {
    parsed = JSON.parse(jsonText);
  } catch {
    throw new Error(`Haiku returned non-JSON for ${displayForm} (batch): ${jsonText}`);
  }
  if (!Array.isArray(parsed.occurrences) || parsed.occurrences.length !== refs.length) {
    throw new Error(
      `Haiku batch response has ${parsed.occurrences?.length} entries but expected ${refs.length} for ${displayForm}: ${jsonText}`,
    );
  }

  return parsed.occurrences.map((occ, i) => ({
    senseIndices: (occ.sense_indices ?? []).filter(
      (i) => typeof i === "number" && Number.isInteger(i) && i >= 0 && i < jmWord.sense.length,
    ),
    counter: counterInfoPerRef[i] ? (Array.isArray(occ.counter) ? occ.counter.filter((c) => typeof c === "string" && c.length > 0) : null) : undefined,
    reasoning: fullText,
  }));
}

/**
 * Build a prompt for Haiku to identify which kanjidic2 meanings are active in a word.
 * allForms: all written forms from writtenForms (e.g. ["入り口", "入口", "這入口"]),
 * used so Haiku understands which form each kanji comes from.
 */
function buildKanjiMeaningsPrompt(jmWord, kanjiMeaningsData, allForms) {
  const definition = jmWord.sense
    .slice(0, 3)
    .map((s) => s.gloss.map((g) => g.text).join("; "))
    .join(" / ");

  const wordLine = allForms.length > 1
    ? `Word: ${allForms[0]} (also written: ${allForms.slice(1).join(", ")})`
    : `Word: ${allForms[0] ?? jmWord.kanji?.[0]?.text ?? jmWord.kana?.[0]?.text}`;

  // Numbered list so Haiku sees each meaning as a discrete item and returns
  // the exact string (important for multi-part meanings like "counter for birds, rabbits").
  const kanjiBlocks = kanjiMeaningsData.map(({ kanji, meanings }) => {
    const numbered = meanings.map((m, i) => `  ${i + 1}. "${m}"`).join("\n");
    return `${kanji}:\n${numbered}`;
  }).join("\n");

  const exampleJson = kanjiMeaningsData
    .map(({ kanji, meanings }) => `"${kanji}": ["${meanings[0]}"]`)
    .join(", ");

  const prompt =
    `You are helping identify which meanings of individual kanji are used in a Japanese word.\n\n` +
    `${wordLine}\n` +
    `Definition: ${definition}\n\n` +
    `For each kanji below, identify which numbered meanings apply to this word's sense.\n` +
    `Copy the meaning strings exactly as written — do not paraphrase or split them.\n\n` +
    `${kanjiBlocks}\n\n` +
    `For each kanji, give a one-sentence rationale, then end with a JSON code block ` +
    `whose values are arrays of the exact meaning strings chosen:\n` +
    `\`\`\`json\n{${exampleJson}}\n\`\`\``;

  return prompt;
}

/**
 * Call Haiku to determine which kanjidic2 meanings are active in a word.
 * Returns a map from kanji character to array of active meanings.
 * Throws on API error or malformed response.
 */
async function analyzeKanjiMeanings(anthropic, jmWord, kanjiMeaningsData, allForms) {
  const displayForm = allForms[0] ?? jmWord?.kanji?.[0]?.text ?? jmWord?.kana?.[0]?.text ?? "(unknown)";
  const prompt = buildKanjiMeaningsPrompt(jmWord, kanjiMeaningsData, allForms);

  const response = await anthropic.messages.create({
    model: "claude-haiku-4-5-20251001",
    max_tokens: 300,
    messages: [{ role: "user", content: prompt }],
  });

  const fullText = response.content[0].text;
  const fenceMatches = [...fullText.matchAll(/```(?:json)?\s*([\s\S]*?)```/gi)];
  if (fenceMatches.length === 0) {
    throw new Error(`Haiku returned no JSON code block for kanji meanings of ${displayForm}:\n${fullText}`);
  }

  const jsonText = fenceMatches[fenceMatches.length - 1][1].trim();
  let parsed;
  try {
    parsed = JSON.parse(jsonText);
  } catch {
    throw new Error(`Haiku returned non-JSON for kanji meanings of ${displayForm}: ${jsonText}`);
  }

  // Validate and normalize the response. Always include every kanji (even with
  // an empty array) so the stored object is a complete sentinel — future runs
  // will not re-analyze words that Haiku already evaluated.
  const result = {};
  for (const { kanji, meanings } of kanjiMeaningsData) {
    const selected = parsed[kanji];
    // Default to empty array if Haiku omitted the key or returned non-array.
    const validMeanings = Array.isArray(selected)
      ? selected.filter((m) => meanings.includes(m))
      : [];
    result[kanji] = validMeanings;
  }

  return { result, reasoning: fullText };
}

// All Haiku calls (sense analysis and kanji meanings) are logged here so every
// LLM response can be reviewed after the run. Written incrementally so Ctrl-C
// does not lose entries already collected.
const reasoningLogPath = `/tmp/sense-reasoning-${Date.now()}.log`;
const reasoningLines = [];
console.log(`  Sense reasoning log → ${reasoningLogPath}`);

// Run per-reference sense analysis.
// --no-llm: carry forward cached llm_sense values but skip all Haiku calls.
let counterPotentialCount = 0;      // counter-capable words with unevaluated senses
let counterSkippedCount = 0;        // those skipped due to --max-senses or --no-llm
{
  const anthropic = noLlm ? null : new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });
  let refsAnalyzed = 0;
  let noLlmSkippedCount = 0; // refs that need LLM but were skipped by --no-llm

  // Pre-populate every ref that can be resolved without an LLM call so that
  // the incremental vocab.json writes below never clobber previously-computed
  // data for entries not yet reached in the loop.

  for (const word of words) {
    const jmWord = jmdictById.get(word.id);
    for (const refs of Object.values(word.references ?? {})) {
      for (const ref of refs) {
        if (ref.counter?.length) {
          // ref.counter was set from manual counter bullets — we know exactly which
          // counter(s) are in use, so derive sense_indices directly from counters.json
          // senseIndex fields without calling Haiku.
          const counterEntries = (countersByJmdictId.get(word.id) ?? []).filter((c) =>
            ref.counter.includes(c.id),
          );
          const senseIndices = [
            ...new Set(counterEntries.flatMap((c) => c.senseIndex ?? [])),
          ].sort((a, b) => a - b);
          ref.llm_sense = { sense_indices: senseIndices, computed_from: refComputedFrom(ref) };
          continue;
        }
        if (!jmWord) {
          ref.llm_sense = { sense_indices: [0], computed_from: refComputedFrom(ref), counter: null };
        } else if (jmWord.sense.length <= 1) {
          const computedFrom = refComputedFrom(ref);
          const counterInfo = countersByJmdictId.get(word.id);
          if (counterInfo && !ref.counter?.length) {
            const trivialCounter = counterInfo.find(hasSenseIndices);
            if (trivialCounter) {
              // The JMDict-tagged counter sense IS the word's only sense — no ambiguity,
              // no LLM call needed. Mark this counter trivially.
              ref.llm_sense = { sense_indices: [0], computed_from: computedFrom, counter: [trivialCounter.id] };
            } else if (computedFrom.length > 0) {
              // All counters.json entries for this word have senseIndex: null — the JMDict
              // entry has no ctr-tagged sense, so we can't trivially infer counter usage.
              // Check cache; if uncached, leave llm_sense unset so the LLM loop handles it.
              const cached = existingRefSense.get(`${word.id}|${JSON.stringify(computedFrom)}`);
              if (cached) ref.llm_sense = cached;
            } else {
              ref.llm_sense = { sense_indices: [0], computed_from: [], counter: null };
            }
          } else {
            ref.llm_sense = { sense_indices: [0], computed_from: computedFrom, counter: null };
          }
        } else {
          const computedFrom = refComputedFrom(ref);
          if (computedFrom.length === 0) {
            ref.llm_sense = { sense_indices: [], computed_from: [], counter: null };
          } else {
            const cached = existingRefSense.get(`${word.id}|${JSON.stringify(computedFrom)}`);
            if (cached) ref.llm_sense = cached;
          }
        }
      }
    }
  }

  // Loop over every ref. Each ref is now either already resolved (llm_sense set
  // above) or genuinely needs a Haiku call. After each Haiku call (or batch call)
  // write vocab.json — safe because every ref not yet reached already has its
  // llm_sense pre-populated.
  //
  // When a word appears multiple times in the same file, all uncached occurrences
  // are sent in a single batched Haiku call instead of one call per occurrence.
  for (const word of words) {
    const jmWord = jmdictById.get(word.id);
    if (!jmWord) continue;
    if (jmWord.sense.length <= 1) {
      // Single-sense words are normally resolved trivially in pre-population.
      // Exception: counter-capable words where all counters.json entries have
      // senseIndex: null (no ctr-tagged sense in JMDict). Those need an LLM call
      // to detect counter usage and may have uncached refs left unset above.
      const ci = countersByJmdictId.get(word.id);
      if (!ci || ci.some(hasSenseIndices)) continue;
    }

    const displayForm = jmWord?.kanji?.[0]?.text ?? jmWord?.kana?.[0]?.text ?? word.id;

    for (const [title, refs] of Object.entries(word.references ?? {})) {
      const uncachedRefs = refs.filter((ref) => !ref.llm_sense);
      if (uncachedRefs.length === 0) continue;

      const counterInfo = countersByJmdictId.get(word.id);

      if (refsAnalyzed >= maxSenses) {
        for (const ref of uncachedRefs) {
          console.log(`  Would analyze ${displayForm} [${title}:${ref.line}] (skipped, --max-senses limit reached)`);
          // Only show counter detection prompt if the ref doesn't already have a manual counter annotation
          const counterInfoForRef = ref.counter?.length ? null : counterInfo;
          console.log(`  Prompt:\n    > ${buildSingleSensePrompt(jmWord, ref, counterInfoForRef).replaceAll(/\n/g, '\n    > ')}\n`);
          if (counterInfoForRef) counterSkippedCount++;
        }
        continue;
      }
      if (noLlm) {
        for (const ref of uncachedRefs) {
          console.log(`  Would analyze ${displayForm} [${title}:${ref.line}] (skipped by --no-llm)`);
          const counterInfoForRef = ref.counter?.length ? null : counterInfo;
          console.log(`  Prompt:\n    > ${buildSingleSensePrompt(jmWord, ref, counterInfoForRef).replaceAll(/\n/g, '\n    > ')}\n`);
          if (counterInfoForRef) counterSkippedCount++;
        }
        noLlmSkippedCount += uncachedRefs.length;
        continue;
      }

      let results;
      if (uncachedRefs.length === 1) {
        const ref = uncachedRefs[0];
        process.stdout.write(
          `  Analyzing ${displayForm} [${title}:${ref.line}] (${refsAnalyzed + 1}/${maxSenses === Infinity ? "all" : maxSenses})… `,
        );
        const counterInfoForRef = ref.counter ? null : counterInfo;
        const { senseIndices, counter, reasoning } = await analyzeReferenceSense(anthropic, jmWord, ref, counterInfoForRef);
        process.stdout.write(`→ [${senseIndices.join(", ")}]\n`);
        results = [{ senseIndices, counter, reasoning }];
      } else {
        const lines = uncachedRefs.map((r) => r.line).join(", ");
        process.stdout.write(
          `  Analyzing ${displayForm} [${title}:lines ${lines}] (${uncachedRefs.length} occurrences, batch; ${refsAnalyzed + 1}–${refsAnalyzed + uncachedRefs.length}/${maxSenses === Infinity ? "all" : maxSenses})… `,
        );
        const counterInfoPerRef = uncachedRefs.map((ref) => (ref.counter?.length ? null : counterInfo));
        results = await analyzeReferencesSenseBatch(anthropic, jmWord, uncachedRefs, counterInfoPerRef);
        process.stdout.write(
          `→ [${results.map((r) => `[${r.senseIndices.join(", ")}]`).join(", ")}]\n`,
        );
      }

      for (let i = 0; i < uncachedRefs.length; i++) {
        const ref = uncachedRefs[i];
        const { senseIndices, counter, reasoning } = results[i];
        const computedFrom = refComputedFrom(ref);
        // Manual counter annotations go in ref.counter (sibling to llm_sense)
        // LLM-detected counters go in llm_sense.counter (null = asked but not a counter; key absent = never asked)
        const llmSenseObj = { sense_indices: senseIndices, computed_from: computedFrom };
        if (counterInfo && !ref.counter?.length) {
          llmSenseObj.counter = counter ?? null;
        }
        llmSenseObj.reasoning = reasoning;
        ref.llm_sense = llmSenseObj;
        reasoningLines.push(
          `${"=".repeat(60)}\n${displayForm}  [${title}:${ref.line}]  →  [${senseIndices.join(", ")}]${counter?.length ? ` (counter: ${counter.join(", ")})` : ""}${ref.counter?.length ? ` [manual: ${ref.counter.join(", ")}]` : ""}\n${"=".repeat(60)}\n${reasoning}\n`,
        );
      }
      writeFileSync(reasoningLogPath, reasoningLines.join("\n"));
      refsAnalyzed += uncachedRefs.length;

      writeFileSync(outPath, JSON.stringify({
        generatedAt: new Date().toISOString(),
        stories: stories.map(({ title }) => ({ title })),
        words,
        sourceOrders,
      }, null, 2) + "\n");
    }
  }

  // Count potential counter senses that exist with llm_sense but lack a counter key
  for (const word of words) {
    const jmWord = jmdictById.get(word.id);
    const counterInfo = countersByJmdictId.get(word.id);
    if (counterInfo && jmWord) {
      const displayForm = jmWord?.kanji?.[0]?.text ?? jmWord?.kana?.[0]?.text ?? word.id;
      for (const [title, refs] of Object.entries(word.references ?? {})) {
        for (const ref of refs) {
          if (ref.llm_sense && !("counter" in ref.llm_sense) && !ref.counter) {
            console.log(`  Would analyze ${displayForm} [${title}:${ref.line}] (potential counter sense found, counter field unevaluated)`);
            counterPotentialCount++;
          }
        }
      }
    }
  }

  // Safety check: refuse to write vocab.json if --no-llm skipped any refs that
  // need LLM analysis. Writing with missing llm_sense corrupts the cache for all
  // future runs (they seed from vocab.json, so once an entry is written without
  // llm_sense it can never be recovered from cache).
  if (noLlmSkippedCount > 0) {
    console.error(
      `\nERROR: --no-llm skipped ${noLlmSkippedCount} ref(s) that need LLM sense analysis.` +
      `\nvocab.json was NOT written to prevent data loss.` +
      `\nRun without --no-llm to analyze these refs and write vocab.json.`,
    );
    process.exit(1);
  }

  // Safety check: verify that no ref lost its llm_sense compared to what was in
  // vocab.json at startup. This catches cache-restoration bugs before they corrupt
  // the file.
  {
    const lostEntries = [];
    for (const word of words) {
      for (const refs of Object.values(word.references ?? {})) {
        for (const ref of refs) {
          if (!ref.llm_sense) {
            const computedFrom = refComputedFrom(ref);
            if (computedFrom.length === 0) continue;
            const key = `${word.id}|${JSON.stringify(computedFrom)}`;
            if (existingRefSense.has(key)) {
              // This ref was in the cache but somehow didn't get restored — this
              // should never happen and indicates a bug in the cache-restoration logic.
              const jmWord = jmdictById.get(word.id);
              const displayForm = jmWord?.kanji?.[0]?.text ?? jmWord?.kana?.[0]?.text ?? word.id;
              lostEntries.push(`  ${displayForm} [${Object.keys(word.references ?? {}).join(", ")}:${ref.line}]`);
            }
          }
        }
      }
    }
    if (lostEntries.length > 0) {
      console.error(
        `\nERROR: ${lostEntries.length} ref(s) are in the cache but were not restored — this is a bug:`,
      );
      for (const entry of lostEntries) console.error(entry);
      console.error("vocab.json was NOT written to prevent data loss.");
      process.exit(1);
    }
  }
}

// Analyze kanji meanings.
// --no-llm: carry forward cached kanjiMeanings values but skip all Haiku calls.
// --dry-run: skip all LLM calls entirely (no token burn).
if (!dryRun) {
  const kanjidicDB = new Database(KANJIDIC2_DB, { readonly: true });
  const anthropic = noLlm ? null : new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });

  console.log("\nAnalyzing kanji meanings…");
  let kanjiAnalyzed = 0;

  const kanjidicStmt = kanjidicDB.prepare("SELECT meanings FROM kanji WHERE literal = ?");

  for (const word of words) {
    const jmWord = jmdictById.get(word.id);
    if (!word.writtenForms?.some((f) => f.forms?.length > 0)) continue;

    // If kanjiMeanings already exists (from cache), it covers all writtenForms
    // kanji — no need to re-analyze.
    const flags = existingWordFlags.get(word.id);
    if (flags?.kanjiMeanings) {
      word.kanjiMeanings = flags.kanjiMeanings;
      continue;
    }

    // Collect all written forms and unique kanji from writtenForms
    // (maximum-kanji collapsed forms). Showing all forms in the prompt lets
    // Haiku understand which form each kanji comes from (e.g. 這 comes from
    // 這入口, not 入り口).
    const allForms = [...new Set(
      (word.writtenForms ?? []).flatMap((rf) => rf.forms ?? []).map((f) => f.text),
    )];
    const uniqueKanji = [...new Set(
      (word.writtenForms ?? []).flatMap((rf) => rf.forms ?? []).flatMap((f) => f.text.split("")),
    )];

    const kanjiMeaningsData = [];
    for (const kanji of uniqueKanji) {
      const row = kanjidicStmt.get(kanji);
      if (row?.meanings) {
        try {
          const meanings = JSON.parse(row.meanings);
          if (Array.isArray(meanings) && meanings.length > 0) kanjiMeaningsData.push({ kanji, meanings });
        } catch { /* skip */ }
      }
    }

    if (kanjiMeaningsData.length === 0) continue;

    const displayForm = allForms[0] ?? jmWord?.kanji?.[0]?.text ?? word.id;

    if (kanjiAnalyzed >= maxKanjiSenses) {
      console.log(`  Would analyze kanji meanings for ${displayForm} (skipped, --max-kanji-senses limit reached)`);
      continue;
    }

    if (noLlm) {
      console.log(`  Would analyze kanji for ${displayForm} (skipped by --no-llm)`);
      continue;
    }

    // Call Haiku to determine active meanings
    kanjiAnalyzed++;
    try {
      process.stdout.write(`  Analyzing kanji meanings for ${displayForm} (${kanjiAnalyzed}/${maxKanjiSenses === Infinity ? "all" : maxKanjiSenses})… `);
      const { result: kanjiMeanings, reasoning } = await analyzeKanjiMeanings(anthropic, jmWord, kanjiMeaningsData, allForms);
      // Always store the result (even if all meaning arrays are empty) so the
      // cache sentinel is set and future runs skip this word.
      word.kanjiMeanings = kanjiMeanings;
      existingWordFlags.set(word.id, { ...existingWordFlags.get(word.id), kanjiMeanings: kanjiMeanings });
      reasoningLines.push(
        `${"=".repeat(60)}\nkanjiMeanings  ${displayForm}  →  ${JSON.stringify(kanjiMeanings)}\n${"=".repeat(60)}\n${reasoning}\n`,
      );
      writeFileSync(reasoningLogPath, reasoningLines.join("\n"));
      process.stdout.write(`✓\n`);
      writeFileSync(outPath, JSON.stringify({
        generatedAt: new Date().toISOString(),
        stories: stories.map(({ title }) => ({ title })),
        words,
        sourceOrders,
      }, null, 2) + "\n");
    } catch (e) {
      console.log(`✗ (${e.message})`);
    }
  }

  if (kanjiAnalyzed > 0) {
    console.log(`Analyzed kanji meanings for ${kanjiAnalyzed} word(s).${maxKanjiSenses !== Infinity ? ` (--max-kanji-senses ${maxKanjiSenses})` : ""}`);
  }
}

// --- Kanji top-usage frequency data ---
// Skip the (slow) rebuild if the word-ID set hasn't changed since the last run.
const kanjiTopUsagePath = path.join(projectRoot, "kanji-top-usage.json");
const currentWordIds = words.map((w) => w.id).sort();
let kanjiTopUsage;
let kanjiCacheHit = false;
if (existsSync(kanjiTopUsagePath)) {
  const cached = JSON.parse(readFileSync(kanjiTopUsagePath, "utf8"));
  if (
    Array.isArray(cached.sourceWordIds) &&
    cached.sourceWordIds.length === currentWordIds.length &&
    cached.sourceWordIds.every((id, i) => id === currentWordIds[i])
  ) {
    kanjiTopUsage = cached.kanji;
    kanjiCacheHit = true;
    console.log(`Kanji top-usage cache hit (${Object.keys(kanjiTopUsage).length} entries) — skipping rebuild.`);
  }
}
if (!kanjiCacheHit) {
  kanjiTopUsage = buildKanjiTopUsage(words, jmdictById, new Set(currentWordIds), bccwjDb, db);
  if (!dryRun) {
    writeFileSync(
      kanjiTopUsagePath,
      JSON.stringify({ generatedAt: new Date().toISOString(), sourceWordIds: currentWordIds, kanji: kanjiTopUsage }, null, 2) + "\n"
    );
    console.log(`Wrote ${Object.keys(kanjiTopUsage).length} kanji entries → ${kanjiTopUsagePath}`);
  } else {
    console.log(`[DRY RUN] Would write ${Object.keys(kanjiTopUsage).length} kanji entries to ${kanjiTopUsagePath}`);
  }
}

const output = {
  generatedAt: new Date().toISOString(),
  stories: stories.map(({ title }) => ({ title })),
  words,
  sourceOrders,
};

if (!dryRun) {
  writeFileSync(outPath, JSON.stringify(output, null, 2) + "\n");
  console.log(
    `\nWrote ${words.length} words from ${stories.length} story/stories → ${outPath}`,
  );
  if (counterPotentialCount > 0 || counterSkippedCount > 0) {
    console.log(`- ${counterPotentialCount} potential counter senses found, ${counterSkippedCount} skipped`);
  }
} else {
  console.log(`\n[DRY RUN] Would have written ${words.length} words to ${outPath}`);
}

// --- Grammar JSON ---
const grammarSources = {
  genki: { name: "Genki I & II", type: "textbook" },
  bunpro: { name: "Bunpro", type: "online" },
  dbjg: { name: "Dictionary of Basic Japanese Grammar", type: "book" },
};

const grammarTopics = {};
for (const [topicId, { sources, refs }] of grammarMap) {
  const dbEntry = grammarDb.get(topicId);
  const references = Object.fromEntries(
    [...refs.entries()].map(([source, occs]) => [source, occs]),
  );
  grammarTopics[topicId] = {
    source: dbEntry.source,
    id: dbEntry.id,
    titleEn: dbEntry.titleEn,
    titleJp: dbEntry.titleJp || undefined,
    level: dbEntry.level,
    href: dbEntry.href || undefined,
    aliasOf: dbEntry.aliasOf || undefined,
    sources: [...sources],
    references,
  };
}

const grammarOutput = {
  generatedAt: new Date().toISOString(),
  sources: grammarSources,
  topics: grammarTopics,
};

// Write grammar.json before equivalence check so /cluster-grammar-topics can
// read the latest topics even if this script exits with an error below.
// (Description fields from equivalences are injected after the check below.)
const grammarOutPath = path.join(projectRoot, "grammar.json");
if (!dryRun) {
  writeFileSync(grammarOutPath, JSON.stringify(grammarOutput, null, 2) + "\n");
}

// Validate grammar/grammar-equivalences.json covers all grammar topics
const equivPath = path.join(
  projectRoot,
  "grammar",
  "grammar-equivalences.json",
);
let grammarEquivalencesRaw;
try {
  grammarEquivalencesRaw = JSON.parse(readFileSync(equivPath, "utf-8"));
} catch {
  grammarEquivalencesRaw = [];
}
// Support both old array-of-arrays format and new array-of-objects format
const grammarEquivalences = grammarEquivalencesRaw.map((entry) =>
  Array.isArray(entry) ? { topics: entry } : entry,
);
const coveredTopics = new Set(grammarEquivalences.flatMap((g) => g.topics));
const missingFromEquiv = Object.keys(grammarTopics).filter(
  (id) => !coveredTopics.has(id),
);
if (missingFromEquiv.length > 0) {
  console.error(
    `\nError: ${missingFromEquiv.length} grammar topic(s) missing from grammar/grammar-equivalences.json:`,
  );
  for (const id of missingFromEquiv) {
    console.error(`  - ${id}`);
  }
  console.error(
    `\nRun /cluster-grammar-topics to add them, then re-run this script.`,
  );
  process.exit(1);
}

// Inject equivalence group info into each topic
const topicToGroup = new Map();
for (let i = 0; i < grammarEquivalences.length; i++) {
  for (const id of grammarEquivalences[i].topics) {
    topicToGroup.set(id, i);
  }
}
for (const [id, topic] of Object.entries(grammarTopics)) {
  const groupIdx = topicToGroup.get(id);
  if (groupIdx !== undefined) {
    const group = grammarEquivalences[groupIdx];
    // Only include equivalenceGroup if topic shares a group with others
    if (group.topics.length > 1) {
      topic.equivalenceGroup = group.topics.filter((other) => other !== id);
    }
    // Inject enriched description fields if present
    if (group.summary) topic.summary = group.summary;
    if (group.subUses) topic.subUses = group.subUses;
    if (group.cautions) topic.cautions = group.cautions;
    if (group.stub) topic.stub = group.stub;
    if (group.classicalJapanese) topic.classicalJapanese = group.classicalJapanese;
  }
}

if (!dryRun) {
  writeFileSync(grammarOutPath, JSON.stringify(grammarOutput, null, 2) + "\n");
  console.log(
    `Wrote ${Object.keys(grammarTopics).length} grammar topics → ${grammarOutPath}`,
  );
}

// --- Corpus JSON ---
// Build per-title vocab and grammar counts from the already-compiled maps.
const vocabCountByTitle = new Map();
for (const { sources } of wordMap.values()) {
  for (const title of sources) {
    vocabCountByTitle.set(title, (vocabCountByTitle.get(title) ?? 0) + 1);
  }
}
const grammarCountByTitle = new Map();
for (const { sources } of grammarMap.values()) {
  for (const title of sources) {
    grammarCountByTitle.set(title, (grammarCountByTitle.get(title) ?? 0) + 1);
  }
}

// Build per-title counter enrollment counts: unique counter IDs seen per story.
// Sources: manual "- counter:id" bullets (countersByTitleLine) and LLM-detected
// counter usage (ref.llm_sense?.counter). Counts unique IDs, not occurrences,
// parallel to how vocabCount counts unique word IDs.
const counterIdsByTitle = new Map();
for (const [title, lineMap] of countersByTitleLine) {
  for (const counterSet of lineMap.values()) {
    for (const counterId of counterSet) {
      if (!counterIdsByTitle.has(title)) counterIdsByTitle.set(title, new Set());
      counterIdsByTitle.get(title).add(counterId);
    }
  }
}
for (const word of words) {
  for (const [title, refs] of Object.entries(word.references ?? {})) {
    for (const ref of refs) {
      for (const counterId of ref.llm_sense?.counter ?? []) {
        if (!counterIdsByTitle.has(title)) counterIdsByTitle.set(title, new Set());
        counterIdsByTitle.get(title).add(counterId);
      }
    }
  }
}

const corpusEntries = stories.map(({ title, content: rawMarkdown }) => ({
  title,
  markdown: rawMarkdown,
  vocabCount: vocabCountByTitle.get(title) ?? 0,
  grammarCount: grammarCountByTitle.get(title) ?? 0,
  counterCount: counterIdsByTitle.get(title)?.size ?? 0,
}));

// Collect all relative image references across all stories.
// Each image is published at its natural repo-relative path (same subdirectory as the story).
const imageRefPattern = /!\[[^\]]*\]\(([^)]+)\)/g;
const seenImages = new Set();
const corpusImages = [];
for (const { title, content } of stories) {
  const storyDir = path.join(projectRoot, path.dirname(title));
  for (const match of content.matchAll(imageRefPattern)) {
    const imgPath = match[1].replace(/^\.\//, ""); // strip leading ./
    if (imgPath.startsWith("http")) continue;       // skip absolute URLs
    const localPath = path.resolve(storyDir, imgPath);
    // Skip images that resolve outside the project root (e.g. via ../ paths)
    if (!localPath.startsWith(projectRoot + path.sep)) {
      console.warn(`  Warning: image outside project root, skipping: ${imgPath} (in ${title})`);
      continue;
    }
    // repoPath mirrors the story's subdirectory structure
    const repoPath = path.relative(projectRoot, localPath);
    if (!seenImages.has(repoPath)) {
      seenImages.add(repoPath);
      corpusImages.push({ repoPath });
    }
  }
}

const corpusOutPath = path.join(projectRoot, "corpus.json");
if (!dryRun) {
  writeFileSync(
    corpusOutPath,
    JSON.stringify({ images: corpusImages, entries: corpusEntries }, null, 2) + "\n",
  );
  console.log(
    `Wrote ${corpusEntries.length} corpus entries, ${corpusImages.length} image(s) → ${corpusOutPath}`,
  );
}

// --- Compound verb detection ---
await checkAndUpdateCompoundVerbs({ dryRun: dryRun || noLlm, maxLlm: maxCompoundVerbs });
