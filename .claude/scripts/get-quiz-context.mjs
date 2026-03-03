/**
 * get-quiz-context.mjs
 * Outputs one compact line per quizzable vocab item, sorted by Ebisu recall
 * probability (most urgent first). Items with no Ebisu model yet are listed
 * at the end as [new].
 *
 * Output format — one line per word:
 *   <jmdictId>  <forms>  {kanji-ok|no-kanji}  <meanings>  →<facet>@<recall>
 *   <jmdictId>  <forms>  {kanji-ok|no-kanji}  <meanings>  →<facet>@<recall> free
 *
 * Example lines:
 *   1584060  包む, つつむ  {no-kanji}  to wrap up; to pack  →meaning-to-reading@0.31
 *   1445690  怒る, おこる  {kanji-ok}  to get angry; to scold  →meaning-reading-to-kanji@0.42 free
 *   1409600  体中, からだじゅう  {kanji-ok}  all over the body  →reading-to-meaning@new
 *   1009670  によると  {no-kanji}  according to (someone)  [new]
 *
 * Four statuses:
 *   →facet@0.XX       fully modeled; use multiple choice for this facet
 *   →facet@0.XX free  fully modeled; use free-answer (≥3 reviews AND halflife ≥48h for this facet)
 *   →facet@new        word has models for some facets, but this facet has never been
 *                     initialized — Claude should use the new-facet teaching approach
 *                     (e.g. word gained a [kanji] tag after initial introduction)
 *   [new]             no Ebisu models at all — full teaching approach
 *
 * Partially-modeled words (→facet@new) sort at the word's lowest existing recall,
 * so they interleave naturally with other items rather than crowding the top.
 *
 * For reviewed words, the facet shown is the one with the lowest recall
 * probability (most in need of practice). For [new] words, no Ebisu model
 * exists yet — Claude should use the teaching approach and then call
 * introduce-word.mjs to initialise their models.
 *
 * Also writes the full output to .claude/quiz-context.txt for use by
 * write-quiz-session.mjs. Call get-word-history.mjs for full per-facet
 * review history when needed.
 *
 * Usage: node .claude/scripts/get-quiz-context.mjs
 */

import { predictRecall } from "ebisu-js";
import { setup, findExactIds, idsToWords } from "jmdict-simplified-node";
import { readFileSync, writeFileSync } from "fs";
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
  QUIZ_CONTEXT,
} from "./shared.mjs";

function hoursAgo(isoTimestamp) {
  return (Date.now() - new Date(isoTimestamp).getTime()) / 3_600_000;
}

// Load Ebisu models keyed by "word_type\0word_id\0quiz_type"
// Load review counts keyed by "word_id\0quiz_type" (jmdict only)
const quizDb = openQuizDb({ readonly: true });
const modelRows = quizDb
  .prepare("SELECT word_type, word_id, quiz_type, alpha, beta, t, last_review FROM ebisu_models")
  .all();
const countRows = quizDb
  .prepare("SELECT word_id, quiz_type, COUNT(*) as count FROM reviews WHERE word_type = 'jmdict' GROUP BY word_id, quiz_type")
  .all();
quizDb.close();

const modelMap = new Map();
for (const row of modelRows) {
  const key = `${row.word_type}\0${row.word_id}\0${row.quiz_type}`;
  modelMap.set(key, row);
}

// Free-answer threshold: facet has been reviewed ≥3 times AND model halflife ≥48h
const countMap = new Map();
for (const row of countRows) {
  countMap.set(`${row.word_id}\0${row.quiz_type}`, row.count);
}

function recallForFacet(wordType, wordId, quizType) {
  const key = `${wordType}\0${wordId}\0${quizType}`;
  const row = modelMap.get(key);
  if (!row) return null; // no model = [new]
  const elapsed = hoursAgo(row.last_review);
  // predictRecall with exact=true returns linear probability 0–1
  return predictRecall([row.alpha, row.beta, row.t], Math.max(elapsed, 1e-6), true);
}

// True if the bullet text contains a [kanji] tag
function hasKanjiTag(bullet) {
  return /\[kanji\]/i.test(bullet);
}

// Scan opted-in Markdown files for vocab bullets
const { db } = await setup(JMDICT_DB);
const reviewed = [];   // { line, recall } — has at least one Ebisu model (recall=0 for @new facets)
const newWords  = [];  // { line } — no Ebisu models at all
let newFacetCount = 0; // reviewed words that have at least one unmodeled facet

for (const filePath of findMdFiles(projectRoot)) {
  const content = readFileSync(filePath, "utf8");
  if (!parseFrontmatter(content)?.["llm-review"]) continue;

  for (const bullet of extractVocabBullets(content)) {
    const tokens = extractJapaneseTokens(bullet);
    if (tokens.length === 0) continue;

    const idSets = tokens.map((token) => new Set(findExactIds(db, token)));
    const matchIds = [...intersectSets(idSets)];
    if (matchIds.length !== 1) continue;

    const [word] = idsToWords(db, matchIds);
    const kanjiTag = hasKanjiTag(bullet);
    const wordType = "jmdict";
    const facetMarker = kanjiTag ? "{kanji-ok}" : "{no-kanji}";
    const targetedFacets = kanjiTag
      ? ["kanji-to-reading", "reading-to-meaning", "meaning-to-reading", "meaning-reading-to-kanji"]
      : ["reading-to-meaning", "meaning-to-reading"];

    // Find the facet with the lowest recall probability; collect unmodeled facets
    let lowestRecall = Infinity;
    let lowestFacet = null;
    let anyModel = false;
    const unmodeledFacets = [];

    for (const facet of targetedFacets) {
      const recall = recallForFacet(wordType, String(word.id), facet);
      if (recall === null) {
        unmodeledFacets.push(facet);
        continue;
      }
      anyModel = true;
      if (recall < lowestRecall) {
        lowestRecall = recall;
        lowestFacet = facet;
      }
    }

    const summary = summarizeWord(word);
    const line = `${word.id}  ${summary}  ${facetMarker}`;

    if (!anyModel) {
      // All facets unmodeled — completely new word
      newWords.push(`${line}  [new]`);
    } else if (unmodeledFacets.length > 0) {
      // Word is known in some facets; surface first unmodeled facet.
      // Sort at the same urgency as the word's worst-recalled existing facet
      // so @new items interleave naturally rather than crowding the top.
      newFacetCount++;
      reviewed.push({
        line: `${line}  →${unmodeledFacets[0]}@new`,
        recall: lowestRecall,
      });
    } else {
      // All facets modeled — show most-forgotten one
      const modelRow = modelMap.get(`${wordType}\0${String(word.id)}\0${lowestFacet}`);
      const reviewCount = countMap.get(`${String(word.id)}\0${lowestFacet}`) ?? 0;
      const freeFlag = (reviewCount >= 3 && modelRow.t >= 48) ? " free" : "";
      reviewed.push({
        line: `${line}  →${lowestFacet}@${lowestRecall.toFixed(2)}${freeFlag}`,
        recall: lowestRecall,
      });
    }
  }
}

// Sort reviewed words by recall ascending (lowest = most urgent)
reviewed.sort((a, b) => a.recall - b.recall);

const lines = [
  ...reviewed.map((r) => r.line),
  ...newWords,
];

writeFileSync(QUIZ_CONTEXT, lines.join("\n") + "\n");
const newFacetSuffix = newFacetCount > 0 ? ` (${newFacetCount} with new facets)` : "";
console.log(
  `Context written: ${reviewed.length} reviewed${newFacetSuffix} + ${newWords.length} new = ${lines.length} words → ${QUIZ_CONTEXT}`
);
