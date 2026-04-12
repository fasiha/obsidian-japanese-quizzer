/**
 * compound-verbs/validate-comparison.mjs
 *
 * Validates the comparison tables from the Gemma 4 re-evaluation (2026-04-10).
 * Parses each assignment .txt file, extracts the JSON, counts per-meaning
 * assignments and unassigned compounds, and prints markdown tables.
 *
 * Usage: node compound-verbs/validate-comparison.mjs
 */

import { readFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const clusters = join(__dirname, "clusters");

// --- File map: [label, suffix, totalCompounds, filename] ---

const runs = [
  // 立てる
  ["Gemini-think (rare glosses only)",            "立てる", 51, "立てる-assignments-2026-04-05_06-27-42-475-google-gemini-2.5-thinking.txt"],
  ["Gemini-think (all glosses)",                  "立てる", 51, "立てる-assignments-2026-04-10_16-29-00-000-gemini-2.5-thinking.txt"],
  ["Gemini-fast (rare glosses only)",             "立てる", 51, "立てる-assignments-2026-04-05_06-27-42-475-google-gemini-2.5-fast.txt"],
  ["Gemini-fast (all glosses)",                   "立てる", 51, "立てる-assignments-2026-04-10_16-31-00-000-gemini-2.5-fast.txt"],
  ["Sonnet (rare glosses only)",                  "立てる", 51, "立てる-assignments-2026-04-10_15-59-32-951-claude-sonnet-4-20250514.txt"],
  ["Sonnet (all glosses)",                        "立てる", 51, "立てる-assignments-2026-04-10_15-57-23-936-claude-sonnet-4-20250514.txt"],
  ["Haiku (rare glosses only)",                   "立てる", 51, "立てる-assignments-2026-04-10_15-59-02-552-claude-haiku-4-5-20251001.txt"],
  ["Haiku (all glosses)",                         "立てる", 51, "立てる-assignments-2026-04-10_15-55-10-603-claude-haiku-4-5-20251001.txt"],
  ["31b @ 1.2 (all glosses)",                     "立てる", 51, "立てる-assignments-2026-04-10_08-03-47-432-bartowski-google_gemma-4-31B-it-GGUF-Q4_K_M.txt"],
  ["31b @ 1.5 (all glosses)",                     "立てる", 51, "立てる-assignments-2026-04-10_08-14-29-977-bartowski-google_gemma-4-31B-it-GGUF-Q4_K_M.txt"],
  ["26b-a4b @ 1.2 (all glosses)",                 "立てる", 51, "立てる-assignments-2026-04-10_06-38-00-102-unsloth-gemma-4-26B-A4B-it-GGUF-Q4_K_M.txt"],
  ["26b-a4b @ 1.5 (all glosses)",                 "立てる", 51, "立てる-assignments-2026-04-10_06-42-00-670-unsloth-gemma-4-26B-A4B-it-GGUF-Q4_K_M.txt"],
  ["31b @ 1.0 (rare glosses only, orig)",         "立てる", 51, "立てる-assignments-2026-04-05_06-27-42-475-google-gemma-4-31b.txt"],
  ["26b-a4b @ 1.0 (rare glosses only, orig)",     "立てる", 51, "立てる-assignments-2026-04-05_05-54-42-970-google-gemma-4-26b-a4b.txt"],

  // 出す
  ["Gemini-think (rare glosses only)",            "出す", 100, "出す-assignments-2026-04-05_18-07-00-000-google-gemini-2.5-thinking.txt"],
  ["Gemini-think (all glosses)",                  "出す", 100, "出す-assignments-2026-04-10_16-33-00-000-gemini-2.5-thinking.txt"],
  ["Gemini-fast (rare glosses only)",             "出す", 100, "出す-assignments-2026-04-05_18-07-00-000-google-gemini-2.5-fast.txt"],
  ["Gemini-fast (all glosses)",                   "出す", 100, "出す-assignments-2026-04-10_16-33-00-000-gemini-2.5-fast.txt"],
  ["Sonnet (rare glosses only)",                  "出す", 100, "出す-assignments-2026-04-10_16-00-04-080-claude-sonnet-4-20250514.txt"],
  ["Sonnet (all glosses)",                        "出す", 100, "出す-assignments-2026-04-10_15-57-48-561-claude-sonnet-4-20250514.txt"],
  ["Haiku (rare glosses only)",                   "出す", 100, "出す-assignments-2026-04-10_15-59-11-662-claude-haiku-4-5-20251001.txt"],
  ["Haiku (all glosses)",                         "出す", 100, "出す-assignments-2026-04-10_15-55-31-577-claude-haiku-4-5-20251001.txt"],
  ["31b @ 1.2 (all glosses)",                     "出す", 100, "出す-assignments-2026-04-10_08-29-54-969-bartowski-google_gemma-4-31B-it-GGUF-Q4_K_M.txt"],
  ["31b @ 1.5 (all glosses)",                     "出す", 100, "出す-assignments-2026-04-10_08-43-10-693-bartowski-google_gemma-4-31B-it-GGUF-Q4_K_M.txt"],
  ["26b-a4b @ 1.2 (all glosses)",                 "出す", 100, "出す-assignments-2026-04-10_06-52-15-778-unsloth-gemma-4-26B-A4B-it-GGUF-Q4_K_M.txt"],
  ["26b-a4b @ 1.5 (all glosses)",                 "出す", 100, "出す-assignments-2026-04-10_06-58-53-989-unsloth-gemma-4-26B-A4B-it-GGUF-Q4_K_M.txt"],
  ["31b @ 1.0 (rare glosses only, orig)",         "出す", 100, "出す-assignments-2026-04-05_06-21-50-187-google-gemma-4-31b.txt"],
  ["26b-a4b @ 1.0 (rare glosses only, orig)",     "出す", 100, "出す-assignments-2026-04-05_05-53-04-662-google-gemma-4-26b-a4b.txt"],
];

function extractJson(text) {
  const matches = [...text.matchAll(/^\s*\{/gm)];
  const last = matches.at(-1);
  if (!last) return null;
  const jsonText = text.slice(last.index).replace(/\n?```\s*$/, "").trim();
  return JSON.parse(jsonText);
}

function extractCompoundList(text, suffix) {
  // Extract compound list from the PROMPT section
  const marker = `Compounds ending in -${suffix}`;
  const idx = text.indexOf(marker);
  if (idx < 0) return null;
  // Find the line after the marker, then collect lines until blank or "Reason through"
  const afterMarker = text.slice(idx);
  const lines = afterMarker.split("\n").slice(1); // skip the header line
  const compounds = [];
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("Reason") || trimmed.startsWith("Example")) break;
    // Strip any gloss in parens: 組み立てる（to assemble...） → 組み立てる
    const headword = trimmed.replace(/（.*）$/, "").trim();
    if (headword) compounds.push(headword);
  }
  return compounds;
}

function processFile(label, suffix, totalExpected, filename) {
  const path = join(clusters, filename);
  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    return { label, suffix, error: `FILE NOT FOUND: ${filename}` };
  }

  // Extract compound list from prompt
  const compoundList = extractCompoundList(text, suffix);
  const totalCompounds = compoundList ? compoundList.length : totalExpected;

  // Extract JSON — try from ANSWER section first, then THINKING, then whole RESPONSE
  let json;
  const responseIdx = text.indexOf("========== RESPONSE ==========");
  const responseText = responseIdx >= 0 ? text.slice(responseIdx) : text;

  try {
    json = extractJson(responseText);
  } catch {
    // Try the whole file
    try {
      json = extractJson(text);
    } catch {
      return { label, suffix, error: "JSON PARSE FAILED" };
    }
  }

  if (!json) return { label, suffix, error: "NO JSON FOUND" };

  // Count per-meaning
  const meanings = Object.entries(json);
  const counts = meanings.map(([, words]) => words.length);
  const allAssigned = new Set();
  for (const [, words] of meanings) {
    for (const w of words) allAssigned.add(w);
  }

  const unassigned = compoundList
    ? compoundList.filter(c => !allAssigned.has(c))
    : [];

  return {
    label,
    suffix,
    counts,
    uniqueAssigned: allAssigned.size,
    totalCompounds,
    unassigned: totalCompounds - allAssigned.size,
    unassignedList: unassigned,
  };
}

// --- Process all runs and print tables ---

const suffixes = ["立てる", "出す"];
const meaningLabels = {
  "立てる": ["M1 (vertical)", "M2 (intensity)", "M3 (formal)", "M4 (transform)"],
  "出す": ["M1 (extract)", "M2 (begin)", "M3 (create)", "M4 (force)"],
};

for (const suffix of suffixes) {
  const suffixRuns = runs.filter(r => r[1] === suffix);
  const total = suffixRuns[0][2];
  const mLabels = meaningLabels[suffix];

  console.log(`\n**${suffix} (${total} compounds)**\n`);
  console.log(`| Model | ${mLabels.join(" | ")} | Unassigned |`);
  console.log(`|---|${mLabels.map(() => "---|").join("")}---|`);

  for (const [label, sfx, tot, file] of suffixRuns) {
    const result = processFile(label, sfx, tot, file);
    if (result.error) {
      console.log(`| ${label} | ${result.error} |`);
      continue;
    }
    const countCells = result.counts.map(c => String(c)).join(" | ");
    console.log(`| ${label} | ${countCells} | **${result.unassigned}** |`);
  }
}

// --- Also print unassigned details ---
console.log("\n\n**Unassigned compounds per run:**\n");
for (const [label, suffix, total, file] of runs) {
  const result = processFile(label, suffix, total, file);
  if (result.error || result.unassigned === 0) continue;
  console.log(`- ${suffix} ${label} (${result.unassigned}): ${result.unassignedList.join("、")}`);
}
