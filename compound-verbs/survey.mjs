/**
 * compound-verbs/survey.mjs
 *
 * For each requested v2 suffix, produces a JSON file in compound-verbs/survey/
 * containing all NINJAL VV Lexicon entries for that suffix, enriched with the
 * matching JMDict entry ID from jmdict.sqlite.
 *
 * Usage:
 *   node compound-verbs/survey.mjs 返す 立てる
 *   node compound-verbs/survey.mjs --all        (all 470 unique v2s)
 *
 * Output: compound-verbs/survey/<v2>.json for each requested v2.
 * Each file is an array of enriched headword objects, sorted by NLB headword_id
 * (a stable ordering; NLB frequency sort happens after nlb-fetch.mjs runs).
 */

import { readFileSync, writeFileSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { setup, findExact, kanjiAnywhere } from "jmdict-simplified-node";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, "..");

const headwords = JSON.parse(
  readFileSync(join(__dirname, "headwords.json"), "utf8")
);

const args = process.argv.slice(2);
if (args.length === 0) {
  console.error(
    "Usage: node compound-verbs/survey.mjs <v2> [<v2> ...] | --all"
  );
  process.exit(1);
}

let targetV2s;
if (args[0] === "--all") {
  targetV2s = [...new Set(headwords.map((e) => e.v2).filter(Boolean))];
  console.log(`Processing all ${targetV2s.length} unique v2s`);
} else {
  targetV2s = args;
}

const { db } = await setup(join(root, "jmdict.sqlite"));

const surveyDir = join(__dirname, "survey");
mkdirSync(surveyDir, { recursive: true });

for (const v2 of targetV2s) {
  const entries = headwords.filter((e) => e.v2 === v2);
  if (entries.length === 0) {
    console.warn(`No NINJAL entries found for v2="${v2}", skipping`);
    continue;
  }

  const enriched = entries.map((entry) => {
    // Try exact match on the full compound kanji form first, then fall back to
    // substring search. Take the first result — misses are flagged explicitly.
    let jmdictId = null;
    let jmdictForms = null;
    let jmdictMeanings = null;

    const exact = findExact(db, entry.headword1);
    const hit = exact.length > 0 ? exact[0] : kanjiAnywhere(db, entry.headword1)[0] ?? null;
    if (hit) {
      jmdictId = hit.id;
      jmdictForms = hit.kanji?.map((k) => k.text) ?? [];
      // Array of arrays: each inner array is one JMDict sense (one or more glosses).
      // Preserves the sense boundary so the LLM can see which glosses group together.
      jmdictMeanings = (hit.sense ?? [])
        .map((s) => s.gloss?.map((g) => g.text) ?? [])
        .filter((glosses) => glosses.length > 0);
    }

    return {
      headword_id: entry.headword_id,
      headword: entry.headword1,
      reading: entry.reading,
      v1: entry.v1,
      v1_reading: entry.v1_reading,
      v2: entry.v2,
      v2_reading: entry.v2_reading,
      jita: entry.jita,
      NLB_link: entry.NLB_link,
      jmdictId,
      jmdictForms,
      jmdictMeanings,
      ninjal_senses: entry.senses.map((s) => ({
        definition_en: s.definition_en,
        example_en: s.examples?.[0]?.example_en ?? null,
        example_ja: s.examples?.[0]?.example ?? null,
      })),
    };
  });

  const misses = enriched.filter((e) => e.jmdictId === null);
  if (misses.length > 0) {
    console.warn(
      `  ${v2}: ${misses.length} JMDict misses: ${misses.map((e) => e.headword).join(", ")}`
    );
  }

  const outPath = join(surveyDir, `${v2}.json`);
  writeFileSync(outPath, JSON.stringify(enriched, null, 2), "utf8");
  console.log(`  ${v2}: ${enriched.length} entries → ${outPath} (${misses.length} JMDict misses)`);
}

db.close();
