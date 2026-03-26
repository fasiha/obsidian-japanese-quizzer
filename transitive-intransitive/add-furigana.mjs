#!/usr/bin/env node
/**
 * add-furigana.mjs
 *
 * For every drill sentence in transitive-pairs.json, calls the local furigana
 * endpoint and reconstructs the sentence using <ruby>/<rt> HTML tags.
 *
 * Usage:
 *   node add-furigana.mjs                        # writes transitive-pairs-furigana.json
 *   node add-furigana.mjs --out some-other.json  # custom output path
 *   node add-furigana.mjs --check                # validate existing furigana annotations
 *
 * The script verifies that stripping all ruby markup from the output yields
 * the original plain Japanese sentence.
 *
 * --check mode validates two things for every drill sentence:
 *   1. The sentence contains at least one CJK character from the pair's kanji
 *      array for that side (intransitive or transitive).
 *   2. For every kanji word in that array, if JMDict's furigana table has an
 *      entry matching (text=word, reading=kana), each ruby segment from that
 *      entry appears correctly in the jaFurigana HTML — confirming that
 *      homonyms (e.g. 開く read as ひらく vs あく) were not misannotated.
 */

import { readFile, writeFile } from "fs/promises";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import Database from "better-sqlite3";

const DIR = dirname(fileURLToPath(import.meta.url));
const INPUT = join(DIR, "transitive-pairs.json");
const BASE_URL = "http://127.0.0.1:8133/api/v1/sentence/";

const CHECK_MODE = process.argv.includes("--check");

const outFlagIndex = process.argv.indexOf("--out");
const OUTPUT =
  outFlagIndex !== -1 && process.argv[outFlagIndex + 1]
    ? process.argv[outFlagIndex + 1]
    : join(DIR, "transitive-pairs-furigana.json");

// ---------------------------------------------------------------------------
// Furigana API helpers
// ---------------------------------------------------------------------------

async function fetchFurigana(sentence) {
  const url = BASE_URL + encodeURIComponent(sentence);
  const res = await fetch(url);
  if (!res.ok) throw new Error(`HTTP ${res.status} for sentence: ${sentence}`);
  const json = await res.json();
  return json[0].furigana; // array of token arrays
}

/**
 * Flattens the array-of-arrays from the API into a single HTML string.
 * Each element is either a plain string or a { ruby, rt } object:
 *   string          → emit as-is
 *   { ruby, rt }    → <ruby>ruby<rt>rt</rt></ruby>
 */
function buildRubyHtml(furiganaTokens) {
  return furiganaTokens
    .flat()
    .map((el) =>
      typeof el === "string"
        ? el
        : `<ruby>${el.ruby}<rt>${el.rt}</rt></ruby>`
    )
    .join("");
}

/**
 * Strips <ruby>, </ruby>, and <rt>…</rt> tags, leaving only the ruby text.
 */
function stripRuby(html) {
  return html
    .replace(/<ruby>/g, "")
    .replace(/<\/ruby>/g, "")
    .replace(/<rt>[^<]*<\/rt>/g, "");
}

function assertRoundTrip(original, html) {
  const stripped = stripRuby(html);
  if (stripped !== original) {
    throw new Error(
      `Round-trip mismatch!\n  original : ${original}\n  stripped : ${stripped}\n  html     : ${html}`
    );
  }
}

// ---------------------------------------------------------------------------
// Check mode helpers
// ---------------------------------------------------------------------------

const CJK_REGEX = /[\u4e00-\u9fff\u3400-\u4dbf]/g;

/**
 * Returns all unique CJK characters found across an array of kanji word strings.
 * E.g. ["開く", "開ける"] → ["開"]
 */
function extractKanjiChars(kanjiWords) {
  const chars = new Set();
  for (const word of kanjiWords) {
    for (const ch of word.matchAll(CJK_REGEX)) chars.add(ch[0]);
  }
  return [...chars];
}

/**
 * Looks up the furigana segments for a kanji word + kana reading in JMDict.
 * Returns an array of { ruby, rt } objects (only the entries that have rt),
 * or null if no matching row exists.
 */
