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

db.exec(`
  CREATE TABLE IF NOT EXISTS ebisu_models (
    word_type   TEXT    NOT NULL,  -- 'jmdict', 'grammar', etc.
    word_id     TEXT    NOT NULL,
    quiz_type   TEXT    NOT NULL,
    alpha       REAL    NOT NULL,
    beta        REAL    NOT NULL,
    t           REAL    NOT NULL,  -- halflife in hours
    last_review TEXT    NOT NULL,  -- ISO 8601 UTC
    PRIMARY KEY (word_type, word_id, quiz_type)
  )
`);

db.exec(`
  CREATE TABLE IF NOT EXISTS model_events (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT    NOT NULL,  -- ISO 8601 UTC
    word_type TEXT    NOT NULL,
    word_id   TEXT    NOT NULL,
    quiz_type TEXT    NOT NULL,
    event     TEXT    NOT NULL   -- CSV: 'learned,24' | 'rescaled,79.2,120' | 'buried'
  )
`);

db.pragma(`user_version = ${SCHEMA_VERSION}`);

db.close();
console.log(
  `Quiz database ready at ${QUIZ_DB} (schema version ${SCHEMA_VERSION})`,
);
