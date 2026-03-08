/**
 * get-kanji-info.mjs
 * Given one or more kanji, outputs compact info: radicals, on/kun readings, meanings.
 * Intended to be called by Claude when a user asks for kanji mnemonics or breakdown.
 *
 * Data sources:
 *   - kanjidic2.sqlite : built on first run from kanjidic2-en-*.json + kradfile-*.json
 *                        All data (including radicals) lives in the DB after first build.
 *   - wanikani/wanikani-kanji-graph.json : kanji → informal component breakdown
 *   - wanikani/wanikani-extra-radicals.json : descriptions for components not in kanjidic2
 *
 * Usage: node .claude/scripts/get-kanji-info.mjs 怒 鳴
 *        node .claude/scripts/get-kanji-info.mjs 怒鳴る   (non-kanji characters are skipped)
 */

import Database from "better-sqlite3";
import { readFileSync, existsSync, readdirSync } from "fs";
import path from "path";
import { projectRoot } from "./shared.mjs";

const KANJIDIC_SQLITE = path.join(projectRoot, "kanjidic2.sqlite");
const WANIKANI_GRAPH = path.join(projectRoot, "wanikani", "wanikani-kanji-graph.json");
const WANIKANI_EXTRA = path.join(projectRoot, "wanikani", "wanikani-extra-radicals.json");

function loadWanikaniData() {
  let kanjiToRadicals = {};
  let extraRadicals = {};
  if (existsSync(WANIKANI_GRAPH)) {
    kanjiToRadicals = JSON.parse(readFileSync(WANIKANI_GRAPH, "utf8")).kanjiToRadicals;
  }
  if (existsSync(WANIKANI_EXTRA)) {
    extraRadicals = JSON.parse(readFileSync(WANIKANI_EXTRA, "utf8"));
  }
  return { kanjiToRadicals, extraRadicals };
}

function findKradfile() {
  const files = readdirSync(projectRoot).filter(
    (f) => f.startsWith("kradfile") && f.endsWith(".json"),
  );
  return files.length ? path.join(projectRoot, files[0]) : null;
}

function loadKradMap(kradfilePath) {
  if (!kradfilePath) return {};
  return JSON.parse(readFileSync(kradfilePath, "utf8")).kanji; // { [kanji]: string[] }
}

// --- kanjidic2 SQLite: build from source JSON on first run ---
function ensureKanjidicSqlite() {
  if (existsSync(KANJIDIC_SQLITE)) return;

  const files = readdirSync(projectRoot).filter(
    (f) => f.startsWith("kanjidic2") && f.endsWith(".json"),
  );
  if (files.length === 0) {
    throw new Error(
      "kanjidic2.sqlite not found and no kanjidic2-en-*.json source found.\n" +
        "Download from https://github.com/scriptin/jmdict-simplified/releases and place in project root.",
    );
  }

  process.stderr.write(
    `Building kanjidic2.sqlite from ${files[0]} (one-time setup)...\n`,
  );
  const source = JSON.parse(
    readFileSync(path.join(projectRoot, files[0]), "utf8"),
  );
  const kradfilePath = findKradfile();
  if (!kradfilePath)
    throw new Error(
      "No kradfile-*.json found in project root. Download from jmdict-simplified releases.",
    );
  const kradMap = loadKradMap(kradfilePath);

  const db = new Database(KANJIDIC_SQLITE);
  db.exec(`
    CREATE TABLE kanji (
      literal      TEXT PRIMARY KEY,
      strokes      INTEGER,
      grade        INTEGER,
      jlpt         INTEGER,  -- old JLPT scale: 4=N5, 3=N4, 2=N3, 1=N2
      on_readings  TEXT,     -- JSON array
      kun_readings TEXT,     -- JSON array
      meanings     TEXT,     -- JSON array (English only)
      radicals     TEXT      -- JSON array of radical characters (from kradfile)
    )
  `);

  const insert = db.prepare("INSERT INTO kanji VALUES (?,?,?,?,?,?,?,?)");
  const insertAll = db.transaction((chars) => {
    for (const c of chars) {
      const on = [], kun = [], meanings = [];
      for (const g of c.readingMeaning?.groups ?? []) {
        for (const r of g.readings) {
          if (r.type === "ja_on") on.push(r.value);
          if (r.type === "ja_kun") kun.push(r.value);
        }
        for (const m of g.meanings) {
          if (m.lang === "en") meanings.push(m.value);
        }
      }
      insert.run(
        c.literal,
        c.misc?.strokeCounts?.[0] ?? null,
        c.misc?.grade ?? null,
        c.misc?.jlptLevel ?? null,
        JSON.stringify(on),
        JSON.stringify(kun),
        JSON.stringify(meanings),
        JSON.stringify(kradMap[c.literal] ?? []),
      );
    }
  });

  insertAll(source.characters);
  db.pragma("journal_mode = DELETE");
  db.close();
  process.stderr.write(
    `Done. kanjidic2.sqlite created (${source.characters.length} entries). You may delete ${files[0]}.\n`,
  );
}

