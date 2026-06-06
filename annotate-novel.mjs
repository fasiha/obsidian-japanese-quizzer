#!/usr/bin/env node
/**
 * Orchestrator for annotating novel-length Markdown files.
 *
 * Designed for incremental use: stop after N batches with --max-batches so
 * you don't burn tokens on chapters you may never read.
 *
 * Usage:
 *   node annotate-novel.mjs start    <file.md>   [options]  # first run
 *   node annotate-novel.mjs continue <work.db>   [options]  # resume
 *
 * Options:
 *   --morpheme-budget N   Max morphemes per batch (default: 400).
 *                         A single sentence always forms its own batch even if it
 *                         exceeds the budget (never skipped, never split).
 *   --max-batches N       Stop after N batches. Omit to run all batches.
 *   --parallel            Run all batches concurrently (default: sequential).
 *   --dry-run             Print the plan and exit without calling claude.
 */

import { execSync, spawn } from "child_process";
import Database from "better-sqlite3";
import path from "path";

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

const [, , subcommand, inputPath, ...rest] = process.argv;
const args = [inputPath, ...rest].filter(Boolean);

function usage() {
  console.error(
    "Usage:\n" +
    "  node annotate-novel.mjs start    <file.md>  [options]\n" +
    "  node annotate-novel.mjs continue <work.db>  [options]\n" +
    "\n" +
    "Options:\n" +
    "  --morpheme-budget N   Max morphemes per batch (default: 400)\n" +
    "  --max-batches N       Stop after N batches\n" +
    "  --parallel            Run batches concurrently\n" +
    "  --dry-run             Print plan and exit"
  );
  process.exit(1);
}

if (!subcommand || !inputPath || (subcommand !== "start" && subcommand !== "continue")) {
  usage();
}

function getFlag(name) {
  const i = args.indexOf(name);
  if (i === -1) return undefined;
  return args[i + 1];
}

const morphemeBudget = parseInt(getFlag("--morpheme-budget") ?? "400", 10);
const maxBatches = getFlag("--max-batches") !== undefined ? parseInt(getFlag("--max-batches"), 10) : Infinity;
const parallel = args.includes("--parallel");
const dryRun = args.includes("--dry-run");

// ---------------------------------------------------------------------------
// Step 1 — Create or resume the work database
// ---------------------------------------------------------------------------

let workDb;
if (subcommand === "start") {
  console.log(`Creating work database for ${inputPath} …`);
  workDb = execSync(`node annotate-harness.mjs start ${JSON.stringify(inputPath)}`, {
    encoding: "utf8",
  }).trim();
  console.log(`Work database: ${workDb}`);
} else {
  workDb = path.resolve(inputPath);
  console.log(`Resuming work database: ${workDb}`);
}

// ---------------------------------------------------------------------------
// Step 2 — Plan batches by morpheme budget
// ---------------------------------------------------------------------------

const db = new Database(workDb, { readonly: true });
const sentences = db
  .prepare(
    `SELECT id, json_array_length(morphemes) AS morpheme_count
     FROM sentences
     WHERE annotations = '[]'
     ORDER BY id`
  )
  .all();
db.close();

if (sentences.length === 0) {
  console.log("All sentences already annotated. Running done …");
  execSync(`node annotate-harness.mjs done ${JSON.stringify(workDb)}`, { stdio: "inherit" });
  process.exit(0);
}

// Greedy bin: accumulate sentences until budget is exceeded, then start a new
// batch. A single sentence always forms at least one batch even if it alone
// exceeds the budget.
const batches = [];
let current = [];
let currentMorphemes = 0;

for (const s of sentences) {
  if (current.length > 0 && currentMorphemes + s.morpheme_count > morphemeBudget) {
    batches.push(current);
    current = [];
    currentMorphemes = 0;
  }
  current.push(s);
  currentMorphemes += s.morpheme_count;
}
if (current.length > 0) batches.push(current);

const batchesToRun = batches.slice(0, maxBatches === Infinity ? batches.length : maxBatches);

// ---------------------------------------------------------------------------
// Step 3 — Print plan
// ---------------------------------------------------------------------------

console.log(`\nPlan: ${sentences.length} unannotated sentences → ${batches.length} batches (morpheme budget: ${morphemeBudget})`);
if (maxBatches !== Infinity && maxBatches < batches.length) {
  console.log(`Running first ${maxBatches} of ${batches.length} batches (${batches.length - maxBatches} deferred).`);
}
for (let i = 0; i < batchesToRun.length; i++) {
  const b = batchesToRun[i];
  const fromId = b[0].id;
  const toId = b[b.length - 1].id;
  const total = b.reduce((sum, s) => sum + s.morpheme_count, 0);
  console.log(`  Batch ${i + 1}: sentences ${fromId}–${toId} (${b.length} sentences, ${total} morphemes)`);
}
if (batches.length > batchesToRun.length) {
  const remaining = batches.slice(batchesToRun.length);
  const remainingSentences = remaining.reduce((sum, b) => sum + b.length, 0);
  console.log(`  … ${batches.length - batchesToRun.length} more batches (${remainingSentences} sentences) deferred`);
}

if (dryRun) {
  console.log("\nDry run — exiting without calling claude.");
  process.exit(0);
}

// ---------------------------------------------------------------------------
// Step 4 — Execute batches
// ---------------------------------------------------------------------------

function runBatch(batch, batchIndex) {
  const fromId = batch[0].id;
  const toId = batch[batch.length - 1].id;
  const prompt = `/annotate-file "${workDb} ${fromId} ${toId}"`;
  console.log(`\nBatch ${batchIndex + 1}: claude -p '${prompt}'`);

  return new Promise((resolve, reject) => {
    const child = spawn("claude", ["-p", prompt], { stdio: "inherit" });
    child.on("close", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`Batch ${batchIndex + 1} exited with code ${code}`));
    });
    child.on("error", reject);
  });
}

if (parallel) {
  console.log(`\nRunning ${batchesToRun.length} batches in parallel …`);
  await Promise.all(batchesToRun.map((batch, i) => runBatch(batch, i)));
} else {
  console.log(`\nRunning ${batchesToRun.length} batches sequentially …`);
  for (let i = 0; i < batchesToRun.length; i++) {
    await runBatch(batchesToRun[i], i);
  }
}

// ---------------------------------------------------------------------------
// Step 5 — Finalize
// ---------------------------------------------------------------------------

console.log("\nFinalizing …");
execSync(`node annotate-harness.mjs done ${JSON.stringify(workDb)}`, { stdio: "inherit" });
