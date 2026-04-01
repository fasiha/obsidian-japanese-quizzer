#!/usr/bin/env node
/**
 * Combines a Markdown file with vocabulary annotations produced by the LLM.
 *
 * Reads the original Markdown file and an annotation JSON file, then writes
 * a new file at {original-basename}.annotated.md. Each annotated Japanese
 * line is followed by a <details>Vocab</details> block. Duplicate and
 * non-Japanese lines are reproduced as-is with no vocab block.
 *
 * Annotation JSON format (written by the LLM):
 *   [{ "id": 5, "entries": ["- reading kanji", "- kana", "- Not in JMDict: ..."] }, ...]
 *
 * The id values must match line indices from filter-for-annotation.mjs output.
 * If entries is empty, no <details> block is inserted for that line.
 *
 * Usage: node recombine-annotations.mjs <original.md> <annotations.json>
 */

import { readFileSync, writeFileSync } from "fs";
import path from "path";

const [, , filePath, annotationsPath] = process.argv;
if (!filePath || !annotationsPath) {
  console.error(
    "Usage: node recombine-annotations.mjs <original.md> <annotations.json>"
  );
  process.exit(1);
}

const originalText = readFileSync(filePath, "utf8");
const lines = originalText.split("\n");

const annotations = JSON.parse(readFileSync(annotationsPath, "utf8"));
const annotationMap = new Map(annotations.map((a) => [a.id, a.entries]));

const outputLines = [];
for (let i = 0; i < lines.length; i++) {
  outputLines.push(lines[i]);

  const entries = annotationMap.get(i);
  if (entries && entries.length > 0) {
    outputLines.push("<details><summary>Vocab</summary>");
    for (const entry of entries) {
      outputLines.push(entry);
    }
    outputLines.push("</details>");
  }
}

const ext = path.extname(filePath);
const base = filePath.slice(0, filePath.length - ext.length);
const outputPath = base + ".annotated" + ext;

writeFileSync(outputPath, outputLines.join("\n"), "utf8");

const duplicatesSkipped =
  lines.filter((line) => /[\u3040-\u9FFF]/.test(line) && !/^\s*\[.*\]\s*$/.test(line)).length -
  annotations.length;

console.log(
  `Wrote ${outputPath} — ${annotations.length} unique lines annotated, ${Math.max(0, duplicatesSkipped)} duplicate lines skipped`
);
