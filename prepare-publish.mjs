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
 *
 * Usage: node prepare-publish.mjs [--no-llm] [--max-senses N] [--max-compound-verbs N]
 */

import { setup, findExactIds, idsToWords } from "jmdict-simplified-node";
import { readFileSync, writeFileSync, existsSync } from "fs";
import Anthropic from "@anthropic-ai/sdk";
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
import { checkAndUpdateCompoundVerbs } from "./.claude/scripts/check-compound-verbs.mjs";

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
// Returns { text, line } where text is the joined sentence text (or null) and line
// is the 1-based line number of the last sentence line found (or null if none found).
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
  if (i < 0) return { text: null, line: null };
  // Collect contiguous prose lines. Stop at blank lines, bullet lines, or
  // block-level <details>/<summary>/</details> lines. Inline <ruby> lines are prose.
  const paraLines = [];
  let lastSentenceLineIdx = i; // 0-indexed; tracks the last (bottom) sentence line
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
  if (paraLines.length === 0) return { text: null, line: null };
  return { text: paraLines.join(" "), line: lastSentenceLineIdx + 1 }; // 1-based
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
    const { text: context, line: sentenceLine } = extractContextBefore(content, match.index);
    // Fallback: use the <details> opening line number if no sentence found above.
    const detailsOpeningLine = content.slice(0, match.index).split("\n").length;
    const line = sentenceLine ?? detailsOpeningLine;
    const innerLines = inner.split("\n");
    for (const innerLine of innerLines) {
      const trimmed = innerLine.trim();
      if (!trimmed.startsWith("-")) continue;
      const bullet = trimmed.slice(1).trim();
      if (!bullet) continue;
      // Narration = text after the leading Japanese tokens (or after the bare ID).
      const parts = bullet.split(/\s+/);
      let j = 0;
      if (/^\d+$/.test(parts[0])) j = 1; // skip bare JMDict ID prefix
      while (j < parts.length && parts[j] && isJapanese(parts[j])) j++;
      const narration = parts.slice(j).join(" ").trim() || null;
      bullets.push({ bullet, line, context, narration });
    }
  }
  return bullets;
}

// --- Command-line flags ---
// --no-llm              : skip all LLM sense-analysis calls and compound verb detection
// --max-senses N        : only run LLM analysis for at most N words (useful for spot-checking)
// --max-compound-verbs N: only run compound verb LLM analysis for at most N suffixes
const args = process.argv.slice(2);
const noLlm = args.includes("--no-llm");
const maxSensesIdx = args.indexOf("--max-senses");
const maxSenses =
  maxSensesIdx !== -1 ? parseInt(args[maxSensesIdx + 1], 10) : Infinity;
const maxCompoundVerbsIdx = args.indexOf("--max-compound-verbs");
const maxCompoundVerbs =
  maxCompoundVerbsIdx !== -1 ? parseInt(args[maxCompoundVerbsIdx + 1], 10) : Infinity;

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
    }
  } catch {
    // Corrupt or missing vocab.json — start fresh
  }
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
    if (directIdMatch) {
      wordId = directIdMatch[1];
    } else {
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
      wordId = String(matchIds[0]);
    }

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
  const flags = existingWordFlags.get(id);
  if (flags?.notCompound) entry.notCompound = true;
  return entry;
});

