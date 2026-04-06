/**
 * add-furigana-to-jmdict.mjs
 *
 * One-time migration: adds a `furigana` table to jmdict.sqlite containing
 * all entries from JmdictFurigana.json.
 *
 * Safe to re-run after updating JmdictFurigana.json — uses INSERT OR REPLACE
 * so existing rows are overwritten with fresh data.
 *
 * Prerequisites:
 *   - jmdict.sqlite built (run any script using openJmdictDb() first)
 *   - JmdictFurigana.json in the project root
 *     Download from: https://github.com/Doublevil/JmdictFurigana/releases
 *
 * Usage:
 *   node .claude/scripts/add-furigana-to-jmdict.mjs
 *
 * After running, copy the updated database into the Xcode Resources folder:
 *   cp jmdict.sqlite Pug/Pug/Resources/jmdict.sqlite
 */

import { readFileSync, existsSync } from "fs";
import path from "path";
import { openJmdictDb, projectRoot } from "./shared.mjs";

const FURIGANA_JSON = path.join(projectRoot, "JmdictFurigana.json");

if (!existsSync(FURIGANA_JSON)) {
  console.error(
    `Error: JmdictFurigana.json not found at ${FURIGANA_JSON}\n` +
      "Download from: https://github.com/Doublevil/JmdictFurigana/releases",
  );
  process.exit(1);
}

const db = await openJmdictDb({ checkJournalMode: true });

db.exec(`
  CREATE TABLE IF NOT EXISTS furigana (
    text    TEXT NOT NULL,
    reading TEXT NOT NULL,
    segs    TEXT NOT NULL,
    PRIMARY KEY (text, reading)
  )
`);

console.log(`Reading ${FURIGANA_JSON} …`);
// JmdictFurigana.json is UTF-8 with BOM.
const raw = readFileSync(FURIGANA_JSON, "utf-8").replace(/^\uFEFF/, "");
const entries = JSON.parse(raw);
console.log(`Loaded ${entries.length} entries. Inserting …`);

const insert = db.prepare(
  "INSERT OR REPLACE INTO furigana (text, reading, segs) VALUES (?, ?, ?)",
);

const insertAll = db.transaction((rows) => {
  for (const { text, reading, furigana } of rows) {
    insert.run(text, reading, JSON.stringify(furigana));
  }
});

insertAll(entries);

const finalCount = db.prepare("SELECT COUNT(*) AS n FROM furigana").get().n;
console.log(`Done. furigana table now has ${finalCount} rows.`);

db.pragma("journal_mode = DELETE");
db.close();
