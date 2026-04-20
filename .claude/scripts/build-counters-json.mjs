// build-counters-json.mjs
// Parses counters/TofuguList.tsv, filters to the top three frequency tiers
// (Absolutely Must Know, Must Know, Common), looks up each counter in
// jmdict.sqlite, and writes counters.json.
//
// Usage: node .claude/scripts/build-counters-json.mjs [--dry-run]
//
// Flags any counter where JMDict lookup finds zero or multiple matches so
// you can resolve them manually before committing counters.json.

import { readFileSync, writeFileSync } from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { setup, findExact, kanjiBeginning, idsToWords } from "jmdict-simplified-node";
import { projectRoot } from "./shared.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DRY_RUN = process.argv.includes("--dry-run");

// Manual overrides for counters where the ctr-sense filter still leaves
// multiple candidates. Maps "kanji|reading" → the correct JMDict ID.
// Resolved by inspecting each candidate's senses and readings via lookup.mjs.
const MANUAL_IDS = {
  "個|こ":     "1264740", // こ counter for small things (not か/つ readings)
  "本|ほん":   "1522150", // ほん book+counter entry (not もと/origin entry)
  "枚|まい":   "1524610", // まい flat-things counter (not ひら reading)
  "分|ふん":   "1502840", // ふん minutes (not ぶ or ぶん)
  "年|ねん":   "2084840", // ねん year counter (not とせ reading)
  "日|か/にち": null,     // two TSV rows: handled below per-reading
  "日|にち":   "2083100", // にち days/nth day
  "日|か":     "2083110", // か day-of-month reading
  "月|つき":   "1255430", // つき moon/month (not げつ=Monday)
  "月|がつ":   "1255430", // same entry, different reading context
  "時|じ":     "2020680", // じ o'clock (not とき or どき)
  "歳|さい":   "1294940", // さい years old (not とせ)
  "円|えん":   "1175570", // えん yen (not まる/circle)
  "曲|きょく": "1239700", // きょく song/piece (not くま/まが/くせ readings)
  "口|くち":   "1275640", // くち main entry with counter senses
  "席|せき":   "1382250", // せき seat (not むしろ/mat)
  "戦|せん":   "2080730", // せん match/game suffix (not いくさ/war)
  "束|たば":   "1404450", // たば bundle (common reading)
  "度|ど":     "1445160", // ど degree/occurrences (not たび)
  "杯|はい":   "2019640", // はい cup/bowl counter (not はた)
  "番|ばん":   "2022640", // ばん number in series (not つがい/mated pair)
  "便|びん":   "1512360", // びん flight/mail (not べん or よすが)
};

const INCLUDED_CATEGORIES = new Set([
  "Absolutely Must Know",
  "Must Know",
  "Common",
]);

// TSV column indices (0-based), based on the header row:
// Kanji, Reading, What it counts, Category, Use, 1..10, How Many, Article URL, Notes
const COL_KANJI = 0;
const COL_READING = 1;
const COL_WHAT = 2;
const COL_CATEGORY = 3;
const COL_N = {
  1: 5,
  2: 6,
  3: 7,
  4: 8,
  5: 9,
  6: 10,
  7: 11,
  8: 12,
  9: 13,
  10: 14,
};
const COL_HOW_MANY = 15;

const tsvPath = path.join(projectRoot, "counters", "TofuguList.tsv");
const raw = readFileSync(tsvPath, "utf8");
const lines = raw.split("\n");

// Row 0 is a junk header ("↑ Click File > Download As…"), row 1 is the real header.
const dataLines = lines.slice(2);

const { db } = await setup(path.join(projectRoot, "jmdict.sqlite"));

const results = [];
const misses = [];

