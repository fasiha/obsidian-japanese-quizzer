/**
 * init-quiz-db.mjs
 * Creates quiz.sqlite in the project root with the reviews table.
 * Safe to run multiple times — uses CREATE TABLE IF NOT EXISTS.
 *
 * Usage: node .claude/scripts/init-quiz-db.mjs
 */

import { openQuizDb, QUIZ_DB, SCHEMA_VERSION } from "./shared.mjs";

const db = openQuizDb();

db.exec(`
  CREATE TABLE IF NOT EXISTS reviews (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    reviewer    TEXT    NOT NULL,
    timestamp   TEXT    NOT NULL,  -- ISO 8601 UTC
    word_type   TEXT    NOT NULL,  -- 'jmdict' for now, 'grammar' later
    word_id     TEXT    NOT NULL,  -- JMDict entry ID (or grammar point ID later)
    word_text   TEXT    NOT NULL,  -- display text from the vocab bullet
    score       REAL    NOT NULL,  -- 0.0 (wrong) to 1.0 (perfect)
    quiz_type   TEXT    NOT NULL,  -- 'reading', 'meaning', 'kanji', etc.
    notes       TEXT               -- Claude's notes about this review attempt
  )
`);

db.pragma(`user_version = ${SCHEMA_VERSION}`);

db.close();
console.log(
  `Quiz database ready at ${QUIZ_DB} (schema version ${SCHEMA_VERSION})`,
);
