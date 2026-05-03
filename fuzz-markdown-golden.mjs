#!/usr/bin/env node
// fuzz-markdown-golden.mjs — golden-output regression harness for the Markdown
// parsers in shared.mjs. For every .md file in the corpus, captures the exact
// output of extractDetailsBlocks / extractContextBefore / extractVocabBullets /
// extractGrammarBullets / extractCounterBullets, plus the per-bullet cache key
// that prepare-publish.mjs uses to look up cached LLM sense analyses.
//
// Purpose: when the parsers in shared.mjs / markdown-ast.mjs are changed, this
// harness diffs the new output against the local golden so we can:
//   1. confirm bullet extraction is unchanged (no silent data loss / churn);
//   2. confirm cache keys are unchanged (no spurious LLM re-runs / token burn).
//
// Workflow:
//   # First time on this machine (or after intentional parser changes):
//   node fuzz-markdown-golden.mjs --write    # capture current parser output
//                                            # into fuzz-markdown-golden.json
//
//   # Before / after a parser change you want to verify is non-disruptive:
//   node fuzz-markdown-golden.mjs            # compare; exit 1 on any diff,
//                                            # printing per-file bullet-level
//                                            # diffs and cache-key churn count
//
// Use fuzz-markdown-golden-verify.mjs after --write to confirm the captured
// cache keys still match the keys that prepare-publish.mjs writes into your
// vocab.json (sanity check on the harness itself).
//
// The golden file (fuzz-markdown-golden.json) is gitignored because it is
// derived from the user's personal / copyrighted .md content. Each contributor
// regenerates it locally via --write; the diff between two locally-generated
// goldens for the same parser code is empty, so the regression check is
// reproducible without sharing the file. See .gitignore.

import { readFileSync, writeFileSync, existsSync } from "fs";
import path from "path";
import { fileURLToPath } from "url";
import {
  findMdFiles,
  extractDetailsBlocks,
  extractContextBefore,
  extractGrammarBullets,
  isJapanese,
  projectRoot,
} from "./.claude/scripts/shared.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const GOLDEN_PATH = path.join(projectRoot, "fuzz-markdown-golden.json");
const GOLDEN_VERSION = 1;

// Mirror prepare-publish.mjs exactly so the cache keys we capture here match
// the ones used at LLM-cache lookup time. If prepare-publish's normalization
// changes, update this to match.
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

// Compute the 1-indexed line number of the character at offset `idx` in `content`.
function lineAtOffset(content, idx) {
  return content.slice(0, idx).split("\n").length;
}

// Per-bullet narration (the non-Japanese text trailing the leading Japanese
// tokens). Mirrors the loop in prepare-publish.mjs's extractVocabBullets.
function bulletNarration(bullet) {
  const parts = bullet.split(/\s+/);
  let j = 0;
  if (/^\d+$/.test(parts[0])) j = 1; // skip bare JMDict ID prefix
  while (j < parts.length && parts[j] && isJapanese(parts[j])) j++;
  return parts.slice(j).join(" ").trim() || null;
}

