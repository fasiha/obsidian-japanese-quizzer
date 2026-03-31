/**
 * check-grammar.mjs
 * Reads all Markdown files with `llm-review: true` frontmatter, extracts grammar
 * bullets from <details><summary>Grammar</summary> blocks, and validates each
 * against the three grammar databases (Genki, Bunpro, DBJG).
 *
 * Reports:
 *   - Bullets missing a source prefix (must be source:id format)
 *   - Bullets with an unknown source prefix
 *   - Bullets whose topic ID doesn't match any entry in the database
 *   - Alias references (valid but points to another entry)
 *   - Summary stats
 *
 * Usage: node .claude/scripts/check-grammar.mjs
 */

import { readFileSync } from "fs";
import path from "path";
import {
  findMdFiles,
  parseFrontmatter,
  projectRoot,
  loadGrammarDatabases,
  extractGrammarBullets,
} from "./shared.mjs";

const VALID_SOURCES = new Set(["genki", "bunpro", "dbjg", "kanshudo", "imabi"]);

const grammarDb = loadGrammarDatabases();
const mdFiles = findMdFiles(projectRoot);
const problems = [];
const validRefs = [];
let totalChecked = 0;

for (const filePath of mdFiles) {
  const content = readFileSync(filePath, "utf8");
  if (!parseFrontmatter(content)?.["llm-review"]) continue;

  const bullets = extractGrammarBullets(content);
  const relPath = path.relative(projectRoot, filePath);

  for (const { topicId, note, line } of bullets) {
    totalChecked++;

    const colonIdx = topicId.indexOf(":");
    if (colonIdx === -1) {
      problems.push({
        file: relPath,
        line,
        direct: `${relPath}:${line}`,
        topicId,
        note,
        error: "missing source prefix (must be source:id, e.g. genki:potential-verbs)",
      });
      continue;
    }

    const source = topicId.slice(0, colonIdx);
    if (!VALID_SOURCES.has(source)) {
      problems.push({
        file: relPath,
        line,
        direct: `${relPath}:${line}`,
        topicId,
        note,
        error: `unknown source "${source}" (valid: ${[...VALID_SOURCES].join(", ")})`,
      });
      continue;
    }

    const entry = grammarDb.get(topicId);
    if (!entry) {
      // Try to suggest close matches
      const bareId = topicId.slice(colonIdx + 1);
      const suggestions = [];
      for (const [key, val] of grammarDb) {
        if (key.startsWith(`${source}:`) && val.id.includes(bareId)) {
          suggestions.push(key);
        }
      }
      problems.push({
        file: relPath,
        line,
        direct: `${relPath}:${line}`,
        topicId,
        note,
        error: "topic not found in database",
        suggestions: suggestions.slice(0, 5),
      });
      continue;
    }

    const ref = {
      file: relPath,
      line,
      topicId,
      titleEn: entry.titleEn,
      level: entry.level,
    };
    if (entry.aliasOf) {
      ref.aliasOf = entry.aliasOf;
    }
    if (note) ref.note = note;
    validRefs.push(ref);
  }
}

console.log(JSON.stringify({ totalChecked, validCount: validRefs.length, problemCount: problems.length, problems }, null, 2));
