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

import { setup, findExact } from 'jmdict-simplified-node';
import { readFileSync } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { findMdFiles, extractJapaneseTokens, intersectSets, parseFrontmatter } from './shared.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(__dirname, '../..');
const JMDICT_DB = path.join(projectRoot, 'jmdict.sqlite');

// Extract bullets (with 1-indexed line numbers) from all Vocab details blocks.
//
// Line number derivation: the inner content of a <details> block starts right
// after the opening tag. We count newlines before that point in the file to get
// the 1-indexed line number of the first character of the inner block, then
// add the 0-indexed line offset within the block for each bullet.
function extractVocabBullets(content) {
  const SUMMARY_REGEXP = /<summary>\s*Vocab\s*<\/summary>/i;
  const DETAILS_REGEXP = /<details\b[^>]*>([\s\S]*?)<\/details>/gi;
  const bullets = [];
  let match;
  while ((match = DETAILS_REGEXP.exec(content)) !== null) {
    const inner = match[1];
    if (!SUMMARY_REGEXP.test(inner)) continue;

    // inner starts at: match.index + (opening tag length)
    // opening tag length = match[0].length - inner.length - '</details>'.length
    const openingTagLen = match[0].length - inner.length - '</details>'.length;
    const innerStartIdx = match.index + openingTagLen;
    // Line number (1-indexed) of the first character of inner
    const innerStartLine = content.slice(0, innerStartIdx).split('\n').length;

    const innerLines = inner.split('\n');
    for (let i = 0; i < innerLines.length; i++) {
      const trimmed = innerLines[i].trim();
      if (!trimmed.startsWith('-')) continue;
      const bullet = trimmed.slice(1).trim();
      if (bullet) bullets.push({ bullet, line: innerStartLine + i });
    }
  }
  return bullets;
}

const { db } = await setup(JMDICT_DB);
const mdFiles = findMdFiles(projectRoot);
const problems = [];
let totalChecked = 0;

for (const filePath of mdFiles) {
  const content = readFileSync(filePath, 'utf8');
  if (!parseFrontmatter(content)?.['llm-review']) continue;
  const bullets = extractVocabBullets(content);
  const relPath = path.relative(projectRoot, filePath);

  for (const { bullet, line } of bullets) {
    const tokens = extractJapaneseTokens(bullet);
    if (tokens.length === 0) continue;
    totalChecked++;

    const tokenResults = {};
    const idSets = tokens.map(token => {
      const words = findExact(db, token);
      tokenResults[token] = words.map(w => w.id);
      return new Set(tokenResults[token]);
    });

    const matchIds = [...intersectSets(idSets)];

    if (matchIds.length !== 1) {
      problems.push({ file: relPath, line, bullet, tokens, tokenResults, matchCount: matchIds.length, matchIds });
    }
  }
}

console.log(JSON.stringify({ totalChecked, problemCount: problems.length, problems }, null, 2));