function captureFile(absPath) {
  const content = readFileSync(absPath, "utf8");
  const vocabBlocks = [];
  const counterBlocks = [];

  for (const { stripped, fileOffset, blockLine, innerStartLine } of extractDetailsBlocks(content, "Vocab")) {
    const { text: context, line: contextLine } = extractContextBefore(content, fileOffset);
    const normalizedContext = normalizeContextForCache(context);

    const vocabBullets = [];
    const counterBullets = [];
    const innerLines = stripped.split("\n");
    let depth = 0;

    for (let i = 0; i < innerLines.length; i++) {
      const lineStr = innerLines[i];
      if (depth === 0) {
        const trimmed = lineStr.trim();
        if (trimmed.startsWith("-")) {
          const bullet = trimmed.slice(1).trim();
          if (bullet) {
            const line = innerStartLine + i;
            if (bullet.startsWith("counter:")) {
              const counterId = bullet.slice("counter:".length).trim();
              if (counterId) {
                counterBullets.push({
                  line,
                  counterId,
                  cacheKey: cacheKey(normalizedContext, null),
                });
              }
            } else {
              const narration = bulletNarration(bullet);
              vocabBullets.push({
                line,
                bullet,
                narration,
                cacheKey: cacheKey(normalizedContext, narration),
              });
            }
          }
        }
      }
      const opens = (lineStr.match(/<details\b/gi) || []).length;
      const closes = (lineStr.match(/<\/details\b/gi) || []).length;
      depth += opens - closes;
      if (depth < 0) depth = 0;
    }

    if (vocabBullets.length > 0) {
      vocabBlocks.push({
        blockLine,
        context,
        contextLine,
        normalizedContext,
        bullets: vocabBullets,
      });
    }
    if (counterBullets.length > 0) {
      counterBlocks.push({
        blockLine,
        context,
        contextLine,
        normalizedContext,
        bullets: counterBullets,
      });
    }
  }

  // Grammar bullets: extractGrammarBullets already returns (topicId, note, line, matchIndex).
  // Group them by their parent <details> block (matchIndex) so the structure mirrors vocab.
  const grammarBlocksByMatchIdx = new Map();
  for (const { topicId, note, line, matchIndex } of extractGrammarBullets(content)) {
    if (!grammarBlocksByMatchIdx.has(matchIndex)) {
      const { text: context, line: contextLine } = extractContextBefore(content, matchIndex);
      grammarBlocksByMatchIdx.set(matchIndex, {
        blockLine: lineAtOffset(content, matchIndex),
        context,
        contextLine,
        normalizedContext: normalizeContextForCache(context),
        bullets: [],
      });
    }
    const block = grammarBlocksByMatchIdx.get(matchIndex);
    block.bullets.push({
      line,
      topicId,
      note: note || null,
      cacheKey: cacheKey(block.normalizedContext, note || null),
    });
  }
  const grammarBlocks = [...grammarBlocksByMatchIdx.values()].sort(
    (a, b) => a.blockLine - b.blockLine,
  );

  if (vocabBlocks.length === 0 && grammarBlocks.length === 0 && counterBlocks.length === 0) {
    return null;
  }
  return { vocabBlocks, grammarBlocks, counterBlocks };
}

function buildSnapshot() {
  const mdFiles = findMdFiles(projectRoot).sort();
  const files = {};
  for (const abs of mdFiles) {
    const rel = path.relative(projectRoot, abs);
    const captured = captureFile(abs);
    if (captured) files[rel] = captured;
  }
  return { version: GOLDEN_VERSION, files };
}

// ── diff helpers ─────────────────────────────────────────────────────────────

function diffFile(rel, oldFile, newFile) {
  // Returns { vocab: { added, removed, changed }, grammar: {...}, counter: {...} }
  // where `changed` items include the first old/new pair for inspection.
  const result = {};
  for (const kind of ["vocabBlocks", "grammarBlocks", "counterBlocks"]) {
    const oldBlocks = oldFile?.[kind] ?? [];
    const newBlocks = newFile?.[kind] ?? [];
    const oldStr = JSON.stringify(oldBlocks);
    const newStr = JSON.stringify(newBlocks);
    if (oldStr === newStr) continue;

    // Drill down to bullet-level diff — that's what matters for cache hits.
    const flatten = (blocks) => {
      const out = [];
      for (const b of blocks) {
        for (const bullet of b.bullets) {
          out.push({
            blockLine: b.blockLine,
            normalizedContext: b.normalizedContext,
            ...bullet,
          });
        }
      }
      return out;
    };
    const oldFlat = flatten(oldBlocks);
    const newFlat = flatten(newBlocks);
    // Identity for matching: (line, primary identifier).
    const idOf = (b) => {
      if (kind === "vocabBlocks") return `${b.line} ${b.bullet}`;
      if (kind === "grammarBlocks") return `${b.line} ${b.topicId} ${b.note ?? ""}`;
      return `${b.line} ${b.counterId}`;
    };
    const oldById = new Map(oldFlat.map((b) => [idOf(b), b]));
    const newById = new Map(newFlat.map((b) => [idOf(b), b]));
    const added = [...newById.keys()].filter((k) => !oldById.has(k));
    const removed = [...oldById.keys()].filter((k) => !newById.has(k));
    const changedIds = [...oldById.keys()].filter(
      (k) => newById.has(k) && JSON.stringify(oldById.get(k)) !== JSON.stringify(newById.get(k)),
    );
    const cacheKeyChanged = changedIds.filter(
      (k) => oldById.get(k).cacheKey !== newById.get(k).cacheKey,
    );
    result[kind] = {
      added: added.map((k) => newById.get(k)),
      removed: removed.map((k) => oldById.get(k)),
      changed: changedIds.map((k) => ({ old: oldById.get(k), new: newById.get(k) })),
      cacheKeyChangedCount: cacheKeyChanged.length,
    };
  }
  return Object.keys(result).length > 0 ? result : null;
}

