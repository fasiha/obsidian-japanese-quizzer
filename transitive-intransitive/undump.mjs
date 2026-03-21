/**
 * Reads dump.md (which may have hand-edited corrections to drill sentences),
 * parses out the drill data, and reinjects it into transitive-pairs.json.
 *
 * Matching is positional: the Nth header in dump.md corresponds to the Nth
 * pair in transitive-pairs.json that has drills. The headers themselves are
 * ignored (they may use outdated kana/kanji from an older JSON version).
 */

import { readFileSync, writeFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const dumpPath = join(__dirname, "dump.md");
const pairsPath = join(__dirname, "transitive-pairs.json");

const dumpText = readFileSync(dumpPath, "utf-8");
const pairs = JSON.parse(readFileSync(pairsPath, "utf-8"));

// Parse dump.md into sections: split on ## headers
const sections = [];
let current = null;
for (const line of dumpText.split("\n")) {
  if (line.startsWith("## ")) {
    if (current) sections.push(current);
    current = { header: line, lines: [] };
  } else if (current) {
    current.lines.push(line);
  }
}
if (current) sections.push(current);

// Parse each section's drill lines
// Format: <ja_intr> (<en_intr>) — <ja_tran> (<en_tran>)
const drillPattern = /^(.+?)\s*\((.+?)\)\s*—\s*(.+?)\s*\((.+?)\)$/;

const parsedSections = sections.map((sec) => {
  const drills = [];
  for (const line of sec.lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const m = trimmed.match(drillPattern);
    if (!m) {
      console.error(
        `WARNING: could not parse drill line in "${sec.header}": ${trimmed}`,
      );
      continue;
    }
    drills.push({
      intransitive: { en: m[2].trim(), ja: m[1].trim() },
      transitive: { en: m[4].trim(), ja: m[3].trim() },
    });
  }
  return { header: sec.header, drills };
});

// Match positionally to pairs with drills
const pairsWithDrills = pairs.filter((p) => p.drills && !p.ambiguousReason);

if (parsedSections.length !== pairsWithDrills.length) {
  console.error(
    `MISMATCH: dump.md has ${parsedSections.length} sections but JSON has ${pairsWithDrills.length} pairs with drills`,
  );
  process.exit(1);
}

// Sanity check: verify header terms match the JSON pair's kana/kanji
const headerPattern = /^## (.+?) vs (.+?)$/;
let sanityFailures = 0;
for (let i = 0; i < parsedSections.length; i++) {
  const sec = parsedSections[i];
  const pair = pairsWithDrills[i];
  const hm = sec.header.match(headerPattern);
  if (!hm) {
    console.error(`SANITY: could not parse header: ${sec.header}`);
    sanityFailures++;
    continue;
  }
  // Each side may be "kana (kanji)" or just "kana"
  const termPattern = /^(\S+?)(?:\s*\((.*?)\))?$/;
  for (const [headerTerm, side] of [
    [hm[1], "intransitive"],
    [hm[2], "transitive"],
  ]) {
    const tm = headerTerm.match(termPattern);
    if (!tm) {
      console.error(
        `SANITY: could not parse term "${headerTerm}" in "${sec.header}"`,
      );
      sanityFailures++;
      continue;
    }
    const verb = pair[side];
    const accepted = new Set([verb.kana, ...(verb.kanji || [])]);
    for (const term of [tm[1], tm[2]].filter((t) => t && t.length > 0)) {
      if (!accepted.has(term)) {
        console.error(
          `SANITY: header term "${term}" not in ${side} kana/kanji [${[...accepted].join(", ")}] (section ${i}: ${sec.header})`,
        );
        sanityFailures++;
      }
    }
  }
}
if (sanityFailures > 0) {
  console.error(`\n${sanityFailures} sanity failure(s) — not writing output.`);
  process.exit(1);
}

let updated = 0;
for (let i = 0; i < parsedSections.length; i++) {
  const sec = parsedSections[i];
  const pair = pairsWithDrills[i];

  if (sec.drills.length !== pair.drills.length) {
    console.error(
      `WARNING: section ${i} "${sec.header}" has ${sec.drills.length} drills but JSON pair ` +
        `${pair.intransitive.kana}/${pair.transitive.kana} has ${pair.drills.length} drills`,
    );
  }

  // Check if anything actually changed
  const oldJson = JSON.stringify(pair.drills);
  const newJson = JSON.stringify(sec.drills);
  if (oldJson !== newJson) {
    pair.drills = sec.drills;
    updated++;
  }
}

console.log(`Sections: ${parsedSections.length}`);
console.log(`Updated: ${updated}`);

writeFileSync(pairsPath, JSON.stringify(pairs, null, 2) + "\n");
console.log(`Wrote ${pairsPath}`);
