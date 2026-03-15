/**
 * enrich-grammar-descriptions.mjs
 *
 * Data helper for grammar description enrichment. Does NOT call any LLM API.
 * The skill (/cluster-grammar-topics) calls this script to gather context,
 * then does its own web fetching and description generation, then calls this
 * script again to write the results back.
 *
 * Modes:
 *
 *   node enrich-grammar-descriptions.mjs --gather [topic-id ...]
 *     Prints JSON context for each equivalence group that contains any of the
 *     given topic IDs. If no topic IDs are given, reports ALL groups.
 *     Output: { groups: [GatherResult, ...] }
 *
 *   node enrich-grammar-descriptions.mjs --needs-enrichment [topic-id ...]
 *     Same as --gather but filters output to groups where needsEnrichment is true.
 *     Output: { groups: [GatherResult, ...] }
 *
 *   node enrich-grammar-descriptions.mjs --write
 *     Reads JSON from stdin: { groups: [WriteInput, ...] }
 *     Writes descriptions into grammar-equivalences.json.
 *
 * @typedef {Object} GatherResult
 * @property {string[]} topics           - Sorted prefixed topic IDs in this group
 * @property {TopicMeta[]} topicsMeta    - Metadata for each topic from the grammar DBs
 * @property {ContentItem[]} contentItems - Sentences from user Markdown files
 * @property {ExistingDescription|null} existingDescription - Current stored description (if any)
 * @property {boolean} needsEnrichment   - True if description is missing or contentItems changed
 *
 * @typedef {Object} TopicMeta
 * @property {string} topicId
 * @property {string} source   - "genki" | "bunpro" | "dbjg"
 * @property {string} titleEn
 * @property {string} [titleJp]
 * @property {string} level
 * @property {string} [href]   - Fetchable URL (Bunpro or St Olaf/Genki)
 *
 * @typedef {Object} ContentItem
 * @property {string} sentence    - Clean Japanese text (ruby tags stripped), for LLM consumption
 * @property {string} rawSentence - Original Markdown with ruby tags intact, stored in sourcesSeen
 *                                  for change-detection and future source-linking
 * @property {string} note        - Free-text annotation note from the bullet (may be empty)
 * @property {string} file        - Relative path of the Markdown file
 * @property {string} topicId     - Which topic ID this annotation referenced
 *
 * @typedef {Object} ExistingDescription
 * @property {string} [summary]
 * @property {string[]} [subUses]
 * @property {string[]} [cautions]
 * @property {string[]} [sourcesSeen]
 * @property {boolean} [stub]
 *
 * @typedef {Object} WriteInput
 * @property {string[]} topics     - Must match a group in grammar-equivalences.json exactly
 * @property {string} summary
 * @property {string[]} subUses
 * @property {string[]} cautions
 * @property {string[]} sourcesSeen
 * @property {boolean} [stub]      - Omit or false if content sentences were used
 */

import { readFileSync, writeFileSync } from "fs";
import path from "path";
import {
  findMdFiles,
  parseFrontmatter,
  projectRoot,
  loadGrammarDatabases,
  extractGrammarBullets,
  isJapanese,
  migrateEquivalences,
} from "./shared.mjs";

const EQUIV_PATH = path.join(projectRoot, "grammar-equivalences.json");

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

/** Strip <ruby>kanji<rt>reading</rt></ruby> tags, keeping the kanji text. */
function stripRuby(text) {
  return text
    .replace(/<ruby>([^<]*)<rt>[^<]*<\/rt><\/ruby>/gi, "$1")
    .replace(/<[^>]+>/g, "") // strip any remaining tags
    .trim();
}

/**
 * Extract content sentences from a Markdown file for a given set of topic IDs.
 *
 * Strategy: for each Grammar details block whose bullets reference one of our
 * topics, walk backward through the file lines to find the nearest non-empty,
 * non-details, Japanese-containing line. That line is the annotated sentence.
 *
 * Returns [{ sentence, note, file, topicId }].
 */
