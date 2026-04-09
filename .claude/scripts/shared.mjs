/**
 * shared.mjs
 * Utilities shared across scripts.
 */

import { existsSync, readFileSync, readdirSync } from "fs";
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
 * Open (or build) jmdict.sqlite and return a better-sqlite3 Database instance.
 *
 * By default opens read-only, which is safe for concurrent use from multiple
 * connections in the same process (no write pragmas, no locking conflicts).
 *
 * Pass { checkJournalMode: true } when building or preparing the database for
 * iOS app bundling. This opens read-write and switches the journal mode from
 * WAL to DELETE if needed — iOS requires the database file to be self-contained
 * with no WAL sidecar files.
 *
 * If the database does not exist, looks for a jmdict-eng-*.json source file in
 * the project root and builds the database (one-time setup). Throws if none found.
 */
export async function openJmdictDb({ checkJournalMode = false } = {}) {
  if (!existsSync(JMDICT_DB)) {
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
    db.close();
  }
  if (checkJournalMode) {
    const db = new Database(JMDICT_DB);
    if (db.pragma("journal_mode", { simple: true }) === "wal") {
      db.pragma("journal_mode = DELETE");
    }
    return db;
  }
  return new Database(JMDICT_DB, { readonly: true });
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

// True if the string contains only Japanese characters
export function isJapanese(str) {
  return /^[\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FFF\u3400-\u4DBF\uF900-\uFAFF\u3005\u30FC。？！]+$/.test(
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

// Helper: extract <details> blocks matching a summary type, with summary tags stripped.
// Yields { match, inner, stripped } for each matching block.
export function* extractDetailsBlocks(content, summaryType) {
  const summaryRegex = new RegExp(`<summary>\\s*${summaryType}\\s*<\\/summary>`, "i");
  const detailsRegex = /<details\b[^>]*>([\s\S]*?)<\/details>/gi;
  let match;
  while ((match = detailsRegex.exec(content)) !== null) {
    const inner = match[1];
    if (!summaryRegex.test(inner)) continue;
    const stripped = inner.replace(/<summary>[\s\S]*?<\/summary>/i, "");
    yield { match, inner, stripped };
  }
}

// Extract bullet text from all <details><summary>Vocab</summary> blocks in a file.
// Returns plain strings (no line numbers). Used by get-quiz-context.mjs.
// check-vocab.mjs has its own version that also tracks line numbers.
export function extractVocabBullets(content) {
  const bullets = [];
  for (const { stripped } of extractDetailsBlocks(content, "Vocab")) {
    for (const line of stripped.split("\n")) {
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
          .join("; ") +
        (s.appliesToKanji[0] !== "*"
          ? ` (applies to these kanji: ${s.appliesToKanji.join(" or ")})`
          : ""),
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

// --- Grammar helpers ---

export const GRAMMAR_DIR = path.join(projectRoot, "grammar");

/**
 * Load all grammar databases and return a Map<prefixedId, entry>.
 * Each entry: { source, id, prefixedId, titleEn, titleJp?, level, href, aliasOf? }
 * Source prefixes: "genki:", "bunpro:", "dbjg:", "kanshudo:"
 */
export function loadGrammarDatabases() {
  const map = new Map();

  function loadTsv(filePath, source, opts = {}) {
    const content = readFileSync(filePath, "utf8");
    const lines = content.split("\n");
    // Skip comment/header line(s)
    const startLine = lines[0].startsWith("#") ? 2 : 1;
    for (let i = startLine; i < lines.length; i++) {
      const line = lines[i].trim();
      if (!line) continue;
      const cols = line.split("\t");
      const id = cols[0];
      const prefixedId = `${source}:${id}`;
      const entry = {
        source,
        id,
        prefixedId,
        href: cols[1] || "",
        level: cols[2] || "",
        titleEn: cols[opts.titleEnCol ?? 3] || "",
        titleJp: opts.titleJpCol != null ? cols[opts.titleJpCol] || "" : "",
      };
      if (opts.aliasOfCol != null && cols[opts.aliasOfCol]) {
        entry.aliasOf = cols[opts.aliasOfCol]
          .split(",")
          .map((t) => `${source}:${t.trim()}`);
      }
      map.set(prefixedId, entry);
    }
  }

  // Genki: id, href, option, title-en
  loadTsv(path.join(GRAMMAR_DIR, "grammar-stolaf-genki.tsv"), "genki");

  // Bunpro: id, href, option, title-jp, title-en
  loadTsv(path.join(GRAMMAR_DIR, "grammar-bunpro.tsv"), "bunpro", {
    titleJpCol: 3,
    titleEnCol: 4,
  });

  // DBJG: id, href, option, title-en, alias-of
  loadTsv(path.join(GRAMMAR_DIR, "grammar-dbjg.tsv"), "dbjg", {
    aliasOfCol: 4,
  });

  // Kanshudo: id, href, level, title, gloss  (no titleJp, no alias-of)
  loadTsv(path.join(GRAMMAR_DIR, "kanshudo-grammar.tsv"), "kanshudo");

  // IMABI: id, href, level, title  (no titleJp, no alias-of)
  loadTsv(path.join(GRAMMAR_DIR, "grammar-imabi.tsv"), "imabi");

  return map;
}

/**
 * Extract grammar bullets (with line numbers) from Grammar details blocks.
 * Returns [{ topicId, note, line }] where topicId is the prefixed ID (first token)
 * and note is any free text after it.
 */
export function extractGrammarBullets(content) {
  const bullets = [];
  for (const { match, stripped } of extractDetailsBlocks(content, "Grammar")) {
    const openingTagLen = match[0].length - match[1].length - "</details>".length;
    const innerStartIdx = match.index + openingTagLen;
    const innerStartLine = content.slice(0, innerStartIdx).split("\n").length;

    const innerLines = stripped.split("\n");
    for (let i = 0; i < innerLines.length; i++) {
      const trimmed = innerLines[i].trim();
      if (!trimmed.startsWith("-")) continue;
      const bullet = trimmed.slice(1).trim();
      if (!bullet) continue;

      // First token is the topic ID (must contain a colon for the source prefix)
      const spaceIdx = bullet.indexOf(" ");
      const topicId = spaceIdx === -1 ? bullet : bullet.slice(0, spaceIdx);
      const note = spaceIdx === -1 ? "" : bullet.slice(spaceIdx + 1).trim();

      // Normalize prefix to lowercase
      const colonIdx = topicId.indexOf(":");
      const normalized =
        colonIdx === -1
          ? topicId
          : topicId.slice(0, colonIdx).toLowerCase() + topicId.slice(colonIdx);

      bullets.push({
        topicId: normalized,
        note,
        line: innerStartLine + i,
        matchIndex: match.index,
      });
    }
  }
  return bullets;
}

/**
 * Migrate grammar-equivalences.json from old array-of-arrays format to
 * array-of-objects. New format entries are passed through unchanged.
 * Exported here (not in add-grammar-equivalence.mjs) so other scripts can
 * import it without triggering add-grammar-equivalence's top-level side effects.
 *
 * @param {Array} raw
 * @returns {Array<{topics: string[], summary?: string, subUses?: string[], cautions?: string[], stub?: boolean}>}
 */
export function migrateEquivalences(raw) {
  if (!Array.isArray(raw)) return [];
  return raw.map((entry) => (Array.isArray(entry) ? { topics: entry } : entry));
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
