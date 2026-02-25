/**
 * get-vocab.mjs
 * Reads all Markdown files, extracts every vocab bullet, and enriches each with
 * JMDict data. Outputs a JSON array to stdout for Claude to read during quizzes.
 *
 * Each item has:
 *   - file, bullet, tokens                  (always present)
 *   - jmdictId, kanji, kana, meanings       (only when matchCount === 1)
 *   - matchCount                             (always; 1 = quizzable)
 *
 * Usage: node .claude/scripts/get-vocab.mjs
 */

import { setup, findExact, idsToWords } from 'jmdict-simplified-node';
import { readFileSync, readdirSync } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(__dirname, '../..');
const JMDICT_DB = path.join(projectRoot, 'jmdict.sqlite');

function findMdFiles(dir, excludeDirs = ['node_modules', '.claude']) {
  const results = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (excludeDirs.includes(entry.name)) continue;
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      results.push(...findMdFiles(fullPath, excludeDirs));
    } else if (entry.name.endsWith('.md')) {
      results.push(fullPath);
    }
  }
  return results;
}

function extractVocabBullets(content) {
  const SUMMARY_REGEXP = /<summary>\s*Vocab\s*<\/summary>/i;
  const DETAILS_REGEXP = /<details\b[^>]*>([\s\S]*?)<\/details>/gi;
  const bullets = [];
  let match;
  while ((match = DETAILS_REGEXP.exec(content)) !== null) {
    const inner = match[1];
    if (!SUMMARY_REGEXP.test(inner)) continue;
    for (const line of inner.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed.startsWith('-')) continue;
      const bullet = trimmed.slice(1).trim();
      if (bullet) bullets.push(bullet);
    }
  }
  return bullets;
}

function isJapanese(str) {
  return /[\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FFF\u3400-\u4DBF\uF900-\uFAFF\u3005\u30FC]/.test(str);
}

function extractJapaneseTokens(bulletText) {
  const result = [];
  for (const token of bulletText.split(/\s+/)) {
    if (token && isJapanese(token)) result.push(token);
    else break;
  }
  return result;
}

function intersectSets(sets) {
  let result = new Set(sets[0]);
  for (let i = 1; i < sets.length; i++) {
    for (const id of result) {
      if (!sets[i].has(id)) result.delete(id);
    }
  }
  return result;
}

// Pull English glosses from a Word's senses (all senses, English only)
function getMeanings(word) {
  const meanings = [];
  for (const sense of word.sense) {
    for (const gloss of sense.gloss) {
      if (gloss.lang === 'eng') meanings.push(gloss.text);
    }
  }
  return meanings;
}

const { db } = await setup(JMDICT_DB);
const mdFiles = findMdFiles(projectRoot);
const output = [];

for (const filePath of mdFiles) {
  const content = readFileSync(filePath, 'utf8');
  const bullets = extractVocabBullets(content);
  const relPath = path.relative(projectRoot, filePath);

  for (const bullet of bullets) {
    const tokens = extractJapaneseTokens(bullet);
    if (tokens.length === 0) continue;

    const idSets = tokens.map(token => {
      const words = findExact(db, token);
      return new Set(words.map(w => w.id));
    });

    const matchIds = [...intersectSets(idSets)];

    if (matchIds.length === 1) {
      const [word] = idsToWords(db, matchIds);
      output.push({
        file: relPath,
        bullet,
        tokens,
        matchCount: 1,
        jmdictId: word.id,
        kanji: word.kanji.map(k => k.text),
        kana: word.kana.map(k => k.text),
        meanings: getMeanings(word),
      });
    } else {
      output.push({
        file: relPath,
        bullet,
        tokens,
        matchCount: matchIds.length,
      });
    }
  }
}

console.log(JSON.stringify(output, null, 2));