for (const line of dataLines) {
  if (!line.trim()) continue;
  const cols = line.split("\t");
  const category = cols[COL_CATEGORY]?.trim();
  if (!INCLUDED_CATEGORIES.has(category)) continue;

  const kanji = cols[COL_KANJI]?.trim();
  const reading = cols[COL_READING]?.trim();
  const whatItCounts = cols[COL_WHAT]?.trim();

  const pronunciations = {};
  for (const [n, colIdx] of Object.entries(COL_N)) {
    pronunciations[n] = cols[colIdx]?.trim() ?? "";
  }
  pronunciations["how-many"] = cols[COL_HOW_MANY]?.trim() ?? "";

  // 〜つ is the wago counter — no kanji form, skip JMDict lookup.
  // It will appear in the wago Markdown file instead.
  if (kanji === "〜つ") {
    console.log(`[skip]  〜つ — wago counter, handled via Markdown file`);
    continue;
  }

  // Check manual override first.
  const manualId = MANUAL_IDS[`${kanji}|${reading}`];
  if (manualId !== undefined) {
    if (manualId === null) continue; // sentinel: skip this row entirely
    const [word] = idsToWords(db, [manualId]);
    const senseIndex = word.sense.findIndex((s) => s.partOfSpeech.includes("ctr"));
    results.push({ jmdictId: word.id, ...(senseIndex >= 0 && { senseIndex }), kanji, reading, category, whatItCounts, pronunciations });
    console.log(`[ok]    ${kanji} (${reading}) → JMDict ${word.id} (manual)`);
    continue;
  }

  // Look up in JMDict by exact kanji match first, then by reading if needed.
  let matches = findExact(db, kanji);

  // findExact searches both kanji and kana forms; filter to entries that
  // actually have the kanji form we want (avoids kana-only false positives).
  const kanjiMatches = matches.filter((w) =>
    w.kanji.some((k) => k.text === kanji)
  );

  // Prefer entries that have at least one sense tagged as a counter (ctr).
  const isCtr = (w) => w.sense.some((s) => s.partOfSpeech.includes("ctr"));
  const ctrMatches = kanjiMatches.filter(isCtr);
  const pool = ctrMatches.length > 0 ? ctrMatches : kanjiMatches;

  const resolve = (word, note = "") => {
    const senseIndex = word.sense.findIndex((s) => s.partOfSpeech.includes("ctr"));
    results.push({
      jmdictId: word.id,
      ...(senseIndex >= 0 && { senseIndex }),
      kanji,
      reading,
      category,
      whatItCounts,
      pronunciations,
    });
    console.log(`[ok]    ${kanji} (${reading}) → JMDict ${word.id}${note}`);
  };

  if (pool.length === 1) {
    resolve(pool[0], ctrMatches.length === 1 ? " (ctr sense)" : "");
  } else if (pool.length === 0) {
    // Try a broader search in case the entry uses a slightly different form.
    const broader = kanjiBeginning(db, kanji).filter((w) =>
      w.kanji.some((k) => k.text === kanji)
    );
    const broaderCtr = broader.filter(isCtr);
    const broaderPool = broaderCtr.length > 0 ? broaderCtr : broader;
    if (broaderPool.length === 1) {
      resolve(broaderPool[0], " (broader search)");
    } else {
      misses.push({ kanji, reading, category, reason: "no match", broader });
      console.warn(`[miss]  ${kanji} (${reading}) — no JMDict match`);
    }
  } else {
    // Still ambiguous after ctr filtering — log for manual resolution.
    misses.push({
      kanji,
      reading,
      category,
      reason: "ambiguous",
      candidates: pool.map((w) => w.id),
    });
    console.warn(
      `[ambig] ${kanji} (${reading}) — ${pool.length} matches after ctr filter: ${pool.map((w) => w.id).join(", ")}`
    );
  }
}

db.close();

console.log(`\n${results.length} counters resolved, ${misses.length} need attention.`);

if (misses.length > 0) {
  console.log("\nCounters needing manual resolution:");
  for (const m of misses) {
    if (m.reason === "ambiguous") {
      console.log(`  ${m.kanji} (${m.reading}) [${m.category}] — candidates: ${m.candidates.join(", ")}`);
    } else {
      console.log(`  ${m.kanji} (${m.reading}) [${m.category}] — no match`);
      if (m.broader.length > 0) {
        console.log(`    Broader search found: ${m.broader.map((w) => `${w.id} ${w.kanji.map((k) => k.text).join("/")}`).join(", ")}`);
      }
    }
  }
}

if (!DRY_RUN) {
  const outPath = path.join(projectRoot, "counters", "counters.json");
  writeFileSync(outPath, JSON.stringify(results, null, 2) + "\n");
  console.log(`\nWrote ${results.length} entries to counters.json`);
} else {
  console.log("\n[dry-run] counters.json not written.");
}