function extractContentItems(content, relPath, topicIds) {
  const topicSet = new Set(topicIds);
  const items = [];

  // Split into lines for backward search
  const lines = content.split("\n");

  // Find all Grammar details blocks and their positions
  const DETAILS_RE = /<details\b[^>]*>([\s\S]*?)<\/details>/gi;
  const SUMMARY_RE = /<summary>\s*Grammar\s*<\/summary>/i;

  let match;
  while ((match = DETAILS_RE.exec(content)) !== null) {
    const inner = match[1];
    if (!SUMMARY_RE.test(inner)) continue;

    // Check if any bullet in this block references one of our topics
    const bullets = extractGrammarBullets(match[0]); // parse just this block
    const relevantBullets = bullets.filter((b) => topicSet.has(b.topicId));
    if (relevantBullets.length === 0) continue;

    // Find which line this details block starts on (0-indexed)
    const charsBefore = content.slice(0, match.index);
    const blockStartLine = charsBefore.split("\n").length - 1;

    // Walk backward from the line before the block to find the annotated sentence
    let sentence = "";
    let rawSentence = "";
    for (let i = blockStartLine - 1; i >= 0; i--) {
      const rawLine = lines[i];
      const clean = stripRuby(rawLine).trim();

      // Skip empty lines
      if (!clean) continue;

      // Skip lines that are part of another details block (closing/opening tags,
      // summary lines, bullet lines inside other details, translation lines)
      if (
        clean.startsWith("<details") ||
        clean.startsWith("</details") ||
        clean.startsWith("<summary") ||
        clean.startsWith("</summary") ||
        clean.startsWith("-") // bullet inside another block
      ) {
        continue;
      }

      // If this line contains Japanese, it's our sentence
      if (isJapanese(clean)) {
        sentence = clean;           // ruby-stripped, for LLM consumption
        rawSentence = rawLine.trim(); // original Markdown, for sourcesSeen
        break;
      }

      // If this line is purely ASCII/English (e.g. a translation line that
      // escaped its details block), skip and keep looking
    }

    // Record one item per relevant bullet, all sharing the same sentence
    for (const { topicId, note } of relevantBullets) {
      items.push({ sentence, rawSentence, note, file: relPath, topicId });
    }
  }

  return items;
}

// ---------------------------------------------------------------------------
// Load equivalences
// ---------------------------------------------------------------------------

function loadEquivalences() {
  let raw;
  try {
    raw = JSON.parse(readFileSync(EQUIV_PATH, "utf-8"));
  } catch {
    raw = [];
  }
  return migrateEquivalences(raw);
}

// ---------------------------------------------------------------------------
// --gather mode
// ---------------------------------------------------------------------------

