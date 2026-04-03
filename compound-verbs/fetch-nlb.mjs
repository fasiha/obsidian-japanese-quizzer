/**
 * compound-verbs/fetch-nlb.mjs
 *
 * Incrementally fetches NLB basicinfob frequency data for all compound words
 * found in compound-verbs/survey/*.json that are not yet in the local cache.
 *
 * Output: compound-verbs/nlb-cache.json  (NOT committed to git — NINJAL's data)
 *
 * Usage:
 *   node compound-verbs/fetch-nlb.mjs
 *   node compound-verbs/fetch-nlb.mjs --dry-run   (show what would be fetched)
 *
 * The script is safe to interrupt and rerun. It only fetches missing entries.
 * Random delay of 30–120 seconds between requests to avoid overwhelming the server.
 */

import { readFileSync, writeFileSync, readdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const surveyDir = join(__dirname, "survey");
const cachePath = join(__dirname, "nlb-cache.json");

const dryRun = process.argv.includes("--dry-run");

// Load existing cache
let cache = {};
try {
  cache = JSON.parse(readFileSync(cachePath, "utf8"));
  console.log(`Loaded cache with ${Object.keys(cache).length} entries`);
} catch {
  console.log("No existing cache, starting fresh");
}

// Collect all NLB_links from survey files
const needed = new Map(); // NLB_link -> headword (for logging)
for (const filename of readdirSync(surveyDir).filter((f) => f.endsWith(".json"))) {
  const entries = JSON.parse(readFileSync(join(surveyDir, filename), "utf8"));
  for (const entry of entries) {
    if (entry.NLB_link && !cache[entry.NLB_link]) {
      needed.set(entry.NLB_link, entry.headword);
    }
  }
}

if (needed.size === 0) {
  console.log("All entries already cached, nothing to fetch");
  process.exit(0);
}

console.log(`Need to fetch ${needed.size} entries`);
if (dryRun) {
  for (const [link, headword] of needed) {
    console.log(`  would fetch ${link} (${headword})`);
  }
  process.exit(0);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function randomDelay() {
  return 46_000 + Math.random() * 36_000;
}

let fetched = 0;
for (const [nlbLink, headword] of needed) {
  const url = `https://nlb.ninjal.ac.jp/basicinfob/${nlbLink}/`;
  process.stdout.write(`Fetching ${nlbLink} (${headword})... `);

  try {
    const res = await fetch(url);
    if (!res.ok) {
      console.log(`HTTP ${res.status}, skipping`);
    } else {
      const data = await res.json();
      cache[nlbLink] = data;
      writeFileSync(cachePath, JSON.stringify(cache, null, 2), "utf8");
      fetched++;
      console.log(`done (freq=${data.freq ?? "?"})`);
    }
  } catch (err) {
    console.log(`error: ${err.message}, skipping`);
  }

  // Don't delay after the last entry
  if (fetched < needed.size) {
    const delay = randomDelay();
    console.log(`  waiting ${(delay / 1000).toFixed(0)}s...`);
    await sleep(delay);
  }
}

console.log(`\nFetched ${fetched} new entries. Cache now has ${Object.keys(cache).length} entries.`);
