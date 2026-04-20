// build-counters-json.mjs
// Parses counters/TofuguList.tsv, filters to the top three frequency tiers
// (Absolutely Must Know, Must Know, Common), looks up each counter in
// jmdict.sqlite, and writes counters.json.
//
// Usage: node .claude/scripts/build-counters-json.mjs [--dry-run]
//
// Flags any counter where JMDict lookup finds zero or multiple matches so
// you can resolve them manually before committing counters.json.
//
// Output schema per entry:
//
//   {
//     "id": "ほん",                  // stable word_id for Ebisu models; kana-based, unique
//     "kanji": "本",
//     "reading": "ほん",
//     "category": "Must Know",
//     "whatItCounts": "Long, cylindrical things",
//     "countExamples": [],           // leave empty; fill in manually from Tofugu article
//     "jmdict": {                    // null when no JMDict entry exists at all
//       "id": "1522150",
//       "senseIndex": 4             // index of the counter sense; null when the entry exists
//                                   // but JMDict has no counter-tagged sense (e.g. 文字, 部屋)
//     },
//     "pronunciations": {
//       "1": "いっぽん",
//       ...
//       "10": "じゅっぽん",
//       "how-many": "なんぼん"
//     }
//   }
//
// senseIndex === 0        → counter is the primary (first) sense
// senseIndex > 0          → counter sense exists but is not the first sense
// senseIndex === null     → entry exists but JMDict never tagged it as a counter;
//                           surfaced in WordDetailSheet so learners see the normal meaning

import { readFileSync, writeFileSync } from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { setup, findExact, kanjiBeginning, idsToWords } from "jmdict-simplified-node";
import { projectRoot } from "./shared.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Manual overrides for counters where the ctr-sense filter still leaves
// multiple candidates. Maps "kanji|reading" → the correct JMDict ID.
// Use null to skip a TSV row entirely (e.g. duplicate header rows).
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
  "月|がつ":   "1255430", // same JMDict entry, different reading context (calendar months)
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

// Manual overrides for "no-counter-sense" entries: counters that appear in
// Tofugu's list but whose JMDict entry has no "ctr" part-of-speech tag.
// Maps "kanji|reading" → the JMDict ID of a closely related entry that
// WordDetailSheet should surface alongside the counter meaning.
// Set to null if there is truly no useful related JMDict entry.
const RELATED_IDS = {
  // Add entries here when the auto-lookup finds a JMDict entry with no ctr sense.
  // Example (hypothetical):
  //   "文字|もじ": "1254180",
  //   "部屋|へや": "1532500",
};

// Explicit stable IDs for entries whose reading is shared by multiple TSV rows.
// Without an override, the script will abort on any reading collision.
// Maps "kanji|reading" → stable kana ID string.
// 月 has two distinct TSV rows with different readings (つき vs がつ), so they
// auto-resolve without an override. 組(くみ) has two rows with the same reading,
// so both need explicit overrides keyed by "kanji|reading|whatItCounts".
//
// Convention: when a counter reading collides with a more common word, the
// counter keeps the plain reading as its ID and the less-common counter gets
// a kanji-suffixed ID (e.g. かい-階). For 組, both rows are counters so both
// get descriptive suffixes.
const ID_OVERRIDES = {
  "階|かい": "かい-階",   // 階 floors; plain "かい" belongs to 回 occurrences
  "巻|かん": "かん-巻",   // 巻 volumes; plain "かん" belongs to 缶 cans
  "軒|けん": "けん-軒",   // 軒 buildings; plain "けん" belongs to 件 matters/cases
  "周|しゅう": "しゅう-周", // 周 circuits/laps; plain "しゅう" belongs to 週 weeks
  "話|わ": "わ-話",       // 話 episodes; plain "わ" belongs to 羽 birds/rabbits
  // 組 has two TSV rows with the same kanji and reading — both need explicit IDs.
  // The key includes whatItCounts (truncated) to distinguish them.
  "組|くみ|Couples, pairs, or groups of something": "くみ-グループ",
  "組|くみ|Classroom numbers": "くみ-クラス",
};