// --- Migration: add radicals column to existing DB if missing ---
function ensureRadicalsColumn(db) {
  const cols = db.pragma("table_info(kanji)").map((r) => r.name);
  if (cols.includes("radicals")) return;

  process.stderr.write(
    "Migrating kanjidic2.sqlite: adding radicals column...\n",
  );
  db.exec("ALTER TABLE kanji ADD COLUMN radicals TEXT");

  const kradfilePath = findKradfile();
  if (!kradfilePath) {
    process.stderr.write(
      "Warning: No kradfile-*.json found; radicals column left empty.\n",
    );
    return;
  }
  const kradMap = loadKradMap(kradfilePath);
  const update = db.prepare("UPDATE kanji SET radicals = ? WHERE literal = ?");
  db.transaction((map) => {
    for (const [literal, rads] of Object.entries(map)) {
      update.run(JSON.stringify(rads), literal);
    }
  })(kradMap);
  db.pragma("journal_mode = DELETE");
  process.stderr.write("Done. Radicals backfilled from kradfile.\n");
}

// --- Main ---

// Accept args like "怒 鳴" or "怒鳴る" — extract only kanji characters
const isKanji = (ch) => /[\u4E00-\u9FFF\u3400-\u4DBF\uF900-\uFAFF]/.test(ch);
const kanjis = process.argv
  .slice(2)
  .flatMap((arg) => [...arg])
  .filter(isKanji)
  .filter((k, i, a) => a.indexOf(k) === i); // deduplicate

if (kanjis.length === 0) {
  console.error("Usage: node .claude/scripts/get-kanji-info.mjs <kanji> [...]");
  console.error("Example: node .claude/scripts/get-kanji-info.mjs 怒 鳴");
  process.exit(1);
}

ensureKanjidicSqlite();
// Open read-write only for the migration check, then switch to readonly.
// Also ensures DELETE journal mode so the file is ready to copy into the iOS bundle.
{
  const dbRw = new Database(KANJIDIC_SQLITE);
  ensureRadicalsColumn(dbRw);
  if (dbRw.pragma("journal_mode", { simple: true }) === "wal") {
    dbRw.pragma("journal_mode = DELETE");
  }
  dbRw.close();
}
const db = new Database(KANJIDIC_SQLITE, { readonly: true });
const query = db.prepare("SELECT * FROM kanji WHERE literal = ?");
const radicalMeaningQuery = db.prepare(
  "SELECT meanings FROM kanji WHERE literal = ?",
);

function radicalLabel(r) {
  const row = radicalMeaningQuery.get(r);
  if (!row) return r;
  const meanings = JSON.parse(row.meanings);
  return meanings.length ? `${r} (${meanings[0]})` : r;
}

// jlptLevel in kanjidic2: 4=N5, 3=N4, 2=N3, 1=N2
function jlptStr(level) {
  if (!level) return "—";
  return `N${level + 1}`;
}

const { kanjiToRadicals: wkGraph, extraRadicals: wkExtra } = loadWanikaniData();

function wkRadicalLabel(r) {
  // Try kanjidic2 first for meaning
  const row = radicalMeaningQuery.get(r);
  if (row) {
    const meanings = JSON.parse(row.meanings);
    return meanings.length ? `${r} (${meanings[0]})` : r;
  }
  // Fall back to wanikani extra radicals
  if (r in wkExtra) return `${r} — ${wkExtra[r]}`;
  return r;
}

for (const k of kanjis) {
  const row = query.get(k);
  const radicals = row ? JSON.parse(row.radicals ?? "[]") : [];
  const wkComponents = wkGraph[k];

  console.log(`- ${k}`);

  // --- Kanjidic section ---
  console.log("  - Kanjidic");
  if (!row) {
    console.log("    - (not in kanjidic2)");
  } else {
    const on = JSON.parse(row.on_readings);
    const kun = JSON.parse(row.kun_readings);
    const meanings = JSON.parse(row.meanings);

    console.log(`    - Radicals: ${radicals.map(radicalLabel).join("、") || "(none)"}`);
    if (on.length) console.log(`    - On: ${on.join("、")}`);
    if (kun.length) console.log(`    - Kun: ${kun.join("、")}`);
    if (meanings.length) console.log(`    - Meanings: ${meanings.join(", ")}`);
    console.log(`    - Strokes: ${row.strokes ?? "?"}  JLPT: ${jlptStr(row.jlpt)}  Grade: ${row.grade ? `G${row.grade}` : "—"}`);
  }

  // --- Wanikani section ---
  if (wkComponents) {
    console.log("  - Wanikani components");
    for (const c of wkComponents) {
      console.log(`    - ${wkRadicalLabel(c)}`);
    }
  }
}

db.close();