function lookupFuriganaSegs(db, kanjiWord, kana) {
  const row = db
    .prepare("SELECT segs FROM furigana WHERE text = ? AND reading = ? LIMIT 1")
    .get(kanjiWord, kana);
  if (!row) return null;
  const segs = JSON.parse(row.segs);
  return segs.filter((s) => s.rt !== undefined);
}

/**
 * Validates a single drill side. Returns an array of problem strings (empty = OK).
 *
 * If the sentence uses the target word in kana only (no kanji characters from
 * the pair's kanji list appear), the sentence is skipped — kana-only usage is
 * acceptable. The furigana reading check only runs when kanji are present, to
 * catch homonym misannotations (e.g. 開く annotated as ひらく when it should be あく).
 */
function checkDrillSide(db, drillSide, pairSide, label) {
  const problems = [];
  const { ja, jaFurigana } = drillSide;
  const { kana, kanji: kanjiWords } = pairSide;

  // Only check furigana readings when at least one CJK character from the
  // kanji list appears in the sentence. If the verb is written in kana only,
  // there is nothing to verify.
  const kanjiChars = extractKanjiChars(kanjiWords);
  const hasKanji = kanjiChars.some((ch) => ja.includes(ch));
  if (!hasKanji) return problems;

  if (!jaFurigana) {
    problems.push(`${label}: jaFurigana is missing for "${ja}"`);
    return problems;
  }

  for (const kanjiWord of kanjiWords) {
    const rubySegs = lookupFuriganaSegs(db, kanjiWord, kana);
    if (!rubySegs || rubySegs.length === 0) continue; // no entry or all kana — skip
    for (const seg of rubySegs) {
      const expected = `<ruby>${seg.ruby}<rt>${seg.rt}</rt></ruby>`;
      if (!jaFurigana.includes(expected)) {
        problems.push(
          `${label}: "${ja}" — expected furigana pattern "${expected}" (from ${kanjiWord}/${kana}) not found in jaFurigana`
        );
      }
    }
  }

  return problems;
}

async function runCheck() {
  const raw = await readFile(INPUT, "utf8");
  const pairs = JSON.parse(raw);
  const db = new Database(join(DIR, "..", "jmdict.sqlite"), { readonly: true });

  let totalSentences = 0;
  let totalProblems = 0;

  for (let pairIdx = 0; pairIdx < pairs.length; pairIdx++) {
    const pair = pairs[pairIdx];
    if (!pair.drills) continue;

    for (let drillIdx = 0; drillIdx < pair.drills.length; drillIdx++) {
      const drill = pair.drills[drillIdx];
      for (const side of ["intransitive", "transitive"]) {
        totalSentences++;
        const label = `pair[${pairIdx}] drill[${drillIdx}] ${side}`;
        const problems = checkDrillSide(db, drill[side], pair[side], label);
        for (const p of problems) {
          console.error(`FAIL: ${p}`);
          totalProblems++;
        }
      }
    }
  }

  db.close();
  if (totalProblems === 0) {
    console.log(`OK: all ${totalSentences} drill sentences passed.`);
  } else {
    console.error(
      `\n${totalProblems} problem(s) found across ${totalSentences} drill sentences.`
    );
    process.exit(1);
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const raw = await readFile(INPUT, "utf8");
  const pairs = JSON.parse(raw);

  let sentenceCount = 0;
  let errorCount = 0;

  for (const pair of pairs) {
    if (!pair.drills) continue;
    for (const drill of pair.drills) {
      for (const side of ["intransitive", "transitive"]) {
        const original = drill[side].ja;
        process.stderr.write(`  [${++sentenceCount}] ${original}\n`);
        try {
          const tokens = await fetchFurigana(original);
          const html = buildRubyHtml(tokens);
          assertRoundTrip(original, html);
          drill[side].jaFurigana = html;
        } catch (err) {
          errorCount++;
          process.stderr.write(`    ERROR: ${err.message}\n`);
          drill[side].jaFurigana = null;
        }
      }
    }
  }

  await writeFile(OUTPUT, JSON.stringify(pairs, null, 2), "utf8");
  process.stderr.write(
    `\nDone. ${sentenceCount - errorCount} sentences annotated` +
      (errorCount ? `, ${errorCount} errors` : "") +
      `.\nOutput written to: ${OUTPUT}\n`
  );
}

(CHECK_MODE ? runCheck() : main()).catch((err) => {
  console.error(err);
  process.exit(1);
});