const INCLUDED_CATEGORIES = new Set([
  "Absolutely Must Know",
  "Must Know",
  "Common",
]);

// TSV column indices (0-based), based on the header row:
// Kanji, Reading, What it counts, Category, Use, 1..10, How Many, Article URL, Notes
const COL_KANJI    = 0;
const COL_READING  = 1;
const COL_WHAT     = 2;
const COL_CATEGORY = 3;
const COL_N = { 1: 5, 2: 6, 3: 7, 4: 8, 5: 9, 6: 10, 7: 11, 8: 12, 9: 13, 10: 14 };
const COL_HOW_MANY = 15;

const tsvPath = path.join(projectRoot, "counters", "TofuguList.tsv");
const raw = readFileSync(tsvPath, "utf8");
const lines = raw.split("\n");

// Row 0 is a junk header ("↑ Click File > Download As…"), row 1 is the real header.
const dataLines = lines.slice(2);

// tofugu-350.json was scraped from the Tofugu counters article. Its `list` and
// `examples` arrays are parallel (list[i] names the counter, examples[i] describes it).
// We build a lookup keyed by the kanji form extracted from each list entry, with the
// reading as a tiebreaker for entries that share a kanji (e.g. 巻 appears as both
// かん and まき in the full list).
const tofuguJson = JSON.parse(readFileSync(path.join(projectRoot, "counters", "tofugu-350.json"), "utf8"));

// Build map: kanji → array of { readings: string[], rawExamples: string }
// readings comes from the parenthetical in the list entry, split on /
const tofuguByKanji = new Map();
for (let i = 0; i < tofuguJson.list.length; i++) {
  const entry = tofuguJson.list[i];
  // "THE 〜つ COUNTER" → kanji="〜つ", readings=[]
  // "本 (ほん)" → kanji="本", readings=["ほん"]
  // "月 (つき/がつ)" → kanji="月", readings=["つき","がつ"]
  // "折/折り (おり)" → kanji="折", readings=["おり"]
  const stripped   = entry.replace(/^THE\s+/, "").replace(/\s+COUNTER$/, "").trim();
  const parenMatch = stripped.match(/^(.+?)\s*\(([^)]+)\)/);
  const kanji      = parenMatch ? parenMatch[1].split("/")[0] : stripped.split("/")[0];
  const readings   = parenMatch ? parenMatch[2].split("/").map((r) => r.trim()) : [];
  if (!tofuguByKanji.has(kanji)) tofuguByKanji.set(kanji, []);
  tofuguByKanji.get(kanji).push({ readings, rawExamples: tofuguJson.examples[i] ?? "" });
}

const tofuguLookupCounts = new Map();

function lookupExamples(kanji, reading) {
  // TSV readings may contain slashes (e.g. "しな/ひん"); split and match any component.
  const readingParts = reading.split("/");
  const candidates = (tofuguByKanji.get(kanji) ?? [])
    .filter((c) => c.readings.length === 0 || c.readings.some((r) => readingParts.includes(r)));
  if (candidates.length === 0) return "";
  const key = `${kanji}|${reading}`;
  const n   = tofuguLookupCounts.get(key) ?? 0;
  tofuguLookupCounts.set(key, n + 1);
  return (candidates[n] ?? candidates[0]).rawExamples;
}

function parseExamples(raw) {
  if (!raw) return [];
  let s = raw.replace(/^Counts:\s*/i, "").trim();
  s = s.replace(/,?\s*and much,?\s*much more\.?$/i, "");
  s = s.replace(/,?\s*and more\.?$/i, "");
  s = s.replace(/,?\s*etc\.?$/i, "");
  return s.split(/,\s*/).map((x) => x.trim()).filter(Boolean);
}

