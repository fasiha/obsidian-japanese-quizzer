/**
 * record-review.mjs
 * Inserts one review record into quiz.sqlite and updates the Ebisu model
 * for the quizzed facet. Optionally passively updates related facets.
 *
 * Required args:
 *   --word-id    TEXT    JMDict entry ID
 *   --word-text  TEXT    Display text (the vocab bullet)
 *   --score      FLOAT   0.0 (wrong) to 1.0 (perfect)
 *   --quiz-type  TEXT    One of:
 *                          reading-to-meaning       (all words)
 *                          meaning-to-reading       (all words)
 *                          kanji-to-reading         ({kanji-ok} words only)
 *                          meaning-reading-to-kanji ({kanji-ok} words only)
 *
 * Optional args:
 *   --reviewer       TEXT    Reviewer name (default: OS username)
 *   --word-type      TEXT    'jmdict' (default) or 'grammar'
 *   --notes          TEXT    Claude's notes about this review attempt
 *   --passive-facets TEXT    Comma-separated facets to passively update with
 *                            score=0.5 (moves model forward in time without
 *                            changing halflife estimate)
 *
 * Usage:
 *   node .claude/scripts/record-review.mjs \
 *     --word-id 1234567 --word-text 体中 --score 0.8 \
 *     --quiz-type meaning-to-reading \
 *     --passive-facets reading-to-meaning \
 *     --notes "Got reading right, hesitated on meaning"
 */

import os from "os";
import { readFileSync, writeFileSync, existsSync } from "fs";
import { defaultModel, updateRecall } from "ebisu-js";
import { openQuizDb, QUIZ_SESSION, EBISU_ALPHA } from "./shared.mjs";

// Parse CLI args
const args = process.argv.slice(2);
let reviewer = os.userInfo().username;
let wordType = "jmdict";
let wordId, wordText, score, quizType, notes;
let passiveFacets = [];

for (let i = 0; i < args.length; i++) {
  if (args[i] === "--reviewer" && args[i + 1]) reviewer = args[++i];
  if (args[i] === "--word-type" && args[i + 1]) wordType = args[++i];
  if (args[i] === "--word-id" && args[i + 1]) wordId = args[++i];
  if (args[i] === "--word-text" && args[i + 1]) wordText = args[++i];
  if (args[i] === "--score" && args[i + 1]) score = parseFloat(args[++i]);
  if (args[i] === "--quiz-type" && args[i + 1]) quizType = args[++i];
  if (args[i] === "--notes" && args[i + 1]) notes = args[++i];
  if (args[i] === "--passive-facets" && args[i + 1])
    passiveFacets = args[++i].split(",").map((s) => s.trim()).filter(Boolean);
}

// Validate
const missing = [];
if (!wordId) missing.push("--word-id");
if (!wordText) missing.push("--word-text");
if (score === undefined) missing.push("--score");
if (!quizType) missing.push("--quiz-type");

if (missing.length > 0) {
  console.error(`Missing required arguments: ${missing.join(", ")}`);
  process.exit(1);
}

if (isNaN(score) || score < 0 || score > 1) {
  console.error(
    `--score must be a number between 0.0 and 1.0 (got: ${args[args.indexOf("--score") + 1]})`,
  );
  process.exit(1);
}

const VALID_QUIZ_TYPES_BY_WORD_TYPE = {
  jmdict: new Set([
    "reading-to-meaning",
    "meaning-to-reading",
    "kanji-to-reading",
    "meaning-reading-to-kanji",
  ]),
};
const validTypes = VALID_QUIZ_TYPES_BY_WORD_TYPE[wordType];
if (validTypes && !validTypes.has(quizType)) {
  console.error(
    `--quiz-type must be one of: ${[...validTypes].join(", ")} (got: ${quizType})`,
  );
  process.exit(1);
}

const timestamp = new Date().toISOString();

const db = openQuizDb();
const result = db
  .prepare(
    "INSERT INTO reviews (reviewer, timestamp, word_type, word_id, word_text, score, quiz_type, notes) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
  )
  .run(reviewer, timestamp, wordType, wordId, wordText, score, quizType ?? null, notes ?? null);

// Update Ebisu model for the quizzed facet
function ebisuUpdate(wType, wId, qType, reviewScore, reviewTimestamp) {
  const existing = db
    .prepare(
      "SELECT alpha, beta, t, last_review FROM ebisu_models WHERE word_type=? AND word_id=? AND quiz_type=?",
    )
    .get(wType, wId, qType);

  const model = existing ? [existing.alpha, existing.beta, existing.t] : defaultModel(24, EBISU_ALPHA, EBISU_ALPHA);
  const elapsed = existing
    ? (new Date(reviewTimestamp) - new Date(existing.last_review)) / 3_600_000
    : 0;

  const [a, b, t] = updateRecall(model, reviewScore, 1, Math.max(elapsed, 1e-6));

  db.prepare(
    "INSERT OR REPLACE INTO ebisu_models (word_type, word_id, quiz_type, alpha, beta, t, last_review) VALUES (?,?,?,?,?,?,?)",
  ).run(wType, wId, qType, a, b, t, reviewTimestamp);
}

ebisuUpdate(wordType, wordId, quizType, score, timestamp);

// Passive updates for related facets (score=0.5 moves model forward in time
// without changing the halflife estimate)
for (const facet of passiveFacets) {
  ebisuUpdate(wordType, wordId, facet, 0.5, timestamp);
}

db.close();

// Remove this word from the session queue if a session is active
if (existsSync(QUIZ_SESSION)) {
  const lines = readFileSync(QUIZ_SESSION, "utf8").split("\n");
  const filtered = lines.filter((line) => !line.startsWith(wordId + "  "));
  writeFileSync(QUIZ_SESSION, filtered.join("\n"));
}

console.log(
  JSON.stringify({
    ok: true,
    id: result.lastInsertRowid,
    reviewer,
    timestamp,
    wordType,
    wordId,
    wordText,
    score,
    quizType: quizType ?? null,
    notes: notes ?? null,
  }),
);
