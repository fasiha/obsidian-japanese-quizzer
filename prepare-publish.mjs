/**
 * prepare-publish.mjs
 * Validates all llm-review Markdown files and compiles a single vocab.json.
 *
 * Requirements per file:
 *   - `llm-review: true` in YAML frontmatter
 *   - All vocab bullets must resolve to exactly one JMDict entry
 *
 * Output: vocab.json at project root
 * {
 *   "generatedAt": "<ISO timestamp>",
 *   "stories": [{ "title": "path/to/File" }],
 *   "words": [{ "id": "1234567", "sources": ["path/to/File"] }]
 * }
 *
 * Words appearing in multiple stories accumulate sources.
 * All other word data (forms, meanings) is derived from bundled jmdict.sqlite in the app.
 *
 * Usage: node prepare-publish.mjs
 */

import { setup, findExactIds, idsToWords } from "jmdict-simplified-node";
import { readFileSync, writeFileSync } from "fs";
import path from "path";
import {
  findMdFiles,
  extractJapaneseTokens,
  isJapanese,
  intersectSets,
  parseFrontmatter,
  projectRoot,
  JMDICT_DB,
  loadGrammarDatabases,
  extractGrammarBullets,
} from "./.claude/scripts/shared.mjs";

// --- JmdictFurigana enrichment ---

/**
 * Convert katakana characters to their hiragana equivalents.
 * Used to deduplicate readings that differ only in script (e.g. のど vs ノド).
 */
function toHiragana(str) {
  return str.replace(/[\u30A1-\u30F6]/g, (c) =>
    String.fromCharCode(c.charCodeAt(0) - 0x60),
  );
}

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

/**
 * Determine if `maybeParent` is a "more kanji" version of `elt` — i.e., the
 * two furigana arrays represent the same text but `maybeParent` uses kanji
 * (ruby+rt) where `elt` uses plain kana (string).
 *
 * Works by nibbling both arrays from the front in parallel:
 * - Matching strings: consume character by character
 * - Matching ruby objects: consume if ruby+rt are identical
 * - String in elt vs ruby in maybeParent: consume if elt's string starts with
 *   maybeParent's rt (parent has kanji where child has plain kana)
 *
 * Returns true only if the entire arrays are consumed with no mismatches.
 */
function isFuriganaParent(elt, maybeParent) {
  if (maybeParent === elt) return false;

  const xx = elt.furigana.map((o) => (o.rt ? o : o.ruby));
  const yy = maybeParent.furigana.map((o) => (o.rt ? o : o.ruby));

  while (xx.length || yy.length) {
    const x = xx[0];
    const y = yy[0];

    if (!x || !y) return false;

    if (typeof x === typeof y) {
      if (typeof x === "string") {
        // Both plain strings — nibble character by character
        if (y.startsWith(x[0])) {
          if (y.length > 1) yy[0] = y.slice(1);
          else yy.shift();
          if (x.length > 1) xx[0] = x.slice(1);
          else xx.shift();
        } else {
          return false;
        }
      } else {
        // Both ruby — must match exactly
        if (x.ruby === y.ruby && x.rt === y.rt) {
          xx.shift();
          yy.shift();
        } else {
          return false;
        }
      }
    } else {
      // Mixed: elt has plain kana, maybeParent has ruby (kanji) — the parent
      // relationship we're looking for
      if (typeof x === "string" && x.startsWith(y.rt)) {
        if (x.length > y.rt.length) xx[0] = x.slice(y.rt.length);
        else xx.shift();
        yy.shift();
      } else {
        return false;
      }
    }
  }

  return true;
}

/**
 * Build furigana data for a single JMDict word.
 *
 * Returns: array of { reading: string, forms: [{ furigana: [...], text: string }] }
 * grouped by reading. Within each reading, lesser-kanji variants are collapsed
 * (e.g. "たき木" is dropped in favor of "焚き木" for reading "たきぎ").
 * Forms preserve JMDict kanji array order.
 *
 * For kana-only words (no kanji entries), returns [{ reading: kanaText, forms: [] }].
 */