// Parses a single TSV pronunciation cell into { primary, rare }.
// Space-separated tokens outside parentheses are equally valid alternates (primary).
// Tokens inside parentheses are rare or less-preferred variants.
// Example: "ななほん (しちほん)" → { primary: ["ななほん"], rare: ["しちほん"] }
// Example: "はっぽん はちほん"   → { primary: ["はっぽん", "はちほん"], rare: [] }
function parsePronunciationCell(cell) {
  const rare = [];
  // Extract all parenthesized groups and collect their contents as rare readings.
  const withoutParens = cell.replace(/\(([^)]+)\)/g, (_, inner) => {
    rare.push(...inner.trim().split(/\s+/).filter(Boolean));
    return "";
  });
  const primary = withoutParens.trim().split(/\s+/).filter(Boolean);
  return { primary, rare };
}

const { db } = await setup(path.join(projectRoot, "jmdict.sqlite"));

const results = [];
const misses  = [];
const seenIds = new Map(); // id → kanji|reading, for collision detection

function buildEntry({ id, kanji, reading, category, whatItCounts, countExamples, pronunciations, word, noCounterSenseForRelated = false }) {
  let jmdict = null;
  if (word) {
    const senseIndex = noCounterSenseForRelated
      ? null
      : word.sense.findIndex((s) => s.partOfSpeech.includes("ctr"));
    jmdict = { id: word.id, senseIndex: senseIndex >= 0 ? senseIndex : null };
  }
  return { id, kanji, reading, category, whatItCounts, countExamples, jmdict, pronunciations };
}

function resolveId(kanji, reading, whatItCounts) {
  // Try most-specific key first (includes whatItCounts), then fall back to kanji|reading.
  const specificKey = `${kanji}|${reading}|${whatItCounts}`;
  const generalKey  = `${kanji}|${reading}`;
  const override = specificKey in ID_OVERRIDES
    ? ID_OVERRIDES[specificKey]
    : ID_OVERRIDES[generalKey];
  if (override === null) {
    return { id: null, needsResolution: true };
  }
  const id = override ?? reading;
  return { id, needsResolution: false };
}

