/**
 * get-quiz-history.mjs
 * Queries quiz.sqlite for recent review history and outputs a JSON summary.
 *
 * Options:
 *   --days N        Look back N days (default: 30)
 *   --reviewer NAME Filter by reviewer (default: all reviewers)
 *
 * Output JSON:
 *   {
 *     "reviews": [...],      // raw rows from the last N days
 *     "summary": {           // per-word stats (all time, not just the window)
 *       "<jmdictId>": {
 *         "wordText": "...",
 *         "totalReviews": N,
 *         "lastReviewed": "ISO timestamp",
 *         "daysSinceLastReview": N,
 *         "averageScore": 0.0-1.0,
 *         "recentScores": [...]  // scores from within the --days window, oldest first
 *       }
 *     }
 *   }
 *
 * Usage: node .claude/scripts/get-quiz-history.mjs [--days 30] [--reviewer fasiha]
 */

import Database from 'better-sqlite3';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(__dirname, '../..');
const QUIZ_DB = path.join(projectRoot, 'quiz.sqlite');

// Parse CLI args
const args = process.argv.slice(2);
let days = 30;
let reviewer = null;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--days' && args[i + 1]) days = parseInt(args[++i], 10);
  if (args[i] === '--reviewer' && args[i + 1]) reviewer = args[++i];
}

const db = new Database(QUIZ_DB, { readonly: true });

// Reviews within the time window
const cutoff = new Date(Date.now() - days * 24 * 60 * 60 * 1000).toISOString();
const recentRows = reviewer
  ? db.prepare('SELECT * FROM reviews WHERE timestamp >= ? AND reviewer = ? ORDER BY timestamp ASC').all(cutoff, reviewer)
  : db.prepare('SELECT * FROM reviews WHERE timestamp >= ? ORDER BY timestamp ASC').all(cutoff);

// Per-word stats across all time (not just the window)
const allRows = reviewer
  ? db.prepare('SELECT * FROM reviews WHERE reviewer = ? ORDER BY timestamp ASC').all(reviewer)
  : db.prepare('SELECT * FROM reviews ORDER BY timestamp ASC').all();

db.close();

const summary = {};
const now = Date.now();

for (const row of allRows) {
  if (!summary[row.word_id]) {
    summary[row.word_id] = {
      wordText: row.word_text,
      totalReviews: 0,
      lastReviewed: null,
      daysSinceLastReview: null,
      averageScore: 0,
      recentScores: [],
      _scoreSum: 0,
    };
  }
  const s = summary[row.word_id];
  s.totalReviews++;
  s._scoreSum += row.score;
  s.averageScore = parseFloat((s._scoreSum / s.totalReviews).toFixed(3));
  s.lastReviewed = row.timestamp;
  s.daysSinceLastReview = Math.floor((now - new Date(row.timestamp).getTime()) / (24 * 60 * 60 * 1000));
}

// Add recentScores from within the window
for (const row of recentRows) {
  if (summary[row.word_id]) {
    summary[row.word_id].recentScores.push({ timestamp: row.timestamp, score: row.score, notes: row.notes });
  }
}

// Clean up internal accumulator
for (const s of Object.values(summary)) delete s._scoreSum;

console.log(JSON.stringify({ reviews: recentRows, summary }, null, 2));