function buildFuriganaForWord(word, furiganaMap) {
  if (!word.kanji || word.kanji.length === 0) {
    // Kana-only word
    return word.kana
      .filter((k) => !k.tags || !k.tags.includes("ik"))
      .map((k) => ({ reading: k.text, forms: [] }));
  }

  // Determine which readings apply to which kanji forms (preserving JMDict order)
  const kanjiTexts = word.kanji
    .filter((k) => !k.tags || !k.tags.includes("iK"))
    .map((k) => k.text);
  const kanaEntries = word.kana.filter(
    (k) => !k.tags || !k.tags.includes("ik"),
  );

  // Group by reading, normalizing katakana to hiragana so readings that differ
  // only in script (e.g. のど vs ノド) are merged into one group.
  const byReading = new Map(); // hiragana-normalized reading -> [{furigana, text}]

  for (const kana of kanaEntries) {
    const applicableKanji =
      kana.appliesToKanji && kana.appliesToKanji[0] === "*"
        ? kanjiTexts
        : (kana.appliesToKanji || []).filter((k) => kanjiTexts.includes(k));

    // Build forms in JMDict kanji array order
    const forms = [];
    for (const kanjiText of applicableKanji) {
      const furiganaEntries = furiganaMap.get(kanjiText) || [];
      const match = furiganaEntries.find((e) => e.reading === kana.text);
      if (match) {
        forms.push({ furigana: match.furigana, text: kanjiText });
      }
    }

    // Collapse: remove forms that have a "parent" (more-kanji version) in the list
    const collapsed = forms.filter(
      (f) => !forms.some((other) => isFuriganaParent(f, other)),
    );

    const key = toHiragana(kana.text);
    if (!byReading.has(key)) {
      byReading.set(key, collapsed);
    } else {
      // Merge, skipping forms whose kanji text is already present (katakana/hiragana
      // variants of the same reading produce identical kanji forms).
      const existing = byReading.get(key);
      const existingTexts = new Set(existing.map((f) => f.text));
      for (const form of collapsed) {
        if (!existingTexts.has(form.text)) {
          existing.push(form);
          existingTexts.add(form.text);
        }
      }
    }
  }

  return [...byReading.entries()].map(([reading, forms]) => ({
    reading,
    forms,
  }));
}

// Return the nearest preceding contiguous prose paragraph before `endIdx` in content.
// Scans backward from `endIdx`, skipping blank lines and entire <details> blocks
// (so intervening Grammar/Vocab blocks between the prose and the target Vocab block
// are transparently skipped). Then collects non-blank lines that are not bullets or
// block-level HTML tags. Inline <ruby> tags within prose lines are preserved.
// Returns joined text, or null if no such paragraph is found.
function extractContextBefore(content, endIdx) {
  const lines = content.slice(0, endIdx).split("\n");
  let i = lines.length - 1;
  // Skip blank lines and entire <details>...</details> blocks going backward.
  while (i >= 0) {
    const trimmed = lines[i].trim();
    if (trimmed === "") {
      i--;
      continue;
    }
    if (trimmed === "</details>") {
      i--;
      while (i >= 0 && !lines[i].trim().startsWith("<details")) i--;
      i--;
      continue;
    }
    break;
  }
  if (i < 0) return null;
  // Collect contiguous prose lines. Stop at blank lines, bullet lines, or
  // block-level <details>/<summary>/</details> lines. Inline <ruby> lines are prose.
  const paraLines = [];
  while (i >= 0) {
    const trimmed = lines[i].trim();
    if (
      trimmed === "" ||
      trimmed.startsWith("-") ||
      trimmed.startsWith("<details") ||
      trimmed.startsWith("</details") ||
      trimmed.startsWith("<summary")
    )
      break;
    paraLines.unshift(trimmed);
    i--;
  }
  return paraLines.length > 0 ? paraLines.join(" ") : null;
}

// Like shared.extractVocabBullets but also returns 1-indexed line numbers,
// bullet narration text (non-Japanese text after the Japanese tokens), and
// the context paragraph preceding the <details> block.
function extractVocabBullets(content) {
  const SUMMARY_REGEXP = /<summary>\s*Vocab\s*<\/summary>/i;
  const DETAILS_REGEXP = /<details\b[^>]*>([\s\S]*?)<\/details>/gi;
  const bullets = [];
  let match;
  while ((match = DETAILS_REGEXP.exec(content)) !== null) {
    const inner = match[1];
    if (!SUMMARY_REGEXP.test(inner)) continue;
    const openingTagLen = match[0].length - inner.length - "</details>".length;
    const context = extractContextBefore(content, match.index);
    const innerStartLine = content
      .slice(0, match.index + openingTagLen)
      .split("\n").length;
    const innerLines = inner.split("\n");
    for (let i = 0; i < innerLines.length; i++) {
      const trimmed = innerLines[i].trim();
      if (!trimmed.startsWith("-")) continue;
      const bullet = trimmed.slice(1).trim();
      if (!bullet) continue;
      // Narration = text after the leading Japanese tokens
      const parts = bullet.split(/\s+/);
      let j = 0;
      while (j < parts.length && parts[j] && isJapanese(parts[j])) j++;
      const narration = parts.slice(j).join(" ").trim() || null;
      bullets.push({ bullet, line: innerStartLine + i, context, narration });
    }
  }
  return bullets;
}

