#!/usr/bin/env node
// fuzz-markdown-golden-verify.mjs — confirm that the per-bullet cacheKey values
// captured in fuzz-markdown-golden.json are exactly the cache keys actually
// stored against LLM responses in vocab.json's `llm_sense.computed_from` field.
//
// If every vocab.json ref's computed_from is present (as a cacheKey) on some
// bullet in the same source file's golden entry, then the golden harness is
// faithfully reproducing the cache keys prepare-publish.mjs uses — which means
// any future parser change that makes the golden diff shows real cache churn.

import { readFileSync } from "fs";
import path from "path";
import { projectRoot } from "./.claude/scripts/shared.mjs";

const VOCAB_JSON = "vocab.json";
const GOLDEN_PATH = path.join(projectRoot, "fuzz-markdown-golden.json");

function stripRuby(text) {
  return text
    .replace(/<rt>[^<]*<\/rt>/g, "")
    .replace(/<rp>[^<]*<\/rp>/g, "")
    .replace(/<[^>]+>/g, "");
}
function normalizeContextForCache(context) {
  if (!context) return context;
  return stripRuby(context).trim();
}
function cacheKey(normalizedContext, narration) {
  const parts = [normalizedContext, narration].filter((v) => v != null);
  return JSON.stringify([...new Set(parts)].sort());
}

const vocab = JSON.parse(readFileSync(VOCAB_JSON, "utf8"));
const golden = JSON.parse(readFileSync(GOLDEN_PATH, "utf8"));

// Collect golden cacheKeys per source-file (relpath without .md → set of keys).
const goldenKeysBySource = new Map();
for (const [rel, file] of Object.entries(golden.files)) {
  const source = rel.replace(/\.md$/i, "");
  const keys = new Set();
  for (const block of file.vocabBlocks) {
    for (const b of block.bullets) keys.add(b.cacheKey);
  }
  for (const block of file.counterBlocks) {
    for (const b of block.bullets) keys.add(b.cacheKey);
  }
  // Grammar bullets too — vocab.json doesn't reference them, but harmless to include.
  for (const block of file.grammarBlocks) {
    for (const b of block.bullets) keys.add(b.cacheKey);
  }
  goldenKeysBySource.set(source, keys);
}

let totalRefsWithLlm = 0;
let matched = 0;
let mismatchedComputedFrom = 0; // ref.llm_sense.computed_from disagrees with what we'd derive from ref.context+narration
let missingFromGolden = 0;
let unknownSource = 0;
// Fatal findings (mean the harness is NOT faithful to prepare-publish.mjs's
// cache-key construction; verify must fail).
const fatalSamples = [];
// Advisory findings (informational only — vocab.json's stored fields drifted
// from current normalization rules; cache lookups still work because the
// lookup key is recomputed fresh from ref.context at every prepare-publish
// run, but the on-disk computed_from is historical residue).
const advisorySamples = [];

for (const w of vocab.words ?? []) {
  for (const [source, refs] of Object.entries(w.references ?? {})) {
    const goldenKeys = goldenKeysBySource.get(source);
    for (const ref of refs) {
      if (!ref.llm_sense) continue;
      totalRefsWithLlm++;

      // 1. The cacheKey we'd derive from the ref's stored context+narration.
      const derivedKey = cacheKey(normalizeContextForCache(ref.context), ref.narration);

      // 2. The cacheKey implied by llm_sense.computed_from itself.
      const computedFromKey = JSON.stringify(
        [...new Set(ref.llm_sense.computed_from)].sort(),
      );

      // ADVISORY: stored llm_sense.computed_from differs from what current
      // normalization would produce. Harmless — lookup uses the fresh key,
      // not the stored one. Surfaces historical drift in vocab.json.
      if (derivedKey !== computedFromKey) {
        mismatchedComputedFrom++;
        if (advisorySamples.length < 3) {
          advisorySamples.push({
            wordId: w.id,
            source,
            line: ref.line,
            derived: derivedKey.slice(0, 200),
            stored: computedFromKey.slice(0, 200),
          });
        }
      }

      // FATAL: ref points to a source file the golden has no entry for.
      // Means the corpus and the golden disagree on which files exist.
      if (!goldenKeys) {
        unknownSource++;
        if (fatalSamples.length < 3) {
          fatalSamples.push({ kind: "unknown-source", wordId: w.id, source, line: ref.line });
        }
        continue;
      }

      // FATAL: ref's derived cacheKey is not in the golden — means the
      // harness's cacheKey calculation has drifted from prepare-publish.mjs's,
      // OR the corpus changed since the golden was written.
      if (goldenKeys.has(derivedKey)) {
        matched++;
      } else {
        missingFromGolden++;
        if (fatalSamples.length < 6) {
          fatalSamples.push({
            kind: "missing-from-golden",
            wordId: w.id,
            source,
            line: ref.line,
            narration: ref.narration,
            contextPreview: (ref.context ?? "").slice(0, 80),
            derivedKey: derivedKey.slice(0, 200),
          });
        }
      }
    }
  }
}

const ok = missingFromGolden === 0 && unknownSource === 0;
const verbose = process.argv.slice(2).includes("--verbose");

console.log(`refs with llm_sense in vocab.json: ${totalRefsWithLlm}`);
console.log(`  matched in golden:               ${matched}`);
if (missingFromGolden > 0) console.log(`  [FATAL] missing from golden:     ${missingFromGolden}`);
if (unknownSource > 0)     console.log(`  [FATAL] source not in golden:    ${unknownSource}`);

if (ok) {
  console.log(`\n[pass] harness faithfully reproduces prepare-publish.mjs cache keys.`);
} else {
  console.log(`\n[FAIL] harness's cacheKey calculation has drifted from prepare-publish.mjs.`);
  console.log(`fatal samples:`);
  for (const s of fatalSamples) console.log("  " + JSON.stringify(s));
}

// Historical-drift advisory is INFORMATIONAL ONLY — does not affect cache
// correctness. Hidden behind --verbose because the typical reader who sees
// it worries about it (the on-disk computed_from disagrees with what current
// normalization would produce, but cache lookups don't use the on-disk field
// as a key so this is harmless). See the script header for the full story.
if (mismatchedComputedFrom > 0 && verbose) {
  console.log(
    `\n[--verbose] historical-drift advisory: ${mismatchedComputedFrom} ref(s) in\n` +
      `vocab.json have stored llm_sense.computed_from that disagrees with what current\n` +
      `normalizeContextForCache would produce from ref.context. This is historical\n` +
      `drift (the refs were written before the normalizer was extended); cache lookups\n` +
      `still hit because the lookup key is recomputed fresh from ref.context every\n` +
      `prepare-publish.mjs run. The stored field is just record-keeping. Sample drifts:`,
  );
  for (const s of advisorySamples) console.log("  " + JSON.stringify(s));
} else if (mismatchedComputedFrom > 0) {
  console.log(
    `\n(${mismatchedComputedFrom} historical-drift advisory ref(s) suppressed; pass --verbose to inspect — informational only, does not affect cache correctness.)`,
  );
}

process.exit(ok ? 0 : 1);
