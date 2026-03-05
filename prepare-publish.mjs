/**
 * prepare-publish.mjs
 * Validates all llm-review Markdown files and compiles a single vocab.json.
 *
 * Requirements per file:
 *   - `llm-review: true` in YAML frontmatter
 *   - `title: ...` in YAML frontmatter (required — used as source label in vocab.json)
 *   - All vocab bullets must resolve to exactly one JMDict entry
 *
 * Output: vocab.json at project root
 * {
 *   "generatedAt": "<ISO timestamp>",
 *   "stories": [{ "title": "..." }],
 *   "words": [{ "id": "1234567", "sources": ["分章読解3"] }]
 * }
 *
 * Words appearing in multiple stories accumulate sources.
 * All other word data (forms, meanings) is derived from bundled jmdict.sqlite in the app.
 *
 * Usage: node prepare-publish.mjs
 */

import { setup, findExactIds } from "jmdict-simplified-node";
import { readFileSync, writeFileSync } from "fs";
import path from "path";
import {
  findMdFiles,
  extractJapaneseTokens,
  intersectSets,
  parseFrontmatter,
  projectRoot,
  JMDICT_DB,
} from "./.claude/scripts/shared.mjs";

// Like shared.extractVocabBullets but also returns 1-indexed line numbers.
function extractVocabBullets(content) {
  const SUMMARY_REGEXP = /<summary>\s*Vocab\s*<\/summary>/i;
  const DETAILS_REGEXP = /<details\b[^>]*>([\s\S]*?)<\/details>/gi;
  const bullets = [];
  let match;
  while ((match = DETAILS_REGEXP.exec(content)) !== null) {
    const inner = match[1];
    if (!SUMMARY_REGEXP.test(inner)) continue;
    const openingTagLen = match[0].length - inner.length - "</details>".length;
    const innerStartLine =
      content.slice(0, match.index + openingTagLen).split("\n").length;
    const innerLines = inner.split("\n");
    for (let i = 0; i < innerLines.length; i++) {
      const trimmed = innerLines[i].trim();
      if (!trimmed.startsWith("-")) continue;
      const bullet = trimmed.slice(1).trim();
      if (bullet) bullets.push({ bullet, line: innerStartLine + i });
    }
  }
  return bullets;
}

const { db } = await setup(JMDICT_DB);
const mdFiles = findMdFiles(projectRoot);

const errors = [];
const stories = [];
// Map from word id -> { id, sources: Set<title> }
const wordMap = new Map();

for (const filePath of mdFiles) {
  const content = readFileSync(filePath, "utf8");
  const fm = parseFrontmatter(content);
  if (!fm?.["llm-review"]) continue;

  const relPath = path.relative(projectRoot, filePath);

  if (!fm.title) {
    errors.push(`${relPath}: missing 'title' in frontmatter`);
    continue;
  }

  const title = fm.title;
  if (!stories.find((s) => s.title === title)) {
    stories.push({ title });
  }

  for (const { bullet, line } of extractVocabBullets(content)) {
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

    if (wordMap.has(wordId)) {
      wordMap.get(wordId).sources.add(title);
    } else {
      wordMap.set(wordId, { id: wordId, sources: new Set([title]) });
    }
  }
}

if (errors.length > 0) {
  console.error(`\nPublication blocked by ${errors.length} error(s):\n`);
  for (const err of errors) console.error(`  ✗ ${err}`);
  process.exit(1);
}

const words = [...wordMap.values()].map(({ id, sources }) => ({
  id,
  sources: [...sources],
}));

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
