/**
 * write-quiz-session.mjs
 * Writes a quiz session plan to .claude/quiz-session.txt.
 * Takes JMDict word IDs as positional arguments, looks each up in JMDict and
 * quiz history, and writes one summary line per word.
 *
 * Usage: node .claude/scripts/write-quiz-session.mjs <id1> <id2> ...
 *
 * The session file is read by read-quiz-session.mjs and deleted by
 * clear-quiz-session.mjs when the quiz is finished.
 */

import { setup, idsToWords } from "jmdict-simplified-node";
import { writeFileSync } from "fs";
import {
  summarizeWord,
  openQuizDb,
  projectRoot,
  JMDICT_DB,
  QUIZ_SESSION,
} from "./shared.mjs";

const ids = process.argv.slice(2);
if (ids.length === 0) {
  console.error("Usage: write-quiz-session.mjs <id1> <id2> ...");
  process.exit(1);
}

// Load review history for these specific words
const quizDb = openQuizDb({ readonly: true });
const stats = new Map();
for (const id of ids) {
  const rows = quizDb
    .prepare(
      "SELECT score, timestamp FROM reviews WHERE word_id = ? ORDER BY timestamp ASC",
    )
    .all(id);
  if (rows.length === 0) continue;
  const scoreSum = rows.reduce((s, r) => s + r.score, 0);
  stats.set(id, {
    totalReviews: rows.length,
    scoreSum,
    lastTimestamp: rows[rows.length - 1].timestamp,
  });
}
quizDb.close();

function reviewStatus(id) {
  const s = stats.get(String(id));
  if (!s) return "never reviewed";
  const days = Math.floor(
    (Date.now() - new Date(s.lastTimestamp).getTime()) / 86_400_000,
  );
  const avg = (s.scoreSum / s.totalReviews).toFixed(2);
  return `${days}d ago, avg ${avg}, ${s.totalReviews} review${s.totalReviews !== 1 ? "s" : ""}`;
}

// Look up JMDict entries
const { db } = await setup(JMDICT_DB);
const words = idsToWords(db, ids);

if (words.length !== ids.length) {
  const found = new Set(words.map((w) => w.id));
  const missing = ids.filter((id) => !found.has(id));
  console.error(
    `Warning: could not find JMDict entries for IDs: ${missing.join(", ")}`,
  );
}

const timestamp = new Date().toISOString();
const lines = [
  `# Quiz session started ${timestamp}`,
  `# ${words.length} word${words.length !== 1 ? "s" : ""} — delete this file or run clear-quiz-session.mjs to discard`,
  "",
  ...words.map((w) => `${w.id}  ${summarizeWord(w)} [${reviewStatus(w.id)}]`),
];

writeFileSync(QUIZ_SESSION, lines.join("\n") + "\n");
console.log(`Session written: ${words.length} words → ${QUIZ_SESSION}`);
