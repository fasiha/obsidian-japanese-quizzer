/**
 * introduce-word.mjs
 * Initialises Ebisu models for a newly-taught word without inserting a
 * review row. Call this after Claude teaches a [new] word so the item
 * enters the spaced-repetition schedule.
 *
 * Required args:
 *   --word-id        TEXT    JMDict entry ID (or other word type ID)
 *   --word-text      TEXT    Display text (used for session removal)
 *   --facets         TEXT    Comma-separated facets to initialise, e.g.
 *                              "reading-to-meaning,meaning-to-reading"
 *
 * Optional args:
 *   --word-type      TEXT    'jmdict' (default) or 'grammar'
 *   --halflife       FLOAT   Initial halflife in hours (default: 24)
 *   --passive-facets TEXT    Comma-separated already-modelled facets to
 *                              passively update with score=0.5 (moves model
 *                              forward in time without changing halflife).
 *                              Silently skipped if no model exists yet.
 *
 * Usage:
 *   node .claude/scripts/introduce-word.mjs \
 *     --word-id 1009670 --word-text "によると" \
 *     --facets "reading-to-meaning,meaning-to-reading"
 *
 *   # User already knows it well — longer halflife:
 *   node .claude/scripts/introduce-word.mjs \
 *     --word-id 1009670 --word-text "によると" \
 *     --facets "reading-to-meaning,meaning-to-reading" --halflife 72
 *
 *   # Introduce one facet, passively nudge the sibling:
 *   node .claude/scripts/introduce-word.mjs \
 *     --word-id 1503510 --word-text "分厚い" \
 *     --facets "reading-to-meaning" \
 *     --passive-facets "meaning-to-reading" --halflife 168
 */

import { readFileSync, writeFileSync, existsSync } from "fs";
import { defaultModel, updateRecall } from "ebisu-js";
import { openQuizDb, QUIZ_SESSION, EBISU_ALPHA } from "./shared.mjs";

const args = process.argv.slice(2);
let wordType = "jmdict";
let wordId, wordText, halflife = 24;
let facets = [];
let passiveFacets = [];

for (let i = 0; i < args.length; i++) {
  if (args[i] === "--word-type" && args[i + 1]) wordType = args[++i];
  if (args[i] === "--word-id" && args[i + 1]) wordId = args[++i];
  if (args[i] === "--word-text" && args[i + 1]) wordText = args[++i];
  if (args[i] === "--halflife" && args[i + 1]) halflife = parseFloat(args[++i]);
  if (args[i] === "--facets" && args[i + 1])
    facets = args[++i].split(",").map((s) => s.trim()).filter(Boolean);
  if (args[i] === "--passive-facets" && args[i + 1])
    passiveFacets = args[++i].split(",").map((s) => s.trim()).filter(Boolean);
}

const missing = [];
if (!wordId) missing.push("--word-id");
if (!wordText) missing.push("--word-text");
if (facets.length === 0) missing.push("--facets");
if (missing.length > 0) {
  console.error(`Missing required arguments: ${missing.join(", ")}`);
  process.exit(1);
}

if (isNaN(halflife) || halflife <= 0) {
  console.error(`--halflife must be a positive number (got: ${halflife})`);
  process.exit(1);
}

const timestamp = new Date().toISOString();
const [a, b, t] = defaultModel(halflife, EBISU_ALPHA, EBISU_ALPHA);

const db = openQuizDb();
const stmt = db.prepare(
  "INSERT OR REPLACE INTO ebisu_models (word_type, word_id, quiz_type, alpha, beta, t, last_review) VALUES (?,?,?,?,?,?,?)",
);

for (const facet of facets) {
  stmt.run(wordType, wordId, facet, a, b, t, timestamp);
}

// Passive updates: nudge existing sibling models forward in time (score=0.5
// leaves the halflife estimate unchanged, just advances last_review)
for (const facet of passiveFacets) {
  const existing = db
    .prepare(
      "SELECT alpha, beta, t, last_review FROM ebisu_models WHERE word_type=? AND word_id=? AND quiz_type=?",
    )
    .get(wordType, wordId, facet);
  if (!existing) continue; // no model yet — skip silently
  const model = [existing.alpha, existing.beta, existing.t];
  const elapsed = (new Date(timestamp) - new Date(existing.last_review)) / 3_600_000;
  const [pa, pb, pt] = updateRecall(model, 0.5, 1, Math.max(elapsed, 1e-6));
  stmt.run(wordType, wordId, facet, pa, pb, pt, timestamp);
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
    wordType,
    wordId,
    wordText,
    facets,
    halflife,
    passiveFacets,
    timestamp,
  }),
);
