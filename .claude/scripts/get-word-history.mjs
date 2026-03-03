/**
 * get-word-history.mjs
 * Outputs full review history and current Ebisu models for one word.
 * Call this during a quiz when you need more detail than the compact
 * context line provides.
 *
 * Required args:
 *   --word-id    TEXT   JMDict entry ID
 *
 * Optional args:
 *   --word-type  TEXT   'jmdict' (default)
 *
 * Usage:
 *   node .claude/scripts/get-word-history.mjs --word-id 1584060
 */

import { predictRecall } from "ebisu-js";
import { openQuizDb } from "./shared.mjs";

const args = process.argv.slice(2);
let wordId, wordType = "jmdict";

for (let i = 0; i < args.length; i++) {
  if (args[i] === "--word-id" && args[i + 1]) wordId = args[++i];
  if (args[i] === "--word-type" && args[i + 1]) wordType = args[++i];
}

if (!wordId) {
  console.error("Missing required argument: --word-id");
  process.exit(1);
}

const db = openQuizDb({ readonly: true });

const reviews = db
  .prepare(
    "SELECT timestamp, quiz_type, score, notes FROM reviews WHERE word_id=? AND word_type=? ORDER BY timestamp ASC",
  )
  .all(wordId, wordType);

const models = db
  .prepare(
    "SELECT quiz_type, alpha, beta, t, last_review FROM ebisu_models WHERE word_id=? AND word_type=?",
  )
  .all(wordId, wordType);

db.close();

// Compute current recall probability for each model
const now = Date.now();
const modelsWithRecall = models.map((m) => {
  const elapsed = (now - new Date(m.last_review).getTime()) / 3_600_000;
  const recall = predictRecall([m.alpha, m.beta, m.t], Math.max(elapsed, 1e-6), true);
  return { ...m, recallNow: recall.toFixed(3), halfliveHours: m.t.toFixed(1) };
});

console.log(JSON.stringify({ wordId, wordType, reviews, models: modelsWithRecall }, null, 2));
