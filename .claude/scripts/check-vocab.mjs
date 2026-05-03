/**
 * check-vocab.mjs
 * Reads all Markdown files, extracts bullets from <details><summary>Vocab</summary> blocks,
 * and checks each against JMDict via findExact. Outputs a JSON report to stdout.
 *
 * A bullet is valid if all its leading Japanese tokens (before any English text)
 * intersect to exactly one JMDict entry. Bullets with 0 or 2+ matches are flagged.
 *
 * Only files with `llm-review: true` in their YAML frontmatter are scanned.
 *
 * Usage: node .claude/scripts/check-vocab.mjs
 */

import { findExactIds } from "jmdict-simplified-node";
import { readFileSync } from "fs";
import path from "path";
import {
  findMdFiles,
  extractJapaneseTokens,
  intersectSets,
  parseFrontmatter,
  projectRoot,
  openJmdictDb,
  extractVocabBulletsWithLines,
} from "./shared.mjs";

const db = await openJmdictDb({ checkJournalMode: true });
const mdFiles = findMdFiles(projectRoot);
const problems = [];
let totalChecked = 0;

for (const filePath of mdFiles) {
  const content = readFileSync(filePath, "utf8");
  if (!parseFrontmatter(content)?.["llm-review"]) continue;
  const bullets = extractVocabBulletsWithLines(content);
  const relPath = path.relative(projectRoot, filePath);

  for (const { bullet, line } of bullets) {
    // If the bullet starts with a bare JMDict ID (all digits), trust it directly.
    const directIdMatch = bullet.match(/^(\d+)/);
    if (directIdMatch) {
      totalChecked++;
      continue;
    }

    const tokens = extractJapaneseTokens(bullet);
    if (tokens.length === 0) continue;
    totalChecked++;

    const tokenResults = {};
    const idSets = tokens.map((token) => {
      const ids = findExactIds(db, token);
      tokenResults[token] = ids;
      return new Set(ids);
    });

    const matchIds = [...intersectSets(idSets)];

    if (matchIds.length !== 1) {
      problems.push({
        file: relPath,
        line,
        direct: `${relPath}:${line}`,
        bullet,
        tokens,
        tokenResults,
        matchCount: matchIds.length,
        matchIds,
      });
    }
  }
}

console.log(
  JSON.stringify(
    { totalChecked, problemCount: problems.length, problems },
    null,
    2,
  ),
);