function summarize(diff, rel) {
  const lines = [];
  for (const [kind, d] of Object.entries(diff)) {
    const tag = kind.replace("Blocks", "").padEnd(8);
    const cacheTag = d.cacheKeyChangedCount > 0 ? ` [⚠ ${d.cacheKeyChangedCount} cache-key changes — will rerun LLM]` : "";
    lines.push(
      `  ${tag}: +${d.added.length} -${d.removed.length} ~${d.changed.length}${cacheTag}`,
    );
    const sample = d.added[0] ?? d.removed[0] ?? d.changed[0];
    if (sample) {
      const preview = JSON.stringify(sample).slice(0, 200);
      lines.push(`    first: ${preview}`);
    }
  }
  return `${rel}\n${lines.join("\n")}`;
}

// ── main ─────────────────────────────────────────────────────────────────────

const args = process.argv.slice(2);
const write = args.includes("--write");

const current = buildSnapshot();

if (write) {
  writeFileSync(GOLDEN_PATH, JSON.stringify(current, null, 2) + "\n");
  const fileCount = Object.keys(current.files).length;
  let vocab = 0, grammar = 0, counter = 0;
  for (const f of Object.values(current.files)) {
    for (const b of f.vocabBlocks) vocab += b.bullets.length;
    for (const b of f.grammarBlocks) grammar += b.bullets.length;
    for (const b of f.counterBlocks) counter += b.bullets.length;
  }
  console.log(
    `wrote golden: ${path.relative(projectRoot, GOLDEN_PATH)}\n` +
      `  ${fileCount} files; ${vocab} vocab + ${grammar} grammar + ${counter} counter bullets`,
  );
  process.exit(0);
}

if (!existsSync(GOLDEN_PATH)) {
  console.error(
    `no golden found at ${GOLDEN_PATH}\nrun: node fuzz-markdown-golden.mjs --write`,
  );
  process.exit(2);
}

const golden = JSON.parse(readFileSync(GOLDEN_PATH, "utf8"));
if (golden.version !== GOLDEN_VERSION) {
  console.error(
    `golden version mismatch (file=${golden.version}, code=${GOLDEN_VERSION}); regenerate with --write`,
  );
  process.exit(2);
}

const allFiles = new Set([
  ...Object.keys(golden.files),
  ...Object.keys(current.files),
]);
const diffs = [];
let totalCacheKeyChanges = 0;
for (const rel of [...allFiles].sort()) {
  const d = diffFile(rel, golden.files[rel], current.files[rel]);
  if (d) {
    diffs.push({ rel, d });
    for (const v of Object.values(d)) totalCacheKeyChanges += v.cacheKeyChangedCount;
  }
}

if (diffs.length === 0) {
  const fileCount = Object.keys(current.files).length;
  console.log(`[pass] golden matches across ${fileCount} files`);
  process.exit(0);
}

console.log(`[FAIL] ${diffs.length} file(s) differ from golden:\n`);
for (const { rel, d } of diffs) {
  console.log(summarize(d, rel));
  console.log();
}
if (totalCacheKeyChanges > 0) {
  console.log(
    `⚠ ${totalCacheKeyChanges} bullet(s) have changed cache keys — running ` +
      `prepare-publish.mjs after this rewrite would re-burn LLM tokens for them.`,
  );
} else {
  console.log(
    `note: no cache-key changes — bullet/structure churn only, no LLM re-run cost.`,
  );
}
process.exit(1);
