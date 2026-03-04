/**
 * rescale-halflife.mjs
 * Adjusts the Ebisu halflife for one facet without recording a review.
 * Use when a word is clearly too easy or too hard and the halflife needs
 * a manual correction (e.g. after the user says "I know this really well").
 *
 * Required args:
 *   --word-id    TEXT    JMDict entry ID
 *   --quiz-type  TEXT    Facet to rescale (e.g. reading-to-meaning)
 *   --halflife   FLOAT   Target halflife in hours
 *
 * Optional args:
 *   --word-type  TEXT    'jmdict' (default)
 *
 * Usage:
 *   node .claude/scripts/rescale-halflife.mjs \
 *     --word-id 1445690 --quiz-type reading-to-meaning --halflife 120
 */

import { rescaleHalflife } from "ebisu-js";
import { openQuizDb } from "./shared.mjs";

const args = process.argv.slice(2);
let wordType = "jmdict";
let wordId, quizType, targetHalflife;

for (let i = 0; i < args.length; i++) {
  if (args[i] === "--word-type" && args[i + 1]) wordType = args[++i];
  if (args[i] === "--word-id" && args[i + 1]) wordId = args[++i];
  if (args[i] === "--quiz-type" && args[i + 1]) quizType = args[++i];
  if (args[i] === "--halflife" && args[i + 1])
    targetHalflife = parseFloat(args[++i]);
}

const missing = [];
if (!wordId) missing.push("--word-id");
if (!quizType) missing.push("--quiz-type");
if (targetHalflife === undefined) missing.push("--halflife");
if (missing.length > 0) {
  console.error(`Missing required arguments: ${missing.join(", ")}`);
  process.exit(1);
}
if (isNaN(targetHalflife) || targetHalflife <= 0) {
  console.error(`--halflife must be a positive number (got: ${targetHalflife})`);
  process.exit(1);
}

const db = openQuizDb();

const existing = db
  .prepare(
    "SELECT alpha, beta, t, last_review FROM ebisu_models WHERE word_type=? AND word_id=? AND quiz_type=?",
  )
  .get(wordType, wordId, quizType);

if (!existing) {
  console.error(
    `No Ebisu model found for word_id=${wordId} quiz_type=${quizType} word_type=${wordType}`,
  );
  db.close();
  process.exit(1);
}

const oldModel = [existing.alpha, existing.beta, existing.t];
const scale = targetHalflife / existing.t;
const [a, b, t] = rescaleHalflife(oldModel, scale);

db.prepare(
  "INSERT OR REPLACE INTO ebisu_models (word_type, word_id, quiz_type, alpha, beta, t, last_review) VALUES (?,?,?,?,?,?,?)",
).run(wordType, wordId, quizType, a, b, t, existing.last_review);

db.prepare(
  "INSERT INTO model_events (timestamp, word_type, word_id, quiz_type, event) VALUES (?,?,?,?,?)",
).run(new Date().toISOString(), wordType, wordId, quizType, `rescaled,${existing.t},${t}`);

db.close();

console.log(
  JSON.stringify({
    ok: true,
    wordType,
    wordId,
    quizType,
    oldHalflife: existing.t,
    newHalflife: t,
    scale,
  }),
);
