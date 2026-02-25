/**
 * get-quiz-context.mjs
 * Outputs one compact line per quizzable vocab item, merged with all-time quiz history.
 * Items where the vocab bullet doesn't resolve to exactly one JMDict entry are omitted.
 *
 * Output format — one line per word:
 *   <jmdictId>  <kanji/kana>, <meanings> (#<id>) [<review status>]
 *
 * Example:
 *   1398530  体中, からだじゅう all over the body; throughout the body (#1398530) [never reviewed]
 *   1584060  包む, つつむ to wrap; to pack; to conceal (#1584060) [5d ago, avg 0.80, 2 reviews]
 *
 * Options:
 *   --reviewer NAME   Filter quiz history to one reviewer (default: all reviewers)
 *
 * Usage: node .claude/scripts/get-quiz-context.mjs [--reviewer fasiha]
 */

import { setup, findExact, idsToWords } from 'jmdict-simplified-node';
import { readFileSync } from 'fs';
import path from 'path';
import {
  findMdFiles, extractJapaneseTokens, intersectSets, parseFrontmatter,
  extractVocabBullets, summarizeWord, openQuizDb, projectRoot, JMDICT_DB,
} from './shared.mjs';

const args = process.argv.slice(2);
let reviewer = null;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--reviewer' && args[i + 1]) reviewer = args[++i];
}

// Load all-time quiz history, keyed by word_id
const quizDb = openQuizDb({ readonly: true });
const historyRows = reviewer
  ? quizDb.prepare('SELECT word_id, score, timestamp FROM reviews WHERE reviewer = ? ORDER BY timestamp ASC').all(reviewer)
  : quizDb.prepare('SELECT word_id, score, timestamp FROM reviews ORDER BY timestamp ASC').all();
quizDb.close();

const stats = new Map(); // word_id -> { totalReviews, scoreSum, lastTimestamp }
for (const row of historyRows) {
  if (!stats.has(row.word_id)) stats.set(row.word_id, { totalReviews: 0, scoreSum: 0, lastTimestamp: null });
  const s = stats.get(row.word_id);
  s.totalReviews++;
  s.scoreSum += row.score;
  s.lastTimestamp = row.timestamp;
}

function reviewStatus(wordId) {
  const s = stats.get(String(wordId));
  if (!s) return 'never reviewed';
  const days = Math.floor((Date.now() - new Date(s.lastTimestamp).getTime()) / 86_400_000);
  const avg = (s.scoreSum / s.totalReviews).toFixed(2);
  return `${days}d ago, avg ${avg}, ${s.totalReviews} review${s.totalReviews !== 1 ? 's' : ''}`;
}

// Scan opted-in Markdown files for vocab bullets
const { db } = await setup(JMDICT_DB);
const lines = [];

for (const filePath of findMdFiles(projectRoot)) {
  const content = readFileSync(filePath, 'utf8');
  if (!parseFrontmatter(content)?.['llm-review']) continue;

  for (const bullet of extractVocabBullets(content)) {
    const tokens = extractJapaneseTokens(bullet);
    if (tokens.length === 0) continue;

    const idSets = tokens.map(token => new Set(findExact(db, token).map(w => w.id)));
    const matchIds = [...intersectSets(idSets)];
    if (matchIds.length !== 1) continue; // skip broken entries

    const [word] = idsToWords(db, matchIds);
    lines.push(`${word.id}  ${summarizeWord(word)} [${reviewStatus(word.id)}]`);
  }
}

console.log(lines.join('\n'));
