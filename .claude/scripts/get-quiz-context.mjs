/**
 * get-quiz-context.mjs
 * Outputs one compact line per quizzable vocab item, merged with all-time quiz history.
 * Items where the vocab bullet doesn't resolve to exactly one JMDict entry are omitted.
 *
 * Output format — one line per word:
 *   <jmdictId>  <kanji/kana>, <meanings> (#<id>) [<review status>]
 *
 * Words with a [kanji] tag in their vocab bullet get a {kanji} marker:
 *   1445740  怒鳴る, どなる to shout in anger (#1445740) {kanji} [never reviewed]
 *
 * Review status shows per-facet breakdown when quiz_type data exists:
 *   1445740  怒鳴る, どなる ... {kanji} [meaning:0d/0.50×1, kanji:never]
 * Otherwise falls back to overall summary:
 *   1584060  包む, つつむ ... [5d ago, avg 0.80, 2 reviews]
 *
 * Options:
 *   --reviewer NAME   Filter quiz history to one reviewer (default: all reviewers)
 *
 * Usage: node .claude/scripts/get-quiz-context.mjs [--reviewer fasiha]
 */

import { setup, findExact, idsToWords } from "jmdict-simplified-node";
import { readFileSync } from "fs";
import {
  findMdFiles,
  extractJapaneseTokens,
  intersectSets,
  parseFrontmatter,
  extractVocabBullets,
  summarizeWord,
  openQuizDb,
  projectRoot,
  JMDICT_DB,
} from "./shared.mjs";

const args = process.argv.slice(2);
let reviewer = null;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--reviewer" && args[i + 1]) reviewer = args[++i];
}

// Load all-time quiz history, keyed by word_id
const quizDb = openQuizDb({ readonly: true });
const historyRows = reviewer
  ? quizDb
      .prepare(
        "SELECT word_id, score, timestamp, quiz_type FROM reviews WHERE reviewer = ? ORDER BY timestamp ASC",
      )
      .all(reviewer)
  : quizDb
      .prepare(
        "SELECT word_id, score, timestamp, quiz_type FROM reviews ORDER BY timestamp ASC",
      )
      .all();
quizDb.close();

// stats: word_id -> { total: {totalReviews, scoreSum, lastTimestamp},
//                    byType: Map<quiz_type, {totalReviews, scoreSum, lastTimestamp}>,
//                    nullCount: number }
const stats = new Map();
for (const row of historyRows) {
  if (!stats.has(row.word_id)) {
    stats.set(row.word_id, {
      total: { totalReviews: 0, scoreSum: 0, lastTimestamp: null },
      byType: new Map(),
      nullCount: 0,
    });
  }
  const s = stats.get(row.word_id);
  s.total.totalReviews++;
  s.total.scoreSum += row.score;
  s.total.lastTimestamp = row.timestamp;
  if (row.quiz_type) {
    if (!s.byType.has(row.quiz_type))
      s.byType.set(row.quiz_type, {
        totalReviews: 0,
        scoreSum: 0,
        lastTimestamp: null,
      });
    const ts = s.byType.get(row.quiz_type);
    ts.totalReviews++;
    ts.scoreSum += row.score;
    ts.lastTimestamp = row.timestamp;
  } else {
    s.nullCount++;
  }
}

function daysAgo(timestamp) {
  return Math.floor((Date.now() - new Date(timestamp).getTime()) / 86_400_000);
}

function reviewStatus(wordId, targetedFacets) {
  const s = stats.get(String(wordId));
  if (!s) return "never reviewed";

  // If we have any quiz_type-tagged reviews, show per-facet breakdown
  if (s.byType.size > 0) {
    const parts = [];
    // Show all targeted facets (so "never" entries are visible for unreviewed facets)
    const facetsToShow = new Set([...targetedFacets, ...s.byType.keys()]);
    for (const facet of facetsToShow) {
      const ts = s.byType.get(facet);
      if (!ts) {
        parts.push(`${facet}:never`);
        continue;
      }
      const avg = (ts.scoreSum / ts.totalReviews).toFixed(2);
      parts.push(
        `${facet}:${daysAgo(ts.lastTimestamp)}d/${avg}×${ts.totalReviews}`,
      );
    }
    // If there are also untracked (null quiz_type) reviews, note them
    if (s.nullCount > 0) {
      const avg = (s.total.scoreSum / s.total.totalReviews).toFixed(2);
      parts.push(
        `untracked:${daysAgo(s.total.lastTimestamp)}d/${avg}×${s.nullCount}`,
      );
    }
    return parts.join(", ");
  }

  // Old-style: all reviews have quiz_type = null — show overall summary
  const avg = (s.total.scoreSum / s.total.totalReviews).toFixed(2);
  return `${daysAgo(s.total.lastTimestamp)}d ago, avg ${avg}, ${s.total.totalReviews} review${s.total.totalReviews !== 1 ? "s" : ""}`;
}

// True if the bullet text contains a [kanji] tag
function hasKanjiTag(bullet) {
  return /\[kanji\]/i.test(bullet);
}

// Scan opted-in Markdown files for vocab bullets
const { db } = await setup(JMDICT_DB);
const lines = [];

for (const filePath of findMdFiles(projectRoot)) {
  const content = readFileSync(filePath, "utf8");
  if (!parseFrontmatter(content)?.["llm-review"]) continue;

  for (const bullet of extractVocabBullets(content)) {
    const tokens = extractJapaneseTokens(bullet);
    if (tokens.length === 0) continue;

    const idSets = tokens.map(
      (token) => new Set(findExact(db, token).map((w) => w.id)),
    );
    const matchIds = [...intersectSets(idSets)];
    if (matchIds.length !== 1) continue; // skip broken entries

    const [word] = idsToWords(db, matchIds);
    const kanjiTag = hasKanjiTag(bullet);
    // Default facets every word is tested on; add kanji if tagged
    const targetedFacets = kanjiTag
      ? ["reading", "meaning", "kanji"]
      : ["reading", "meaning"];
    const facetMarker = kanjiTag ? " {kanji}" : "";
    lines.push(
      `${word.id}  ${summarizeWord(word)}${facetMarker} [${reviewStatus(word.id, targetedFacets)}]`,
    );
  }
}

console.log(lines.join("\n"));
