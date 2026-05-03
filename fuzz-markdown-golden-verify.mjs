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

const VOCAB_JSON = "/Users/ahmed.fasih/Downloads/pug-files/vocab.json";
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
const sampleMisses = [];

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

      // These two should be equal — sanity check on vocab.json's internal consistency.
      if (derivedKey !== computedFromKey) {
        mismatchedComputedFrom++;
        if (sampleMisses.length < 3) {
          sampleMisses.push({
            kind: "internal-inconsistency",
            wordId: w.id,
            source,
            line: ref.line,
            derived: derivedKey.slice(0, 200),
            stored: computedFromKey.slice(0, 200),
          });
        }
      }

      if (!goldenKeys) {
        unknownSource++;
        if (sampleMisses.length < 3) {
          sampleMisses.push({ kind: "unknown-source", wordId: w.id, source, line: ref.line });
        }
        continue;
      }

      // 3. The key (as captured by the golden harness) should appear in the golden.
      if (goldenKeys.has(derivedKey)) {
        matched++;
      } else {
        missingFromGolden++;
        if (sampleMisses.length < 6) {
          sampleMisses.push({
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

console.log(`refs with llm_sense:           ${totalRefsWithLlm}`);
console.log(`  matched in golden:           ${matched}`);
console.log(`  missing from golden:         ${missingFromGolden}`);
console.log(`  source not in golden:        ${unknownSource}`);
console.log(`  vocab.json self-inconsistent: ${mismatchedComputedFrom}`);
if (sampleMisses.length) {
  console.log(`\nsample issues:`);
  for (const s of sampleMisses) console.log("  " + JSON.stringify(s));
}

const ok = missingFromGolden === 0 && unknownSource === 0;
process.exit(ok ? 0 : 1);
