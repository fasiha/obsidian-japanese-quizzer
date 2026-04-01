/**
 * build-jmdict-sidecar.mjs
 *
 * Builds jmdict-sidecar.json for the Obsidian vocab-definitions plugin.
 *
 * Scans all llm-review Markdown files, collects every vocab bullet, resolves
 * each bullet to a JMDict entry (same logic as prepare-publish.mjs), and
 * writes a compact sidecar JSON keyed by raw bullet text.
 *
 * Output: jmdict-sidecar.json at project root (same directory as the Markdown
 * files, so the Obsidian plugin can find it by walking up from any note).
 *
 * Usage: node build-jmdict-sidecar.mjs
 */

import { setup, findExactIds, idsToWords } from "jmdict-simplified-node";
import { readFileSync, writeFileSync } from "fs";
import path from "path";
import Database from "better-sqlite3";
import {
  findMdFiles,
  extractJapaneseTokens,
  intersectSets,
  parseFrontmatter,
  projectRoot,
  JMDICT_DB,
  extractVocabBullets,
} from "./.claude/scripts/shared.mjs";

const { db } = await setup(JMDICT_DB);

// Load tag map from jmdict metadata so the plugin can expand tag codes like
// "adv" → "adverb (fukushi)" without hardcoding anything.
const rawTags = new Database(JMDICT_DB)
  .prepare("select value_json from metadata where key='tags'")
  .pluck()
  .get();
const tags = JSON.parse(rawTags);

const mdFiles = findMdFiles(projectRoot);

// Map from bullet text → full JMDict word object
const entries = {};
let warnings = 0;

for (const filePath of mdFiles) {
  const content = readFileSync(filePath, "utf8");
  const fm = parseFrontmatter(content);
  if (!fm?.["llm-review"]) continue;

  const relPath = path.relative(projectRoot, filePath);

  for (const bullet of extractVocabBullets(content)) {
    if (bullet in entries) continue; // already resolved

    const directIdMatch = bullet.match(/^\d+/);
    if (directIdMatch) {
      const [word] = idsToWords(db, [directIdMatch[0]]);
      entries[bullet] = word;
      continue;
    }
    
    const tokens = extractJapaneseTokens(bullet);
    if (tokens.length === 0) continue;

    const idSets = tokens.map((token) => new Set(findExactIds(db, token)));
    const matchIds = [...intersectSets(idSets)];

    if (matchIds.length !== 1) {
      console.warn(
        `${relPath}: bullet "${bullet}" matched ${matchIds.length} JMDict entries (skipping)`,
      );
      warnings++;
      continue;
    }

    const [word] = idsToWords(db, matchIds);
    entries[bullet] = word;
  }
}

const output = {
  generatedAt: new Date().toISOString(),
  tags,
  entries,
};

const outPath = path.join(projectRoot, "jmdict-sidecar.json");
writeFileSync(outPath, JSON.stringify(output, null, 2) + "\n");

const count = Object.keys(entries).length;
console.log(`Wrote ${count} entries → ${outPath}`);
if (warnings > 0) console.warn(`${warnings} bullet(s) skipped (see above)`);