for (const line of dataLines) {
  if (!line.trim()) continue;
  const cols     = line.split("\t");
  const category = cols[COL_CATEGORY]?.trim();

  const kanji        = cols[COL_KANJI]?.trim();
  const reading      = cols[COL_READING]?.trim();
  const whatItCounts = cols[COL_WHAT]?.trim();
  const countExamples = parseExamples(lookupExamples(kanji, reading));

  if (!INCLUDED_CATEGORIES.has(category)) continue;

  const pronunciations = {};
  for (const [n, colIdx] of Object.entries(COL_N)) {
    pronunciations[n] = parsePronunciationCell(cols[colIdx]?.trim() ?? "");
  }
  pronunciations["how-many"] = parsePronunciationCell(cols[COL_HOW_MANY]?.trim() ?? "");

  // 〜つ is the wago counter — no kanji form, handled via wago Markdown file.
  if (kanji === "〜つ") {
    console.log(`[skip]  〜つ — wago counter, handled via Markdown file`);
    continue;
  }

  // Check MANUAL_IDS before ID resolution so null (skip) sentinels never touch seenIds.
  const overrideKey = `${kanji}|${reading}`;
  const manualId    = MANUAL_IDS[overrideKey];
  if (manualId === null) continue; // sentinel: skip this row entirely

  const { id, needsResolution } = resolveId(kanji, reading, whatItCounts);
  if (needsResolution) {
    misses.push({ kanji, reading, category, reason: "id-collision", whatItCounts });
    console.warn(`[id?]   ${kanji} (${reading}) — ID collision; add to ID_OVERRIDES`);
    continue;
  }

  if (seenIds.has(id)) {
    const prior = seenIds.get(id);
    misses.push({ kanji, reading, category, reason: "id-collision", whatItCounts });
    console.warn(`[id?]   ${kanji} (${reading}) — ID "${id}" already used by ${prior}; add override`);
    continue;
  }
  seenIds.set(id, `${kanji}|${reading}`);

  if (manualId !== undefined) {
    const [word] = idsToWords(db, [manualId]);
    const entry  = buildEntry({ id, kanji, reading, category, whatItCounts, countExamples, pronunciations, word });
    results.push(entry);
    console.log(`[ok]    ${kanji} (${reading}) → JMDict ${word.id} (manual)`);
    continue;
  }

  // Check if this is a known "no-counter-sense" entry with a related JMDict ID.
  const relatedId = RELATED_IDS[overrideKey];
  if (relatedId !== undefined) {
    if (relatedId === null) {
      // No related entry at all.
      const entry = buildEntry({ id, kanji, reading, category, whatItCounts, pronunciations, word: null });
      results.push(entry);
      console.log(`[ok]    ${kanji} (${reading}) → no JMDict entry`);
    } else {
      const [word] = idsToWords(db, [relatedId]);
      const entry  = buildEntry({ id, kanji, reading, category, whatItCounts, countExamples, pronunciations, word, noCounterSenseForRelated: true });
      results.push(entry);
      console.log(`[ok]    ${kanji} (${reading}) → JMDict ${word.id} (related, no counter sense) (manual)`);
    }
    continue;
  }

  // Auto-lookup: exact kanji match first.
  const allMatches  = findExact(db, kanji);
  const kanjiMatches = allMatches.filter((w) => w.kanji.some((k) => k.text === kanji));
  const isCtr        = (w) => w.sense.some((s) => s.partOfSpeech.includes("ctr"));
  const ctrMatches   = kanjiMatches.filter(isCtr);
  const pool         = ctrMatches.length > 0 ? ctrMatches : kanjiMatches;

  const resolveWord = (word, note = "") => {
    const entry = buildEntry({ id, kanji, reading, category, whatItCounts, countExamples, pronunciations, word });
    results.push(entry);
    console.log(`[ok]    ${kanji} (${reading}) → JMDict ${word.id}${note}`);
  };

  if (pool.length === 1) {
    resolveWord(pool[0], ctrMatches.length === 1 ? " (ctr sense)" : "");
  } else if (pool.length === 0) {
    // Broader search in case the entry uses a slightly different kanji form.
    const broader    = kanjiBeginning(db, kanji).filter((w) => w.kanji.some((k) => k.text === kanji));
    const broaderCtr = broader.filter(isCtr);
    const broaderPool = broaderCtr.length > 0 ? broaderCtr : broader;
    if (broaderPool.length === 1) {
      resolveWord(broaderPool[0], " (broader search)");
    } else {
      misses.push({ kanji, reading, category, reason: "no match", broader });
      console.warn(`[miss]  ${kanji} (${reading}) — no JMDict match`);
    }
  } else {
    misses.push({ kanji, reading, category, reason: "ambiguous", candidates: pool.map((w) => w.id) });
    console.warn(`[ambig] ${kanji} (${reading}) — ${pool.length} matches after ctr filter: ${pool.map((w) => w.id).join(", ")}`);
  }
}

db.close();

console.log(`\n${results.length} counters resolved, ${misses.length} need attention.`);

if (misses.length > 0) {
  console.log("\nCounters needing manual resolution:");
  for (const m of misses) {
    if (m.reason === "ambiguous") {
      console.log(`  ${m.kanji} (${m.reading}) [${m.category}] — candidates: ${m.candidates.join(", ")}`);
    } else if (m.reason === "id-collision") {
      console.log(`  ${m.kanji} (${m.reading}) [${m.category}] — ID collision (whatItCounts: "${m.whatItCounts}")`);
    } else {
      console.log(`  ${m.kanji} (${m.reading}) [${m.category}] — no match`);
      if (m.broader?.length > 0) {
        console.log(`    Broader search found: ${m.broader.map((w) => `${w.id} ${w.kanji.map((k) => k.text).join("/")}`).join(", ")}`);
      }
    }
  }
}

  const outPath = path.join(projectRoot, "counters", "counters.json");
  writeFileSync(outPath, JSON.stringify(results, null, 2) + "\n");
