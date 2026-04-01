#!/usr/bin/env node
/**
 * inject-timestamps.mjs
 *
 * Reads an SRT file and a lyrics Markdown file, then outputs the Markdown
 * to stdout with <timed-audio> tags injected after each lyric line.
 *
 * Usage:
 *   node inject-timestamps.mjs <file.srt> <lyrics.md> [audio-filename]
 *
 * The audio filename defaults to the SRT filename with .mp3 extension.
 * It is used verbatim as the `path` attribute in the <timed-audio> tag,
 * so it should be relative to the Markdown file's directory.
 *
 * How matching works:
 *   1. Each physical text line in the SRT (including lines in multi-line
 *      entries) is added to an ordered queue keyed by normalised text.
 *   2. Lyric lines in the Markdown are matched against this queue in order.
 *      Duplicate lines each consume one entry from the queue, so repeated
 *      chorus lines are assigned consecutive timestamps correctly.
 *   3. Lines that have no SRT match are passed through unchanged.
 */

import { readFileSync } from "fs";
import { basename, extname } from "path";

// ── CLI args ─────────────────────────────────────────────────────────────────

const [, , srtFile, mdFile, audioArg] = process.argv;

if (!srtFile || !mdFile) {
  console.error(
    "Usage: node inject-timestamps.mjs <file.srt> <lyrics.md> [audio-filename]"
  );
  process.exit(1);
}

const audioFilename =
  audioArg ?? basename(srtFile).replace(/\.[^.]+$/, "") + ".mp3";

// ── SRT parsing ───────────────────────────────────────────────────────────────

/** Parse SRT timestamps ("HH:MM:SS,mmm") into fractional seconds. */
function srtTimeToSeconds(ts) {
  return ts.replace(",", ".").split(":").reverse()
    .reduce((acc, v, i) => acc + parseFloat(v) * 60 ** i, 0);
}

/**
 * Parse an SRT file into an array of { start, end, lines[] } entries.
 * Multi-line subtitle entries produce one object whose `lines` array
 * contains each physical text line.
 */
function parseSrt(text) {
  const entries = [];
  const blocks = text.trim().split(/\n\n+/);
  for (const block of blocks) {
    const rows = block.split("\n").map((r) => r.trim());
    // rows[0] is the sequence number, rows[1] is the time arrow, rows[2..] are text
    if (rows.length < 3) continue;
    const arrow = rows[1];
    if (!arrow.includes("-->")) continue;
    const [startStr, endStr] = arrow.split("-->").map((s) => s.trim());
    const start = srtTimeToSeconds(startStr);
    const end = srtTimeToSeconds(endStr);
    const lines = rows.slice(2).filter(Boolean);
    if (lines.length) entries.push({ start, end, lines });
  }
  return entries;
}

/** Format fractional seconds for the W3C media fragment #t= syntax. */
function formatTimestamp(seconds) {
  return seconds.toFixed(3);
}

// Normalize for matching: collapse whitespace
function normalise(line) {
  return line.replace(/\s+/g, " ").trim();
}

// Strip <ruby>base<rt>reading</rt></ruby> tags, keeping the base character
function stripRuby(str) {
  return str.replace(/<ruby>([^<]*?)<rt>[^<]*?<\/rt><\/ruby>/g, "$1");
}

/** Returns true if the string contains at least one CJK character. */
function containsJapanese(str) {
  return /[\u3000-\u9fff\uff00-\uffef]/.test(str);
}

// ── Markdown processing ───────────────────────────────────────────────────────

const mdLines = readFileSync(mdFile, "utf8").split("\n");
const srtEntries = parseSrt(readFileSync(srtFile, "utf8"));

let mdIndex = 0;
let inFrontmatter = false;
let frontmatterDone = false;
let inDetails = false;

// Helper: output a line and advance past any <details> block if we're at one
function outputLineAndAdvance(line) {
  console.log(line);
  mdIndex++;
}

// Iterate through SRT entries in order, searching forward through Markdown
for (const { start, end, lines: srtLines } of srtEntries) {
  for (const srtLine of srtLines) {
    const srtNorm = normalise(srtLine);
    let matched = false;

    // Search forward through Markdown for a matching lyric line
    while (mdIndex < mdLines.length && !matched) {
      const raw = mdLines[mdIndex];
      const line = raw.trimEnd();

      // Track YAML front matter (first --- block)
      if (!frontmatterDone) {
        if (mdIndex === 0 && line === "---") {
          inFrontmatter = true;
          outputLineAndAdvance(line);
          continue;
        }
        if (inFrontmatter && line === "---") {
          inFrontmatter = false;
          frontmatterDone = true;
          outputLineAndAdvance(line);
          continue;
        }
        if (inFrontmatter) {
          outputLineAndAdvance(line);
          continue;
        }
      }

      // Track <details> blocks (vocab annotations)
      if (line.startsWith("<details")) {
        inDetails = true;
        outputLineAndAdvance(line);
        continue;
      }
      if (line.startsWith("</details>")) {
        inDetails = false;
        outputLineAndAdvance(line);
        continue;
      }
      if (inDetails) {
        outputLineAndAdvance(line);
        continue;
      }

      // Decide whether this is a lyric line worth tagging:
      //  - must contain Japanese
      //  - must not be a section header like [繰り返し]
      //  - must not be empty
      const isLyric =
        line.length > 0 &&
        !line.startsWith("[") &&
        containsJapanese(line);

      if (!isLyric) {
        // Not a lyric line, output and continue searching
        outputLineAndAdvance(line);
        continue;
      }

      // Try to match this lyric line (after stripping ruby tags) against the SRT line
      const mdNorm = normalise(stripRuby(line));
      if (mdNorm === srtNorm) {
        // Match! Inject timestamp and advance
        const startFmt = formatTimestamp(start);
        const endFmt = formatTimestamp(end);
        console.log(
          `${line} <audio controls data-src="${audioFilename}#t=${startFmt},${endFmt}" />`
        );
        mdIndex++;
        matched = true;
      } else {
        // Not a match; this line is in Markdown but not in current SRT.
        // Output as-is and continue searching for the SRT line.
        outputLineAndAdvance(line);
      }
    }

    if (!matched) {
      console.error(`[warn] no match in Markdown for SRT line: ${srtLine}`);
    }
  }
}

// Output remaining lines in Markdown
while (mdIndex < mdLines.length) {
  const raw = mdLines[mdIndex];
  const line = raw.trimEnd();
  console.log(line);
  mdIndex++;
}
