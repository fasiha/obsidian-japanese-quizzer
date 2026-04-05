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

    // Resolve v1 and v2 JMDict IDs. Always attempted — v1/v2 may be in JMDict even
    // when the compound itself is not. If the compound is in JMDict but a component
    // is not, that is unexpected and worth fixing, so fail loudly in that case only.
    let v1JmdictId = null;
    let v2JmdictId = null;

    // vvlexicon sometimes stores multiple kanji spellings for v1/v2 as a
    // comma-separated string (e.g. "擦る,摺る,摩る"). Try each form in turn and
    // use the first hit. If two forms resolve to *different* JMDict IDs, warn —
    // that would mean vvlexicon is treating distinct verbs as spelling variants,
    // which is a data problem worth knowing about. Same ID across forms is normal
    // (alternate spellings of one entry).
    // Strip trailing hiragana (okurigana) from a verb form to get its kanji stem.
    // e.g. "擦る" → "擦", "跳ねる" → "跳ね" ... actually we want just the leading
    // kanji characters: strip from the first hiragana character onward.
    function kanjiStem(form) {
      const match = form.match(/^[\u4e00-\u9fff\u3400-\u4dbf]+/);
      return match ? match[0] : form;
    }

    // vvlexicon sometimes stores multiple kanji spellings for v1/v2 as a
    // comma-separated string (e.g. "擦る,摺る,摩る"). When there are multiple
    // forms, pick the one whose kanji stem matches the start of the compound
    // headword — that is the v1 actually used in this compound. Fall back to
    // first form if none match (shouldn't happen for well-formed vvlexicon data).
    function lookupComponent(field, compoundHeadword) {
      const forms = field.split(",").map((f) => f.trim()).filter(Boolean);
      if (forms.length === 0) return null;

      // Choose canonical form by kanji-stem match against compound headword.
      const canonical = forms.find((f) => compoundHeadword.startsWith(kanjiStem(f)))
        ?? forms[0];

      if (forms.length > 1 && canonical !== forms[0]) {
        console.log(`  info: "${field}" in "${compoundHeadword}" — using "${canonical}" (stem matches compound start)`);
      } else if (forms.length > 1) {
        // First form chosen either by match or fallback — no extra noise unless
        // another form also matched, which would be genuinely ambiguous.
        const otherMatch = forms.slice(1).find((f) => compoundHeadword.startsWith(kanjiStem(f)));
        if (otherMatch) {
          console.warn(`  warning: "${field}" in "${compoundHeadword}" — both "${canonical}" and "${otherMatch}" match compound start; using first`);
        }
      }

      const exact = findExact(db, canonical);
      const componentHit = exact.length > 0 ? exact[0] : kanjiAnywhere(db, canonical)[0] ?? null;
      return componentHit ? componentHit.id : null;
    }

    v1JmdictId = lookupComponent(entry.v1, entry.headword1);
    if (v1JmdictId === null) {
      // Some vvlexicon v1s are genuinely absent from JMDict (archaic, colloquial,
      // or kana-only verbs not yet entered). Warn but continue in all cases.
      console.warn(`  warning: v1 "${entry.v1}" of "${entry.headword1}" not found in JMDict`);
    }

    v2JmdictId = lookupComponent(entry.v2, entry.headword1);
    if (v2JmdictId === null) {
      console.warn(`  warning: v2 "${entry.v2}" of "${entry.headword1}" not found in JMDict`);
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
      v1JmdictId,
      v2JmdictId,
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
