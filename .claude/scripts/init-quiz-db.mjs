/**
 * init-quiz-db.mjs
 * Creates quiz.sqlite in the project root with the reviews table.
 * Safe to run multiple times — uses CREATE TABLE IF NOT EXISTS.
 *
 * Usage: node .claude/scripts/init-quiz-db.mjs
 */

import Database from 'better-sqlite3';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(__dirname, '../..');
const QUIZ_DB = path.join(projectRoot, 'quiz.sqlite');

const db = new Database(QUIZ_DB);

db.exec(`
  CREATE TABLE IF NOT EXISTS reviews (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    reviewer    TEXT    NOT NULL,
    timestamp   TEXT    NOT NULL,  -- ISO 8601 UTC
    word_type   TEXT    NOT NULL,  -- 'jmdict' for now, 'grammar' later
    word_id     TEXT    NOT NULL,  -- JMDict entry ID (or grammar point ID later)
    word_text   TEXT    NOT NULL,  -- display text from the vocab bullet
    score       REAL    NOT NULL,  -- 0.0 (wrong) to 1.0 (perfect)
    notes       TEXT               -- Claude's notes about this review attempt
  )
`);

db.close();
console.log(`Quiz database ready at ${QUIZ_DB}`);
