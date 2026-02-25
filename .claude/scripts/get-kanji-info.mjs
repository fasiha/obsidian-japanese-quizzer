/**
 * get-kanji-info.mjs
 * Given one or more kanji, outputs compact info: radicals, on/kun readings, meanings.
 * Intended to be called by Claude when a user asks for kanji mnemonics or breakdown.
 *
 * Data sources:
 *   - kradfile-*.json     : loaded fresh every run (~500 KB, fast)
 *   - kanjidic2.sqlite    : slim DB generated on first run from kanjidic2-en-*.json (15 MB → ~2 MB)
 *
 * Both source files are expected in the project root. kanjidic2.sqlite is cached there too.
 *
 * Usage: node .claude/scripts/get-kanji-info.mjs 怒 鳴
 *        node .claude/scripts/get-kanji-info.mjs 怒鳴る   (non-kanji characters are skipped)
 */

import Database from 'better-sqlite3';
import { readFileSync, existsSync, readdirSync } from 'fs';
import path from 'path';
import { projectRoot } from './shared.mjs';

const KANJIDIC_SQLITE = path.join(projectRoot, 'kanjidic2.sqlite');

// --- kradfile: load fresh (small enough) ---
function loadKradfile() {
  const files = readdirSync(projectRoot).filter(f => f.startsWith('kradfile') && f.endsWith('.json'));
  if (files.length === 0) throw new Error('No kradfile-*.json found in project root. Download from jmdict-simplified releases.');
  const data = JSON.parse(readFileSync(path.join(projectRoot, files[0]), 'utf8'));
  return data.kanji; // { [kanji: string]: string[] }
}

// --- kanjidic2 SQLite: build from source JSON on first run ---
function ensureKanjidicSqlite() {
  if (existsSync(KANJIDIC_SQLITE)) return;

  const files = readdirSync(projectRoot).filter(f => f.startsWith('kanjidic2') && f.endsWith('.json'));
  if (files.length === 0) {
    throw new Error(
      'kanjidic2.sqlite not found and no kanjidic2-en-*.json source found.\n' +
      'Download from https://github.com/scriptin/jmdict-simplified/releases and place in project root.'
    );
  }

  process.stderr.write(`Building kanjidic2.sqlite from ${files[0]} (one-time setup)...\n`);
  const source = JSON.parse(readFileSync(path.join(projectRoot, files[0]), 'utf8'));

  const db = new Database(KANJIDIC_SQLITE);
  db.exec(`
    CREATE TABLE kanji (
      literal      TEXT PRIMARY KEY,
      strokes      INTEGER,
      grade        INTEGER,
      jlpt         INTEGER,  -- old JLPT scale: 4=N5, 3=N4, 2=N3, 1=N2
      on_readings  TEXT,     -- JSON array
      kun_readings TEXT,     -- JSON array
      meanings     TEXT      -- JSON array (English only)
    )
  `);

  const insert = db.prepare('INSERT INTO kanji VALUES (?,?,?,?,?,?,?)');
  const insertAll = db.transaction(chars => {
    for (const c of chars) {
      const on = [], kun = [], meanings = [];
      for (const g of c.readingMeaning?.groups ?? []) {
        for (const r of g.readings) {
          if (r.type === 'ja_on') on.push(r.value);
          if (r.type === 'ja_kun') kun.push(r.value);
        }
        for (const m of g.meanings) {
          if (m.lang === 'en') meanings.push(m.value);
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
      );
    }
  });

  insertAll(source.characters);
  db.close();
  process.stderr.write(`Done. kanjidic2.sqlite created (${source.characters.length} entries). You may delete ${files[0]}.\n`);
}

// --- Main ---

// Accept args like "怒 鳴" or "怒鳴る" — extract only kanji characters
const isKanji = ch => /[\u4E00-\u9FFF\u3400-\u4DBF\uF900-\uFAFF]/.test(ch);
const kanjis = process.argv.slice(2)
  .flatMap(arg => [...arg])
  .filter(isKanji)
  .filter((k, i, a) => a.indexOf(k) === i); // deduplicate

if (kanjis.length === 0) {
  console.error('Usage: node .claude/scripts/get-kanji-info.mjs <kanji> [...]');
  console.error('Example: node .claude/scripts/get-kanji-info.mjs 怒 鳴');
  process.exit(1);
}

const kradMap = loadKradfile();
ensureKanjidicSqlite();
const db = new Database(KANJIDIC_SQLITE, { readonly: true });
const query = db.prepare('SELECT * FROM kanji WHERE literal = ?');
const radicalMeaningQuery = db.prepare('SELECT meanings FROM kanji WHERE literal = ?');

function radicalLabel(r) {
  const row = radicalMeaningQuery.get(r);
  if (!row) return r;
  const meanings = JSON.parse(row.meanings);
  return meanings.length ? `${r} (${meanings[0]})` : r;
}

// jlptLevel in kanjidic2: 4=N5, 3=N4, 2=N3, 1=N2
function jlptStr(level) {
  if (!level) return '—';
  return `N${level + 1}`;
}

for (const k of kanjis) {
  const row = query.get(k);
  const radicals = kradMap[k] ?? [];

  if (!row) {
    console.log(`${k}: not in kanjidic2`);
    console.log(`  Radicals: ${radicals.map(radicalLabel).join('、') || '(none)'}`);
    continue;
  }

  const on = JSON.parse(row.on_readings);
  const kun = JSON.parse(row.kun_readings);
  const meanings = JSON.parse(row.meanings);

  console.log(`${k}:`);
  console.log(`  Radicals: ${radicals.map(radicalLabel).join('、') || '(none)'}`);
  if (on.length)       console.log(`  On:       ${on.join('、')}`);
  if (kun.length)      console.log(`  Kun:      ${kun.join('、')}`);
  if (meanings.length) console.log(`  Meanings: ${meanings.join(', ')}`);
  console.log(`  Strokes: ${row.strokes ?? '?'}  JLPT: ${jlptStr(row.jlpt)}  Grade: ${row.grade ? `G${row.grade}` : '—'}`);
}

db.close();