// --- Preserve words from existing vocab.json that aren't in current Markdown ---
// This prevents data loss if the script is interrupted: words not referenced in
// the current Markdown files are preserved as-is from the previous run.
{
  const currentIds = new Set(words.map((w) => w.id));
  if (existsSync(outPath)) {
    try {
      const existing = JSON.parse(readFileSync(outPath, "utf8"));
      for (const oldWord of existing.words ?? []) {
        if (!currentIds.has(oldWord.id)) {
          words.push(oldWord);
        }
      }
    } catch {
      // Corrupt or missing vocab.json — continue with current Markdown only
    }
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
  return parsed.sense_indices.filter(
    (i) => typeof i === "number" && Number.isInteger(i) && i >= 0 && i < numSenses,
  );
}

/**
 * Call Haiku to determine which JMDict sense(s) a single sentence uses the
 * word in. Returns an array of valid 0-based sense indices and the full raw
 * response text (for the reasoning log).
 * Throws on API error or malformed response (caller handles abort).
 */
async function analyzeReferenceSense(anthropic, jmWord, ref) {
  const { displayForm, wordLine, senseList } = buildSensePromptHeader(jmWord);

  const parts = [];
  if (ref.context) parts.push(`Sentence: ${stripRuby(ref.context)}`);
  if (ref.narration) parts.push(`Note: ${ref.narration}`);
  const contextBlock = parts.join("\n");

  const prompt =
    `You are helping a Japanese language learner understand which sense of a word is used in a specific sentence.\n\n` +
    `${wordLine}\n\n` +
    `JMDict senses (0-indexed):\n${senseList}\n\n` +
    `${contextBlock}\n\n` +
    `Which sense(s) does this specific occurrence of the word use? ` +
    `A sentence may cover more than one sense if it is metaphorical or genuinely ambiguous. ` +
    `Use an empty array if the context is insufficient to determine. ` +
    `Think step by step, then end your response with a JSON code block:\n` +
    "```json\n{\"sense_indices\": [0]}\n```";

  const response = await anthropic.messages.create({
    model: "claude-haiku-4-5-20251001",
    max_tokens: 600,
    messages: [{ role: "user", content: prompt }],
  });

  const fullText = response.content[0].text;
  const validIndices = parseSingleSenseResponse(fullText, displayForm, jmWord.sense.length);
  return { senseIndices: validIndices, reasoning: fullText };
}

/**
 * Call Haiku once to determine which JMDict sense(s) each of several
 * occurrences of the same word uses. Returns one result object per ref
 * (in the same order), each with senseIndices and the shared reasoning text.
 * Throws on API error or malformed response (caller handles abort).
 */
async function analyzeReferencesSenseBatch(anthropic, jmWord, refs) {
  const { displayForm, wordLine, senseList } = buildSensePromptHeader(jmWord);

  const occurrenceBlocks = refs
    .map((ref, i) => {
      const parts = [];
      if (ref.context) parts.push(`Sentence: ${stripRuby(ref.context)}`);
      if (ref.narration) parts.push(`Note: ${ref.narration}`);
      return `Occurrence ${i}:\n${parts.length ? parts.join("\n") : "(no context)"}`;
    })
    .join("\n\n");

  const exampleJson =
    `{"occurrences": [{"sense_indices": [0]}, {"sense_indices": [1, 2]}]}`;

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

  return parsed.occurrences.map((occ) => ({
    senseIndices: (occ.sense_indices ?? []).filter(
      (i) => typeof i === "number" && Number.isInteger(i) && i >= 0 && i < jmWord.sense.length,
    ),
    reasoning: fullText,
  }));
}

// Run per-reference sense analysis.
// --no-llm: carry forward cached llm_sense values but skip all Haiku calls.
{
  const anthropic = noLlm ? null : new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });
  let refsAnalyzed = 0;
  let noLlmSkippedCount = 0; // refs that need LLM but were skipped by --no-llm

  // Open a reasoning log file so we can review Haiku's chain-of-thought later
  const reasoningLogPath = `/tmp/sense-reasoning-${Date.now()}.log`;
  const reasoningLines = [];
  console.log(`  Sense reasoning log → ${reasoningLogPath}`);

  // Pre-populate every ref that can be resolved without an LLM call so that
  // the incremental vocab.json writes below never clobber previously-computed
  // data for entries not yet reached in the loop.
  for (const word of words) {
    const jmWord = jmdictById.get(word.id);
    for (const refs of Object.values(word.references ?? {})) {
      for (const ref of refs) {
        if (!jmWord || jmWord.sense.length <= 1) {
          ref.llm_sense = { sense_indices: [0], computed_from: refComputedFrom(ref) };
        } else {
          const computedFrom = refComputedFrom(ref);
          if (computedFrom.length === 0) {
            ref.llm_sense = { sense_indices: [], computed_from: [] };
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
    if (!jmWord || jmWord.sense.length <= 1) continue;

    const displayForm = jmWord?.kanji?.[0]?.text ?? jmWord?.kana?.[0]?.text ?? word.id;

    for (const [title, refs] of Object.entries(word.references ?? {})) {
      const uncachedRefs = refs.filter((ref) => !ref.llm_sense);
      if (uncachedRefs.length === 0) continue;

      if (refsAnalyzed >= maxSenses) {
        for (const ref of uncachedRefs) {
          console.log(`  Would analyze ${displayForm} [${title}:${ref.line}] (skipped, --max-senses limit reached)`);
        }
        continue;
      }
      if (noLlm) {
        for (const ref of uncachedRefs) {
          console.log(`  Would analyze ${displayForm} [${title}:${ref.line}] (skipped by --no-llm)`);
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
        const { senseIndices, reasoning } = await analyzeReferenceSense(anthropic, jmWord, ref);
        process.stdout.write(`→ [${senseIndices.join(", ")}]\n`);
        results = [{ senseIndices, reasoning }];
      } else {
        const lines = uncachedRefs.map((r) => r.line).join(", ");
        process.stdout.write(
          `  Analyzing ${displayForm} [${title}:lines ${lines}] (${uncachedRefs.length} occurrences, batch; ${refsAnalyzed + 1}–${refsAnalyzed + uncachedRefs.length}/${maxSenses === Infinity ? "all" : maxSenses})… `,
        );
        results = await analyzeReferencesSenseBatch(anthropic, jmWord, uncachedRefs);
        process.stdout.write(
          `→ [${results.map((r) => `[${r.senseIndices.join(", ")}]`).join(", ")}]\n`,
        );
      }

      for (let i = 0; i < uncachedRefs.length; i++) {
        const ref = uncachedRefs[i];
        const { senseIndices, reasoning } = results[i];
        const computedFrom = refComputedFrom(ref);
        reasoningLines.push(
          `${"=".repeat(60)}\n${displayForm}  [${title}:${ref.line}]  →  [${senseIndices.join(", ")}]\n${"=".repeat(60)}\n${reasoning}\n`,
        );
        ref.llm_sense = { sense_indices: senseIndices, computed_from: computedFrom, reasoning };
      }
      writeFileSync(reasoningLogPath, reasoningLines.join("\n"));
      refsAnalyzed += uncachedRefs.length;

      writeFileSync(outPath, JSON.stringify({
        generatedAt: new Date().toISOString(),
        stories: stories.map(({ title }) => ({ title })),
        words,
      }, null, 2) + "\n");
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

const output = {
  generatedAt: new Date().toISOString(),
  stories: stories.map(({ title }) => ({ title })),
  words,
};

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
    if (group.classicalJapanese) topic.classicalJapanese = group.classicalJapanese;
  }
}

writeFileSync(grammarOutPath, JSON.stringify(grammarOutput, null, 2) + "\n");
console.log(
  `Wrote ${Object.keys(grammarTopics).length} grammar topics → ${grammarOutPath}`,
);

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

const corpusEntries = stories.map(({ title, content: rawMarkdown }) => ({
  title,
  markdown: rawMarkdown,
  vocabCount: vocabCountByTitle.get(title) ?? 0,
  grammarCount: grammarCountByTitle.get(title) ?? 0,
}));

const corpusOutPath = path.join(projectRoot, "corpus.json");
writeFileSync(corpusOutPath, JSON.stringify(corpusEntries, null, 2) + "\n");
console.log(`Wrote ${corpusEntries.length} corpus entries → ${corpusOutPath}`);

// --- Compound verb detection ---
console.log("\n=== Compound verb detection ===");
await checkAndUpdateCompoundVerbs({ dryRun: noLlm, maxLlm: maxCompoundVerbs });