const { db } = await setup(JMDICT_DB);
const grammarDb = loadGrammarDatabases();
const mdFiles = findMdFiles(projectRoot);

const errors = [];
const stories = [];
// Map from word id -> { id, sources: Set<title>, refs: Map<title, Set<lineNumber>> }
const wordMap = new Map();
// Map from grammar topicId -> { topicId, sources: Set<title>, sentences: [] }
const grammarMap = new Map();
const grammarErrors = [];

for (const filePath of mdFiles) {
  const content = readFileSync(filePath, "utf8");
  const fm = parseFrontmatter(content);
  if (!fm?.["llm-review"]) continue;

  const relPath = path.relative(projectRoot, filePath);

  const title = relPath.replace(/\.md$/i, "");
  if (!stories.find((s) => s.title === title)) {
    stories.push({ title });
  }

  // --- Grammar extraction ---
  for (const { topicId, note, line } of extractGrammarBullets(content)) {
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

    if (grammarMap.has(topicId)) {
      grammarMap.get(topicId).sources.add(title);
    } else {
      grammarMap.set(topicId, {
        topicId,
        sources: new Set([title]),
      });
    }
  }

  // --- Vocab extraction ---
  for (const { bullet, line, context, narration } of extractVocabBullets(content)) {
    const tokens = extractJapaneseTokens(bullet);
    if (tokens.length === 0) continue;

    const idSets = tokens.map((token) => new Set(findExactIds(db, token)));
    const matchIds = [...intersectSets(idSets)];

    if (matchIds.length !== 1) {
      errors.push(
        `${relPath}:${line}: bullet "${bullet}" matched ${matchIds.length} JMDict entries (expected 1)`,
      );
      continue;
    }

    const wordId = String(matchIds[0]);

    const occurrence = { line, context, narration };
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

const words = [...wordMap.values()].map(({ id, sources, refs }) => {
  const references = Object.fromEntries(
    [...refs.entries()].map(([title, occurrences]) => [
      title,
      occurrences.slice().sort((a, b) => a.line - b.line),
    ]),
  );
  const entry = { id, sources: [...sources], references };
  const jmWord = jmdictById.get(id);
  if (jmWord) {
    entry.writtenForms = buildFuriganaForWord(jmWord, furiganaMap);
  }
  return entry;
});

const output = {
  generatedAt: new Date().toISOString(),
  stories,
  words,
};

const outPath = path.join(projectRoot, "vocab.json");
writeFileSync(outPath, JSON.stringify(output, null, 2) + "\n");
console.log(
  `\nWrote ${words.length} words from ${stories.length} story/stories → ${outPath}`,
);

// --- Grammar JSON ---
const grammarSources = {
  genki: { name: "Genki I & II", type: "textbook" },
  bunpro: { name: "Bunpro", type: "online" },
  dbjg: { name: "Dictionary of Basic Japanese Grammar", type: "book" },
};

const grammarTopics = {};
for (const [topicId, { sources }] of grammarMap) {
  const dbEntry = grammarDb.get(topicId);
  grammarTopics[topicId] = {
    source: dbEntry.source,
    id: dbEntry.id,
    titleEn: dbEntry.titleEn,
    titleJp: dbEntry.titleJp || undefined,
    level: dbEntry.level,
    href: dbEntry.href || undefined,
    aliasOf: dbEntry.aliasOf || undefined,
    sources: [...sources],
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
writeFileSync(grammarOutPath, JSON.stringify(grammarOutput, null, 2) + "\n");

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
  }
}

writeFileSync(grammarOutPath, JSON.stringify(grammarOutput, null, 2) + "\n");
console.log(
  `Wrote ${Object.keys(grammarTopics).length} grammar topics → ${grammarOutPath}`,
);