function gather(requestedTopics, { onlyNeeded = false } = {}) {
  const grammarDb = loadGrammarDatabases();
  const groups = loadEquivalences();
  const mdFiles = findMdFiles(projectRoot);

  // Build a map from topic ID -> group index for fast lookup
  const topicToGroupIdx = new Map();
  for (let i = 0; i < groups.length; i++) {
    for (const id of groups[i].topics) {
      topicToGroupIdx.set(id, i);
    }
  }

  // Determine which group indices to process
  let targetIndices;
  if (requestedTopics.length === 0) {
    targetIndices = new Set(groups.map((_, i) => i));
  } else {
    targetIndices = new Set();
    for (const id of requestedTopics) {
      const idx = topicToGroupIdx.get(id);
      if (idx !== undefined) targetIndices.add(idx);
      else process.stderr.write(`[warn] topic "${id}" not found in any equivalence group\n`);
    }
  }

  // Collect all content items across all MD files upfront (single pass)
  const allItems = []; // { sentence, note, file, topicId }
  for (const filePath of mdFiles) {
    const content = readFileSync(filePath, "utf-8");
    if (!parseFrontmatter(content)?.["llm-review"]) continue;
    const relPath = path.relative(projectRoot, filePath);
    // Gather all topic IDs present in this file's grammar bullets
    const bullets = extractGrammarBullets(content);
    const fileTopicIds = bullets.map((b) => b.topicId);
    if (fileTopicIds.length === 0) continue;
    const items = extractContentItems(content, relPath, fileTopicIds);
    allItems.push(...items);
  }

  // Group content items by group index
  const itemsByGroup = new Map();
  for (const item of allItems) {
    const idx = topicToGroupIdx.get(item.topicId);
    if (idx === undefined) continue;
    if (!itemsByGroup.has(idx)) itemsByGroup.set(idx, []);
    itemsByGroup.get(idx).push(item);
  }

  // Build GatherResult for each target group
  const results = [];
  for (const idx of targetIndices) {
    const group = groups[idx];
    const contentItems = itemsByGroup.get(idx) ?? [];

    // Topic metadata
    const topicsMeta = group.topics.map((id) => {
      const entry = grammarDb.get(id);
      if (!entry) return { topicId: id, source: "unknown", titleEn: id, level: "unknown" };
      return {
        topicId: id,
        source: entry.source,
        titleEn: entry.titleEn,
        ...(entry.titleJp ? { titleJp: entry.titleJp } : {}),
        level: entry.level,
        ...(entry.href ? { href: entry.href } : {}),
      };
    });

    // Check whether description needs (re)generation
    const existingDescription = group.summary
      ? {
          summary: group.summary,
          ...(group.subUses ? { subUses: group.subUses } : {}),
          ...(group.cautions ? { cautions: group.cautions } : {}),
          ...(group.sourcesSeen ? { sourcesSeen: group.sourcesSeen } : {}),
          ...(group.stub ? { stub: group.stub } : {}),
        }
      : null;

    const currentSourcesSeen = contentItems
      .filter((it) => it.sentence)
      .map((it) => `${it.file}: ${it.rawSentence}`)
      .sort();

    const storedSourcesSeen = (group.sourcesSeen ?? []).slice().sort();
    const sourcesChanged =
      JSON.stringify(currentSourcesSeen) !== JSON.stringify(storedSourcesSeen);

    const needsEnrichment = !existingDescription || sourcesChanged;

    results.push({
      topics: group.topics,
      topicsMeta,
      contentItems,
      existingDescription,
      needsEnrichment,
    });
  }

  const output = onlyNeeded ? results.filter((r) => r.needsEnrichment) : results;
  process.stdout.write(JSON.stringify({ groups: output }, null, 2) + "\n");
}

// ---------------------------------------------------------------------------
// --write mode
// ---------------------------------------------------------------------------

function write() {
  let input;
  try {
    const raw = readFileSync("/dev/stdin", "utf-8");
    input = JSON.parse(raw);
  } catch (e) {
    process.stderr.write(`Failed to read/parse JSON from stdin: ${e.message}\n`);
    process.exit(1);
  }

  const groups = loadEquivalences();

  // Build a map from sorted-topics key -> group index
  const keyToIdx = new Map();
  for (let i = 0; i < groups.length; i++) {
    keyToIdx.set(groups[i].topics.join("|"), i);
  }

  let written = 0;
  for (const desc of input.groups) {
    const key = [...desc.topics].sort().join("|");
    const idx = keyToIdx.get(key);
    if (idx === undefined) {
      process.stderr.write(`[warn] no equivalence group found for topics: ${desc.topics.join(", ")}\n`);
      continue;
    }
    // Merge description fields into the group, preserving topics and any other fields
    groups[idx] = {
      topics: groups[idx].topics,
      summary: desc.summary,
      subUses: desc.subUses,
      cautions: desc.cautions,
      sourcesSeen: desc.sourcesSeen,
      ...(desc.stub ? { stub: true } : {}),
    };
    written++;
  }

  writeFileSync(EQUIV_PATH, JSON.stringify(groups, null, 2) + "\n");
  process.stderr.write(`Wrote descriptions for ${written} group(s) → ${EQUIV_PATH}\n`);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

const args = process.argv.slice(2);
if (args[0] === "--write") {
  write();
} else if (args[0] === "--gather" || args.length === 0) {
  const topics = args[0] === "--gather" ? args.slice(1) : [];
  gather(topics);
} else if (args[0] === "--needs-enrichment") {
  gather(args.slice(1), { onlyNeeded: true });
} else {
  process.stderr.write(
    "Usage:\n" +
    "  node enrich-grammar-descriptions.mjs --gather [topic-id ...]\n" +
    "  node enrich-grammar-descriptions.mjs --needs-enrichment [topic-id ...]\n" +
    "  node enrich-grammar-descriptions.mjs --write   (reads JSON from stdin)\n",
  );
  process.exit(1);
}
