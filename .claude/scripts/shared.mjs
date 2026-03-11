/**
 * shared.mjs
 * Utilities shared across scripts.
 */

import { existsSync, readdirSync } from "fs";
import path from "path";
import { fileURLToPath } from "url";
import Database from "better-sqlite3";
import { setup } from "jmdict-simplified-node";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const projectRoot = path.resolve(__dirname, "../..");
export const JMDICT_DB = path.join(projectRoot, "jmdict.sqlite");
export const QUIZ_DB = path.join(projectRoot, "quiz.sqlite");
export const QUIZ_SESSION = path.join(
  projectRoot,
  ".claude",
  "quiz-session.txt",
);
export const QUIZ_CONTEXT = path.join(
  projectRoot,
  ".claude",
  "quiz-context.txt",
);
export const SCHEMA_VERSION = 1;

// Beta distribution shape parameter for the Ebisu prior (α = β → symmetric).
// A value slightly above 1 gives a mildly informative prior around 0.5 recall.
export const EBISU_ALPHA = 1.25;

/**
 * Open (or create) jmdict.sqlite and return the better-sqlite3 Database instance.
 * If the DB already exists, opens it directly (switching from WAL to DELETE journal
 * mode only if needed, to avoid needless disk writes).
 * If it doesn't exist, looks for a jmdict-eng-*.json source file in the project root
 * and builds from it (one-time setup); throws if no source JSON is found.
 */
export async function openJmdictDb() {
  if (existsSync(JMDICT_DB)) {
    const db = new Database(JMDICT_DB);
    if (db.pragma("journal_mode", { simple: true }) === "wal") {
      db.pragma("journal_mode = DELETE");
    }
    return db;
  }
  const sourceFiles = readdirSync(projectRoot).filter(
    (f) => f.startsWith("jmdict-eng") && f.endsWith(".json"),
  );
  if (!sourceFiles.length) {
    throw new Error(
      "jmdict.sqlite not found and no jmdict-eng-*.json source found.\n" +
        "Download from https://github.com/scriptin/jmdict-simplified/releases and place in project root.",
    );
  }
  const { db } = await setup(JMDICT_DB, sourceFiles[0]);
  db.pragma("journal_mode = DELETE");
  return db;
}

/**
 * Open quiz.sqlite, verify the schema version, and return the Database instance.
 * Pass { readonly: true } for scripts that only read.
 * Exits with an error if the DB was created by a newer version of the code.
 */
export function openQuizDb(options = {}) {
  const db = new Database(QUIZ_DB, options);
  if (!options.readonly) db.pragma("journal_mode = WAL");
  const currentVersion = db.pragma("user_version", { simple: true });
  if (currentVersion > SCHEMA_VERSION) {
    db.close();
    console.error(
      `quiz.sqlite has schema version ${currentVersion} but this script only knows version ${SCHEMA_VERSION}.\n` +
        `Pull the latest code before running this script.`,
    );
    process.exit(1);
  }
  return db;
}

// Find all .md files under dir, skipping excludeDirs
export function findMdFiles(dir, excludeDirs = ["node_modules", ".claude"]) {
  const results = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (excludeDirs.includes(entry.name)) continue;
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      results.push(...findMdFiles(fullPath, excludeDirs));
    } else if (entry.name.endsWith(".md")) {
      results.push(fullPath);
    }
  }
  return results;
}

// True if the string contains at least one Japanese character
export function isJapanese(str) {
  return /[\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FFF\u3400-\u4DBF\uF900-\uFAFF\u3005\u30FC]/.test(
    str,
  );
}

// Extract leading Japanese tokens from a bullet (stop at first non-Japanese token)
export function extractJapaneseTokens(bulletText) {
  const result = [];
  for (const token of bulletText.split(/\s+/)) {
    if (token && isJapanese(token)) result.push(token);
    else break;
  }
  return result;
}

// Intersect multiple Sets, returning a new Set
export function intersectSets(sets) {
  let result = new Set(sets[0]);
  for (let i = 1; i < sets.length; i++) {
    for (const id of result) {
      if (!sets[i].has(id)) result.delete(id);
    }
  }
  return result;
}

// Extract bullet text from all <details><summary>Vocab</summary> blocks in a file.
// Returns plain strings (no line numbers). Used by get-quiz-context.mjs.
// check-vocab.mjs has its own version that also tracks line numbers.
export function extractVocabBullets(content) {
  const SUMMARY_REGEXP = /<summary>\s*Vocab\s*<\/summary>/i;
  const DETAILS_REGEXP = /<details\b[^>]*>([\s\S]*?)<\/details>/gi;
  const bullets = [];
  let match;
  while ((match = DETAILS_REGEXP.exec(content)) !== null) {
    const inner = match[1];
    if (!SUMMARY_REGEXP.test(inner)) continue;
    for (const line of inner.split("\n")) {
      const trimmed = line.trim();
      if (!trimmed.startsWith("-")) continue;
      const bullet = trimmed.slice(1).trim();
      if (bullet) bullets.push(bullet);
    }
  }
  return bullets;
}

// Return the forms portion of a context line in "written:X,Y  reading:A,B" format
// (or just "reading:A,B" for kana-only words). Irregular forms (iK/ik) are omitted.
// "written:" = JMDict orthographic (kanji/mixed) forms; "reading:" = kana-only forms.
// Using "written:" avoids confusion with the quiz-policy tags {kanji-ok}/{no-kanji}.
// This is the Layer-1 structured format used in quiz-context.txt and Swift contextLine().
export function wordFormsPart(word) {
  const writtenTexts = word.kanji
    .filter((k) => !k.tags.includes("iK"))
    .map((k) => k.text);
  const kanaTexts = word.kana
    .filter((k) => !k.tags.includes("ik"))
    .map((k) => k.text);
  if (writtenTexts.length > 0) {
    return `written:${writtenTexts.join(",")}  reading:${kanaTexts.join(",")}`;
  }
  return `reading:${kanaTexts.join(",")}`;
}

// Return English meanings joined by " / " (one entry per sense).
export function wordMeanings(word, numbered = false) {
  return word.sense
    .map(
      (s, outerIdx) =>
        (numbered ? `(${outerIdx + 1}) ` : "") +
        s.gloss
          .filter((g) => g.lang === "eng")
          .map((g) => g.text)
          .join("; "),
    )
    .filter(Boolean)
    .join(numbered ? ". " : " / ");
}

// Produce a compact one-line summary of a JMDict Word entry.
// Format: "kanji, kana meaning1; meaning2 / sense2meaning1 (#id)"
// Irregular kanji (iK) and irregular kana (ik) forms are omitted from the display.
export function summarizeWord(word) {
  const forms = word.kanji
    .filter((k) => !k.tags.includes("iK"))
    .map((k) => k.text)
    .concat(word.kana.filter((k) => !k.tags.includes("ik")).map((k) => k.text))
    .join(", ");
  const meanings = word.sense
    .map((s) =>
      s.gloss
        .filter((g) => g.lang === "eng")
        .map((g) => g.text)
        .join("; "),
    )
    .filter(Boolean)
    .join(" / ");
  return `${forms} ${meanings}`;
}

// Parse YAML frontmatter and return key-value pairs, or null if none present.
// Only handles simple scalar values (strings, booleans, numbers) — no arrays/objects.
// Tolerates: BOM, Windows (CRLF) line endings, leading blank lines before ---.
export function parseFrontmatter(content) {
  const s = content
    .replace(/^\uFEFF/, "")
    .replace(/\r\n/g, "\n")
    .replace(/^\n+/, "");
  const match = s.match(/^---\n([\s\S]*?)\n---(\n|$)/);
  if (!match) return null;
  const fm = {};
  for (const line of match[1].split("\n")) {
    const colon = line.indexOf(":");
    if (colon === -1) continue;
    const key = line.slice(0, colon).trim();
    const raw = line.slice(colon + 1).trim();
    if (!key) continue;
    fm[key] = raw === "true" ? true : raw === "false" ? false : raw;
  }
  return fm;
}
