#!/usr/bin/env node
/**
 * Two-step harness for the annotate-file skill.
 *
 * start: read a Markdown file, run MeCab on every Japanese line, and create a
 *        SQLite work database that the LLM fills in.
 *
 *   node annotate-harness.mjs start <file.md>
 *
 *   Prints the path of the created work database, e.g.:
 *     /tmp/Shippo-annotations-1716480000000.json
 *
 *   Work file shape:
 *   {
 *     "sourceFile": "/abs/path/to/file.md",
 *     "sentences": [
 *       {
 *         "id": 5,                         // line index in source file
 *         "text": "stripped of ruby tags",
 *         "furigana": "base[reading]…",    // only when ruby tags were present
 *         "morphemes": [                   // MeCab output, one object per morpheme
 *           {
 *             "literal": "息",
 *             "pronunciation": "イキ",
 *             "lemmaReading": "イキ",
 *             "lemma": "息",
 *             "pos": "noun-common-general",
 *             "posJa": "名詞-普通名詞-一般",
 *             "inflectionType": "sahen_verb_irregular",  // omitted when absent
 *             "inflectionTypeJa": "サ行変格",             // omitted when absent
 *             "inflection": "continuative-general",      // omitted when absent
 *             "inflectionJa": "連用形-一般",              // omitted when absent
 *             "compoundHint": { "reading": 5, "kanji": 5 } // omitted when 0
 *           }
 *         ],
 *         "annotations": []  // LLM fills this in
 *       }
 *     ]
 *   }
 *
 *   The LLM fills each "annotations" array with strings in the annotate-vocab
 *   format, e.g. ["- いきおい 勢い", "- Not in JMDict: ぽーん — thud sound"].
 *   Lines with no content words get an empty array and no vocab block.
 *
 * done: read the completed work file and produce the annotated Markdown.
 *
 *   node annotate-harness.mjs done <work.json>
 *
 *   Writes <original-dir>/<basename>.annotated.<timestamp>.md and prints a
 *   one-line summary. Can be called before all sentences are annotated —
 *   sentences with empty annotations arrays get no vocab block.
 */

import { execSync, spawn } from "child_process";
import { readFileSync, writeFileSync } from "fs";
import Database from "better-sqlite3";
import path from "path";
import { fileURLToPath } from "url";
import { wordFormsPart, wordMeanings } from "./.claude/scripts/shared.mjs";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const jmdictDbPath = path.join(scriptDir, "jmdict.sqlite");

// ---------------------------------------------------------------------------
// UniDic POS / inflection translation tables (ported from mecabUnidic.ts)
// ---------------------------------------------------------------------------

const POS_MAP = new Map([
  ["代名詞", "pronoun"],
  ["副詞", "adverb"],
  ["助動詞", "auxiliary_verb"],
  ["助詞", "particle"],
  ["係助詞", "binding"],
  ["副助詞", "adverbial"],
  ["接続助詞", "conjunctive"],
  ["格助詞", "case"],
  ["準体助詞", "nominal"],
  ["終助詞", "phrase_final"],
  ["動詞", "verb"],
  ["一般", "general"],
  ["非自立可能", "bound"],
  ["名詞", "noun"],
  ["助動詞語幹", "auxiliary"],
  ["固有名詞", "proper"],
  ["人名", "name"],
  ["名", "firstname"],
  ["姓", "surname"],
  ["地名", "place"],
  ["国", "country"],
  ["数詞", "numeral"],
  ["普通名詞", "common"],
  ["サ変可能", "verbal_suru"],
  ["サ変形状詞可能", "verbal_adjectival"],
  ["副詞可能", "adverbial_suffix"],
  ["助数詞可能", "counter"],
  ["形状詞可能", "adjectival"],
  ["形容詞", "adjective_i"],
  ["形状詞", "adjectival_noun"],
  ["タリ", "tari"],
  ["感動詞", "interjection"],
  ["フィラー", "filler"],
  ["接尾辞", "suffix"],
  ["動詞的", "verbal"],
  ["名詞的", "nominal_suffix"],
  ["助数詞", "counter_suffix"],
  ["形容詞的", "adjective_i_suffix"],
  ["形状詞的", "adjectival_noun_suffix"],
  ["接続詞", "conjunction"],
  ["接頭辞", "prefix"],
  ["空白", "whitespace"],
  ["補助記号", "supplementary_symbol"],
  ["ＡＡ", "ascii_art"],
  ["顔文字", "emoticon"],
  ["句点", "period"],
  ["括弧閉", "bracket_close"],
  ["括弧開", "bracket_open"],
  ["読点", "comma"],
  ["記号", "symbol"],
  ["文字", "character"],
  ["連体詞", "adnominal"],
  ["未知語", "unknown_words"],
  ["カタカナ文", "katakana"],
  ["漢文", "chinese_writing"],
  ["言いよどみ", "hesitation"],
  ["web誤脱", "errors_omissions"],
  ["方言", "dialect"],
  ["ローマ字文", "latin_alphabet"],
  ["新規未知語", "new_unknown_words"],
]);

const INFL_TYPE_MAP = new Map([
  ["五段", "godan_verb"],
  ["ワア行", "wa_a_column"],
  ["カ行変格", "kahen_verb_irregular"],
  ["サ行変格", "sahen_verb_irregular"],
  ["上一段", "kamiichidan_verb_i_row"],
  ["下一段", "shimoichidan_verb_e_row"],
  ["形容詞", "adjective"],
  ["ダ行", "da_column"],
  ["ラ行", "ra_column"],
  ["マ行", "ma_column"],
  ["ナ行", "na_column"],
  ["バ行", "ba_column"],
  ["タ行", "ta_column"],
  ["カ行", "ka_column"],
  ["サ行", "sa_column"],
  ["ハ行", "ha_column"],
  ["ガ行", "ga_column"],
  ["ア行", "a_column"],
  ["ヤ行", "ya_column"],
  ["ザ行", "za_column"],
  ["ダ", "da"],
  ["タイ", "tai"],
  ["マス", "masu"],
  ["デス", "desu"],
  ["レル", "reru"],
  ["ナイ", "nai"],
  ["ラシイ", "rashii"],
  ["無変化型", "uninflected_form"],
  ["助動詞", "auxiliary"],
  ["一般", "general"],
]);

const INFL_MAP = new Map([
  ["連用形", "continuative"],
  ["終止形", "conclusive"],
  ["連体形", "attributive"],
  ["仮定形", "conditional"],
  ["命令形", "imperative"],
  ["未然形", "irrealis"],
  ["已然形", "realis"],
  ["意志推量形", "volitional_tentative"],
  ["語幹", "word_stem"],
  ["一般", "general"],
  ["融合", "integrated"],
  ["長音", "long_sound"],
  ["促音便", "euphonic_change_t"],
  ["撥音便", "euphonic_change_n"],
  ["ウ音便", "euphonic_change_u"],
  ["イ音便", "euphonic_change_i"],
  ["省略", "abbreviation"],
  ["補助", "auxiliary_inflection"],
  ["ト", "change_to"],
  ["ニ", "change_ni"],
  ["セ", "se"],
  ["サ", "sa"],
  ["*", "uninflected"],
]);

function translateDashed(raw, map) {
  if (!raw) return null;
  const parts = raw.split("-");
  return parts.map((k) => map.get(k) ?? k).join("-");
}

// ---------------------------------------------------------------------------
// MeCab parsing
// ---------------------------------------------------------------------------

function katakanaToHiragana(s) {
  return s.replace(/[ァ-ヶ]/g, (c) =>
    String.fromCharCode(c.charCodeAt(0) - 0x60)
  );
}

// POS top-level categories that are purely grammatical
const GRAMMAR_POS_PREFIXES = ["助詞", "助動詞", "補助記号", "記号"];

// Lemmas that are grammatical despite having a content-word POS
const GRAMMAR_LEMMAS = new Set(["無い", "ない"]);

function isContentWord(posJa, lemma) {
  if (GRAMMAR_POS_PREFIXES.some((p) => posJa.startsWith(p))) return false;
  if (GRAMMAR_LEMMAS.has(lemma)) return false;
  return true;
}

function parseMecabLine(raw) {
  const fields = raw.split("\t");
  if (fields.length < 5) return null;
  const [literal, pronunciation, lemmaReading, lemma, posRaw, inflTypeRaw, inflRaw] = fields;
  const posJa = posRaw || "";
  const inflectionTypeJa = inflTypeRaw || null;
  const inflectionJa = inflRaw || null;
  return { literal, pronunciation, lemmaReading, lemma, posJa, inflectionTypeJa, inflectionJa };
}

function runMecab(sentence, userDictionary = null) {
  const dictFlag = userDictionary ? ` -u ${JSON.stringify(userDictionary)}` : "";
  const raw = execSync(`echo ${JSON.stringify(sentence)} | mecab${dictFlag}`, {
    encoding: "utf8",
  });
  const morphemes = [];
  for (const line of raw.split("\n")) {
    if (!line || line === "EOS") continue;
    const parsed = parseMecabLine(line);
    if (parsed) morphemes.push(parsed);
  }
  return morphemes;
}

function buildMorphemeObjects(rawMorphemes) {
  return rawMorphemes.map((m) => {
    const pos = translateDashed(m.posJa, POS_MAP);
    const inflectionType = m.inflectionTypeJa
      ? translateDashed(m.inflectionTypeJa, INFL_TYPE_MAP)
      : null;
    const inflection = m.inflectionJa
      ? translateDashed(m.inflectionJa, INFL_MAP)
      : null;

    const obj = {
      literal: m.literal,
      pronunciation: m.pronunciation,
      pronunciationHiragana: katakanaToHiragana(m.pronunciation),
      lemmaReading: m.lemmaReading,
      lemmaReadingHiragana: katakanaToHiragana(m.lemmaReading),
      lemma: m.lemma,
      pos,
      posJa: m.posJa,
    };
    if (inflectionType) {
      obj.inflectionType = inflectionType;
      obj.inflectionTypeJa = m.inflectionTypeJa;
    }
    if (inflection) {
      obj.inflection = inflection;
      obj.inflectionJa = m.inflectionJa;
    }

    const isContent = isContentWord(m.posJa, m.lemma);
    obj.isContentWord = isContent;


    return obj;
  });
}

// ---------------------------------------------------------------------------
// Markdown filtering (same logic as filter-for-annotation.mjs)
// ---------------------------------------------------------------------------

function isJapaneseLine(line) {
  if (/^\s*\[.*\]\s*$/.test(line)) return false;
  return /[぀-鿿]/.test(line);
}

function stripRuby(line) {
  let r = line.replace(/<rp>[^<]*<\/rp>/g, "");
  r = r.replace(/<rt>[^<]*<\/rt>/g, "");
  r = r.replace(/<\/?ruby>/g, "");
  return r;
}

function rubyToAnnotated(line) {
  let r = line.replace(/<rp>[^<]*<\/rp>/g, "");
  r = r.replace(/<ruby>([^<]*)<rt>([^<]*)<\/rt><\/ruby>/g, "$1[$2]");
  r = r.replace(/<\/?ruby>/g, "");
  return r;
}

// ---------------------------------------------------------------------------
// Exhaustive compound candidate search
// ---------------------------------------------------------------------------

const MAX_COMPOUND_SPAN = 5;
const COMPOUND_LIMIT = 20; // max dictionary hits per search variant

const tokenize = (s) => s.split("").join(" ");

function forkingPaths(arrays) {
  let result = [[]];
  for (const choices of arrays) {
    result = choices.flatMap((choice) => result.map((path) => [...path, choice]));
  }
  return result;
}

function hasKanji(s) {
  return /[一-鿿㐀-䶿]/.test(s);
}

function isParticleMorpheme(m) {
  return m.pos?.startsWith("particle");
}

/**
 * For a span of morphemes, produce the set of search strings to try.
 * Returns { readingSearches: string[], kanjiSearches: string[] }.
 *
 * Reading searches: cartesian product of (pronunciationHiragana, lemmaReadingHiragana) per morpheme.
 * Kanji searches: cartesian product of (literal, lemma) per morpheme, filtered to kanji-containing strings.
 * Particle-skipped reading: same as reading searches but with particle morphemes removed from the span.
 */
function spanSearchStrings(span) {
  // Per-morpheme reading alternatives: pronunciation + lemma reading (deduplicated).
  // Particles use their literal (orthographic) form, not pronunciationHiragana, because
  // dictionary entries spell は/へ/を as written — は is pronounced わ but appears as は
  // in compound headwords like おなかがへる.
  const readingChoices = span.map((m) => {
    if (isParticleMorpheme(m)) return [m.literal];
    const forms = [m.pronunciationHiragana];
    if (m.lemmaReadingHiragana !== m.pronunciationHiragana) {
      forms.push(m.lemmaReadingHiragana);
    }
    return [...new Set(forms)];
  });

  // Per-morpheme kanji alternatives: literal + lemma (deduplicated, kept only if kanji-containing)
  const kanjiChoices = span.map((m) => {
    return [...new Set([m.literal, m.lemma])];
  });

  const readingSearches = forkingPaths(readingChoices).map((parts) =>
    parts.join("")
  );

  const kanjiSearches = forkingPaths(kanjiChoices)
    .map((parts) => parts.join(""))
    .filter(hasKanji);

  // Particle-stripped reading: remove particle morphemes and punctuation (empty
  // pronunciation) to prevent collapsed queries that over-match short entries.
  const contentMorphemes = span.filter((m) => !isParticleMorpheme(m) && m.pronunciationHiragana);
  let particleStrippedSearches = [];
  if (contentMorphemes.length >= 2 && contentMorphemes.length < span.length) {
    const strippedChoices = contentMorphemes.map((m) => {
      const forms = [m.pronunciationHiragana];
      if (m.lemmaReadingHiragana !== m.pronunciationHiragana) {
        forms.push(m.lemmaReadingHiragana);
      }
      return [...new Set(forms)];
    });
    particleStrippedSearches = forkingPaths(strippedChoices).map((parts) =>
      parts.join("")
    );
  }

  return {
    readingSearches: [...new Set(readingSearches)],
    kanjiSearches: [...new Set(kanjiSearches)],
    particleStrippedSearches: [...new Set(particleStrippedSearches)],
  };
}

function runFts5Query(db, table, query) {
  try {
    return db
      .prepare(
        `SELECT entries.entry_json FROM ${table}
         JOIN entries ON ${table}.entry_id = entries.id
         WHERE ${table}.text MATCH ?
         GROUP BY entries.id
         LIMIT ${COMPOUND_LIMIT}`
      )
      .pluck()
      .all(query);
  } catch {
    return [];
  }
}

/**
 * For every position in the morpheme array, search JMDict for all matching entries —
 * both single-morpheme exact matches (for content words) and multi-morpheme prefix
 * matches (for compounds, phrases, idioms).
 *
 * Returns a flat array of hits sorted start-ascending then end-descending, so the
 * longest span at each position appears first. The LLM reads this array and selects
 * the best non-overlapping coverage without needing to call lookup.mjs.
 *
 * Deduplication is per (start, wordId): the same dictionary entry can appear at two
 * different start positions (word used twice in a sentence), but is deduplicated
 * within a single start position across multiple search paths.
 *
 * Multi-morpheme search strategies per span:
 *   1. Full span reading — cartesian product of (pronunciationHiragana, lemmaReadingHiragana)
 *      per morpheme; particles use literal (orthographic) form to avoid は→わ artifacts
 *   2. Full span kanji — cartesian product of (literal, lemma), filtered to kanji-containing
 *   3. Particle-stripped reading — same as (1) but particle morphemes removed from span,
 *      catching entries like おなかがへる from the span [おなか, が, へる]
 */
function buildSentenceHits(morphemes, jmdict, tags) {
  const exactStmt = jmdict.prepare(`
    SELECT entries.entry_json FROM raws
    JOIN entries ON raws.entry_id = entries.id
    WHERE raws.text = ?
    GROUP BY entries.id
    LIMIT ${COMPOUND_LIMIT}
  `).pluck();

  const allHits = [];
  // Key: "start-wordId" — deduplicates within a start position, but allows the same
  // word to appear at two different positions (annotated twice if used twice).
  const seen = new Set();

  const addHit = (start, end, word) => {
    const key = `${start}-${word.id}`;
    if (seen.has(key)) return;
    seen.add(key);
    allHits.push({
      start,
      end,
      wordId: word.id,
      forms: wordFormsPart(word),
      meanings: wordMeanings(word, { partOfSpeech: true, numbered: true, tags }),
    });
  };

  for (let start = 0; start < morphemes.length; start++) {
    const m = morphemes[start];

    // Single-morpheme exact lookup for content words
    if (m.isContentWord) {
      const searches = [...new Set([m.literal, m.lemma, m.pronunciationHiragana, m.lemmaReadingHiragana])];
      for (const search of searches) {
        for (const row of exactStmt.all(search)) {
          addHit(start, start + 1, JSON.parse(row));
        }
      }
    }

    // Multi-morpheme span prefix lookups — only start at content words so that
    // non-content morphemes (particles, punctuation) cannot anchor a span.
    // They can still appear in the middle of a span started by a content word.
    if (!m.isContentWord) continue;
    for (
      let end = Math.min(morphemes.length, start + MAX_COMPOUND_SPAN);
      end > start + 1;
      end--
    ) {
      const span = morphemes.slice(start, end);
      const { readingSearches, kanjiSearches, particleStrippedSearches } = spanSearchStrings(span);

      for (const search of readingSearches) {
        for (const row of runFts5Query(jmdict, "kanas", `^"${tokenize(search)}"`)) {
          addHit(start, end, JSON.parse(row));
        }
      }
      for (const search of kanjiSearches) {
        for (const row of runFts5Query(jmdict, "kanjis", `^"${tokenize(search)}"`)) {
          addHit(start, end, JSON.parse(row));
        }
      }
      for (const search of particleStrippedSearches) {
        for (const row of runFts5Query(jmdict, "kanas", `^"${tokenize(search)}"`)) {
          addHit(start, end, JSON.parse(row));
        }
      }
    }
  }

  // Sort: start ascending, then end descending (longest span first within each position)
  allHits.sort((a, b) => a.start !== b.start ? a.start - b.start : b.end - a.end);
  return allHits;
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const [, , subcommand, arg, ...restArgs] = process.argv;

if (!subcommand || (!arg && subcommand !== "help")) {
  console.error(
    "Usage:\n" +
      "  node annotate-harness.mjs full  <file.md>  [work options]  — start + work + done in one step\n" +
      "  node annotate-harness.mjs start <file.md>  [--mecab-user-dictionary /path/to/user.dic]  — create work database\n" +
      "  node annotate-harness.mjs work     <work.db>  [--morpheme-budget N] [--max-batches N] [--parallel] [--dry-run]  — annotate in batches\n" +
      "  node annotate-harness.mjs done     <work.db>  [--no-timestamp]  — produce annotated Markdown and vocab-inline-data.json sidecar\n" +
      "  node annotate-harness.mjs reimport <work.db> <annotated.md>  — sync edited Markdown back into the work database"
  );
  process.exit(1);
}

const userDictIdx = restArgs.indexOf("--mecab-user-dictionary");
const userDictionary = userDictIdx !== -1 ? restArgs[userDictIdx + 1] : null;

if (subcommand === "start") {
  const filePath = path.resolve(arg);
  const text = readFileSync(filePath, "utf8");
  const lines = text.split("\n");

  const timestamp = Date.now();
  const basename = path.basename(filePath, path.extname(filePath));
  const workPath = `/tmp/${basename}-annotations-${timestamp}.db`;

  const work = new Database(workPath);
  work.pragma("journal_mode = WAL");
  work.exec(`
    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE sentences (
      id        INTEGER PRIMARY KEY,
      text      TEXT NOT NULL,
      furigana  TEXT,
      morphemes TEXT NOT NULL,
      hits      TEXT NOT NULL DEFAULT '[]',
      annotations TEXT NOT NULL DEFAULT '[]',
      grammar   TEXT NOT NULL DEFAULT '',
      translation TEXT NOT NULL DEFAULT ''
    );
  `);
  work.prepare(`INSERT INTO meta VALUES ('sourceFile', ?)`).run(filePath);
  const insertSentence = work.prepare(
    `INSERT INTO sentences (id, text, furigana, morphemes, hits) VALUES (?, ?, ?, ?, ?)`
  );

  // Print the work DB path immediately so the caller can monitor progress
  // (e.g. watch the row count) while processing continues.
  console.log(workPath);

  const jmdict = new Database(jmdictDbPath, { readonly: true });
  jmdict.pragma("journal_mode = WAL");
  const tags = JSON.parse(jmdict.prepare(`SELECT value_json FROM metadata WHERE key = 'tags'`).pluck().get() ?? "{}");

  const seen = new Set();
  let inFrontmatter = false;
  let processed = 0;

  // Wrap each insert in its own transaction — this commits to disk after every
  // sentence rather than buffering everything in memory until the end.
  // For a novel this makes the file immediately visible and Ctrl-C safe.
  const insertOne = work.transaction((id, text, furigana, morphemes, hits) => {
    insertSentence.run(id, text, furigana, JSON.stringify(morphemes, null, 2), JSON.stringify(hits));
  });

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (i === 0 && line.trim() === "---") { inFrontmatter = true; continue; }
    if (inFrontmatter && line.trim() === "---") { inFrontmatter = false; continue; }
    if (inFrontmatter) continue;
    if (!isJapaneseLine(line)) continue;
    if (seen.has(line)) continue;
    seen.add(line);

    const hasRuby = /<ruby>/.test(line);
    const stripped = stripRuby(line);
    const rawMorphemes = runMecab(stripped, userDictionary);
    const morphemes = buildMorphemeObjects(rawMorphemes);
    const hits = buildSentenceHits(morphemes, jmdict, tags);
    const furigana = hasRuby ? rubyToAnnotated(line) : null;

    insertOne(i, stripped, furigana, morphemes, hits);
    processed++;
    if (processed % 50 === 0) process.stderr.write(`${processed} sentences processed…\n`);
  }

  jmdict.close();
  work.close();
  process.stderr.write(`Done — ${processed} sentences written to ${workPath}\n`);
} else if (subcommand === "done") {

  const workPath = path.resolve(arg);
  const work = new Database(workPath, { readonly: true });

  // Add grammar/translation columns if the DB predates their support.
  const cols = work.prepare("PRAGMA table_info(sentences)").all();
  const missingCols = [];
  if (!cols.some((c) => c.name === "grammar")) missingCols.push("grammar");
  if (!cols.some((c) => c.name === "translation")) missingCols.push("translation");
  if (missingCols.length > 0) {
    // Must reopen read-write to alter schema.
    work.close();
    const rw = new Database(workPath);
    for (const col of missingCols) {
      rw.exec(`ALTER TABLE sentences ADD COLUMN ${col} TEXT NOT NULL DEFAULT ''`);
    }
    rw.close();
    // Reopen read-only.
  }
  const workRo = new Database(workPath, { readonly: true });

  const sourceFile = workRo.prepare(`SELECT value FROM meta WHERE key = 'sourceFile'`).pluck().get();
  const rows = workRo.prepare(`SELECT id, annotations, grammar, translation FROM sentences`).all();
  workRo.close();

  const sourceText = readFileSync(sourceFile, "utf8");
  const lines = sourceText.split("\n");

  const annotationMap = new Map(rows.map((r) => [r.id, JSON.parse(r.annotations)]));
  const grammarMap = new Map(rows.filter((r) => r.grammar).map((r) => [r.id, r.grammar]));
  const translationMap = new Map(rows.filter((r) => r.translation).map((r) => [r.id, r.translation]));

  const outputLines = [];
  for (let i = 0; i < lines.length; i++) {
    outputLines.push(lines[i]);
    const translation = translationMap.get(i);
    const grammar = grammarMap.get(i);
    const entries = annotationMap.get(i);
    // Canonical order: Translation block, then Grammar block, then Vocab block.
    if (translation) {
      for (const translationLine of translation.split("\n")) outputLines.push(translationLine);
    }
    if (grammar) {
      for (const grammarLine of grammar.split("\n")) outputLines.push(grammarLine);
    }
    if (entries && entries.length > 0) {
      outputLines.push("<details><summary>Vocab</summary>");
      for (const entry of entries) {
        // Bare strings are "Not in JMDict:" and "Proper noun:" annotations.
        const displayString = typeof entry === "string" ? entry : entry.form;
        outputLines.push(displayString.startsWith("- ") ? displayString : `- ${displayString}`);
      }
      outputLines.push("</details>");
    }
  }

  const overwrite = restArgs.includes("--no-timestamp");
  const sourceDir = path.dirname(sourceFile);
  const sourceBase = path.basename(sourceFile, path.extname(sourceFile));
  const outputSuffix = overwrite ? "" : `.${Date.now()}`;
  const outputPath = path.join(sourceDir, `${sourceBase}.annotated${outputSuffix}.md`);

  writeFileSync(outputPath, outputLines.join("\n"), "utf8");

  const annotated = rows.filter((r) => JSON.parse(r.annotations).length > 0).length;
  console.log(`Wrote ${outputPath} — ${annotated}/${rows.length} sentences annotated`);

  {
    // Collect unique wordIds for BCCWJ frequency lookup.
    const wordIds = new Set();
    for (const [, entries] of annotationMap) {
      for (const entry of entries) {
        if (typeof entry === "object" && entry.wordId) wordIds.add(entry.wordId);
      }
    }

    {
      // Look up BCCWJ frequency for each word using the best-matching kanji/reading pair.
      const bccwjPath = path.join(scriptDir, "bccwj.sqlite");
      let bccwjDb = null;
      try {
        bccwjDb = new Database(bccwjPath, { readonly: true });
      } catch {
        // bccwj.sqlite absent — frequency will be omitted
      }
      const bccwjOverrides = JSON.parse(
        readFileSync(path.join(scriptDir, "bccwj-overrides.json"), "utf8"),
      ).overrides;
      const jmdictDb = new Database(jmdictDbPath, { readonly: true });
      const entryQuery = jmdictDb.prepare("SELECT entry_json FROM entries WHERE id = ?");
      const bccwjQuery = bccwjDb
        ? bccwjDb.prepare("SELECT pmw FROM bccwj WHERE kanji = ? AND reading = ? LIMIT 1")
        : null;

      // words: per-wordId BCCWJ frequency only (sense_indices are per-occurrence, stored in sentences).
      const words = {};
      for (const wordId of wordIds) {
        const row = entryQuery.get(wordId);
        let bccwjPerMillionWords = null;
        if (row && bccwjQuery) {
          const entry = JSON.parse(row.entry_json);
          const kanjiTexts = (entry.kanji ?? []).map((k) => k.text);
          const readingTexts = (entry.kana ?? []).map((k) => k.text);
          let pairs = kanjiTexts.length > 0
            ? kanjiTexts.flatMap((k) => readingTexts.map((r) => [k, r]))
            : readingTexts.map((r) => [r, r]);
          const override = bccwjOverrides[wordId];
          if (override) pairs = [[override.kanji, override.reading], ...pairs];
          for (const [kanji, reading] of pairs) {
            const hit = bccwjQuery.get(kanji, reading);
            if (hit && (bccwjPerMillionWords === null || hit.pmw > bccwjPerMillionWords)) {
              bccwjPerMillionWords = hit.pmw;
            }
          }
        }
        if (bccwjPerMillionWords !== null) words[wordId] = { bccwjPerMillionWords };
      }

      jmdictDb.close();
      if (bccwjDb) bccwjDb.close();

      // sentences: full per-occurrence annotation arrays keyed by sentence ID.
      // Used by reimport (to restore annotations) and annotate-vocab-inline
      // (for per-occurrence sense_indices rather than aggregated ones).
      const sentences = Object.fromEntries(
        [...annotationMap.entries()]
          .filter(([, entries]) => entries.length > 0)
          .map(([id, entries]) => [id, entries])
      );
      const sidecarPath = outputPath.replace(/\.md$/, ".vocab-inline-data.json");
      writeFileSync(sidecarPath, JSON.stringify({ sentences, words }, null, 2), "utf8");
      console.log(`Wrote ${sidecarPath} — ${wordIds.size} words in sidecar`);
    }
  }
} else if (subcommand === "reimport") {
  // Re-read an edited annotated Markdown (and its sidecar) back into the work
  // database. Enables the edit loop:
  //   done → edit annotated.md / vocab-inline-data.json → reimport → work more → done
  //
  // Usage: node annotate-harness.mjs reimport <work.db> <annotated.md>
  //
  // The sidecar (<annotated.vocab-inline-data.json>) stores the full annotation
  // objects keyed by sentence ID. reimport looks up unchanged bullets there by
  // form string; only genuinely new/changed bullets need JMDict resolution.

  const { existsSync: fsExistsSync } = await import("fs");
  const { setup, idsToWords } = await import("jmdict-simplified-node");
  const { extractJapaneseTokens, resolveTokensToIds, JMDICT_DB } = await import("./.claude/scripts/shared.mjs");

  const annotatedPath = path.resolve(restArgs[0] ?? "");
  if (!annotatedPath || !fsExistsSync(annotatedPath)) {
    console.error("Usage: node annotate-harness.mjs reimport <work.db> <annotated.md>");
    process.exit(1);
  }

  const workPath = path.resolve(arg);
  const work = new Database(workPath);

  // Load sidecar. It contains:
  //   sentences: { [sentenceId]: annotation[] }  — full objects, for reimport
  //   words:     { [wordId]: { sense_indices, bccwjPerMillionWords } }
  const sidecarPath = annotatedPath.replace(/\.md$/, ".vocab-inline-data.json");
  // form string → annotation object, built from sidecar sentences
  const formToAnnotation = new Map();
  // wordId → sense_indices from edited words section (user may have tweaked these)
  const sidecarWordSenses = new Map();
  const knownBareStrings = new Set(); // bare strings from sidecar → pass through without JMDict
  if (fsExistsSync(sidecarPath)) {
    const sidecar = JSON.parse(readFileSync(sidecarPath, "utf8"));
    for (const entries of Object.values(sidecar.sentences ?? {})) {
      for (const entry of entries) {
        if (typeof entry === "object" && entry.form) {
          formToAnnotation.set(entry.form, entry);
        } else if (typeof entry === "string") {
          knownBareStrings.add(entry);
        }
      }
    }
    for (const [wordId, data] of Object.entries(sidecar.words ?? {})) {
      if (Array.isArray(data.sense_indices)) sidecarWordSenses.set(wordId, data.sense_indices);
    }
    console.log(`Loaded sidecar: ${formToAnnotation.size} known annotations, ${knownBareStrings.size} known bare strings, ${sidecarWordSenses.size} words`);
  } else {
    console.log("No sidecar found — all bullets will be resolved via JMDict");
  }

  // Build a map from stripped sentence text → sentence id for matching.
  const rows = work.prepare("SELECT id, text FROM sentences").all();
  const textToId = new Map(rows.map((r) => [r.text.trim(), r.id]));

  // Set up JMDict for resolving genuinely new/changed form strings.
  const { db: jmdictNode } = await setup(JMDICT_DB);

  function resolveFormToWordId(formString) {
    const tokens = extractJapaneseTokens(formString);
    if (tokens.length === 0) return null;
    const matchIds = resolveTokensToIds(jmdictNode, tokens);
    if (matchIds.length !== 1) return null;
    return matchIds[0];
  }

  // Parse the annotated Markdown line-by-line.
  const annotatedLines = readFileSync(annotatedPath, "utf8").split("\n");

  const vocabUpdates = new Map(); // sentenceId → annotation array
  const grammarUpdates = new Map(); // sentenceId → verbatim grammar block string
  const translationUpdates = new Map(); // sentenceId → verbatim translation block string
  const presentIds = new Set(); // sentence IDs that appeared in the annotated file

  // State machine: idle → vocab, grammar, or translation → idle, cycling per
  // sentence. 'idle' with currentSentenceId set means we're between consecutive
  // blocks (any combination of translation/grammar/vocab) for the same sentence.
  let state = "idle"; // "idle" | "vocab" | "grammar" | "translation"
  let currentSentenceId = null;
  let currentBullets = [];
  let currentGrammarLines = []; // raw lines including opening/closing tags
  let currentTranslationLines = []; // raw lines including opening/closing tags

  function flushSentence() {
    if (currentSentenceId !== null) {
      presentIds.add(currentSentenceId);
      if (currentBullets.length > 0) vocabUpdates.set(currentSentenceId, currentBullets);
      if (currentGrammarLines.length > 0) {
        grammarUpdates.set(currentSentenceId, currentGrammarLines.join("\n"));
      }
      if (currentTranslationLines.length > 0) {
        translationUpdates.set(currentSentenceId, currentTranslationLines.join("\n"));
      }
    }
    currentBullets = [];
    currentGrammarLines = [];
    currentTranslationLines = [];
    currentSentenceId = null;
  }

  function matchSentenceFromPrevLine(li) {
    const prevLine = li > 0 ? annotatedLines[li - 1] : "";
    const strippedPrev = stripRuby(prevLine).trim();
    const id = textToId.get(strippedPrev) ?? null;
    if (id === null) console.warn(`  Warning: could not match sentence: ${strippedPrev.slice(0, 60)}`);
    return id;
  }

  for (let li = 0; li < annotatedLines.length; li++) {
    const line = annotatedLines[li];
    const trimmed = line.trim();

    if (state === "idle") {
      const isVocab = /<details[^>]*>/.test(line) && /<summary[^>]*>\s*Vocab\s*<\/summary>/.test(line);
      const isGrammar = /<details[^>]*>/.test(line) && /<summary[^>]*>\s*Grammar\s*<\/summary>/.test(line);
      const isTranslation = /<details[^>]*>/.test(line) && /<summary[^>]*>\s*Translation\s*<\/summary>/.test(line);

      if (isVocab || isGrammar || isTranslation) {
        // If no current sentence, identify it from the preceding line.
        // If we already have one (second consecutive block), reuse it.
        if (currentSentenceId === null) {
          currentSentenceId = matchSentenceFromPrevLine(li);
        }
        if (isGrammar) {
          // Compact one-liner: entire block on one line — store verbatim and stay idle.
          if (/<\/details\b/.test(line)) {
            currentGrammarLines = [line];
          } else {
            state = "grammar";
            currentGrammarLines = [line];
          }
        } else if (isTranslation) {
          if (/<\/details\b/.test(line)) {
            currentTranslationLines = [line];
          } else {
            state = "translation";
            currentTranslationLines = [line];
          }
        } else {
          state = "vocab";
        }
      } else if (currentSentenceId !== null) {
        // Non-details line while holding a sentence context — flush and process normally.
        flushSentence();
      }
      continue;
    }

    if (state === "grammar") {
      currentGrammarLines.push(line);
      if (/<\/details\b/.test(line)) state = "idle";
      continue;
    }

    if (state === "translation") {
      currentTranslationLines.push(line);
      if (/<\/details\b/.test(line)) state = "idle";
      continue;
    }

    // state === "vocab"
    if (/<\/details\b/.test(line)) {
      state = "idle";
      continue;
    }

    if (trimmed.startsWith("-")) {
      const bullet = trimmed.slice(1).trim();
      if (!bullet) continue;

      // Bare-string annotations pass through unchanged.
      if (bullet.startsWith("Not in JMDict:") || bullet.startsWith("Proper noun:")) {
        currentBullets.push(bullet);
        continue;
      }

      // Known bare strings from the sidecar (e.g. multi-form entries the LLM
      // stored without a wordId) pass through without JMDict resolution.
      if (knownBareStrings.has(bullet)) {
        currentBullets.push(bullet);
        continue;
      }

      // Check sidecar first — covers unchanged bullets without needing JMDict.
      const known = formToAnnotation.get(bullet);
      if (known) {
        // Use sidecar's sense_indices unless the user edited the words section.
        const sense_indices = sidecarWordSenses.get(known.wordId) ?? known.sense_indices;
        currentBullets.push({ ...known, sense_indices });
        continue;
      }

      // Word ID prefix (e.g. "1631640" or "1198910 とける 解ける") — resolve directly.
      // Users prepend the JMDict ID to disambiguate bullets that matched multiple entries.
      const directIdMatch = bullet.match(/^(\d+)(\s|$)/);
      if (directIdMatch) {
        const wordId = directIdMatch[1];
        const [jmWord] = idsToWords(jmdictNode, [wordId]);
        if (!jmWord) {
          console.warn(`  Warning: wordId ${wordId} not found in JMDict — storing as bare string`);
          currentBullets.push(bullet);
          continue;
        }
        // Preserve the user's ID-prefixed bullet as form so done emits it back
        // unchanged and future reimports find it in the sidecar by form string.
        const sense_indices = sidecarWordSenses.get(wordId) ?? [0];
        currentBullets.push({ form: bullet, wordId, sense_indices });
        continue;
      }

      // New or changed bullet — resolve via JMDict.
      const wordId = resolveFormToWordId(bullet);
      if (wordId === null) {
        console.warn(`  Warning: could not resolve "${bullet}" to a JMDict entry — storing as bare string`);
        currentBullets.push(bullet);
        continue;
      }
      const sense_indices = sidecarWordSenses.get(wordId) ?? [0];
      currentBullets.push({ form: bullet, wordId, sense_indices });
    }
  }
  flushSentence(); // flush any trailing sentence context at end of file

  // Migrate grammar/translation columns for DBs that predate their support.
  const existingCols = work.prepare("PRAGMA table_info(sentences)").all();
  if (!existingCols.some((c) => c.name === "grammar")) {
    work.exec("ALTER TABLE sentences ADD COLUMN grammar TEXT NOT NULL DEFAULT ''");
  }
  if (!existingCols.some((c) => c.name === "translation")) {
    work.exec("ALTER TABLE sentences ADD COLUMN translation TEXT NOT NULL DEFAULT ''");
  }

  // Write updates back. Only sentences present in the annotated file are touched.
  // Sentences not in the file are left as-is (still unannotated for further work).
  const updateStmt = work.prepare("UPDATE sentences SET annotations = ?, grammar = ?, translation = ? WHERE id = ?");
  const updateAll = work.transaction(() => {
    for (const id of presentIds) {
      const annotations = vocabUpdates.get(id) ?? [];
      const grammar = grammarUpdates.get(id) ?? "";
      const translation = translationUpdates.get(id) ?? "";
      updateStmt.run(JSON.stringify(annotations), grammar, translation, id);
    }
  });
  updateAll();
  work.close();

  console.log(`Reimported ${presentIds.size} sentences into ${workPath} (${vocabUpdates.size} with vocab, ${grammarUpdates.size} with grammar, ${translationUpdates.size} with translation)`);
  const notPresent = rows.length - presentIds.size;
  if (notPresent > 0) {
    console.log(`  (${notPresent} sentences not in annotated file — left untouched for further work)`);
  }

} else if (subcommand === "work" || subcommand === "full") {
  // `work` expects an existing work.db; `full` creates one first from a .md file.
  let workDb;
  if (subcommand === "full") {
    const filePath = arg;
    console.log(`Creating work database for ${filePath} …`);
    workDb = execSync(
      `node ${process.argv[1]} start ${JSON.stringify(filePath)}`,
      { encoding: "utf8" }
    ).trim();
    console.log(`Work database: ${workDb}`);
  } else {
    workDb = path.resolve(arg);
    console.log(`Work database: ${workDb}`);
  }

  // Parse work options from restArgs (or process.argv for full).
  const workArgs = subcommand === "full"
    ? restArgs  // restArgs already excludes subcommand and arg
    : restArgs;

  function getWorkFlag(name) {
    const i = workArgs.indexOf(name);
    return i === -1 ? undefined : workArgs[i + 1];
  }
  const morphemeBudget = parseInt(getWorkFlag("--morpheme-budget") ?? "400", 10);
  const maxBatches = getWorkFlag("--max-batches") !== undefined
    ? parseInt(getWorkFlag("--max-batches"), 10)
    : Infinity;
  const parallel = workArgs.includes("--parallel");
  const dryRun = workArgs.includes("--dry-run");

  // Build batches from unannotated sentences.
  const db = new Database(workDb, { readonly: true });
  const sentences = db
    .prepare(
      `SELECT id, json_array_length(morphemes) AS morpheme_count
       FROM sentences WHERE annotations = '[]' ORDER BY id`
    )
    .all();
  db.close();

  if (sentences.length === 0) {
    console.log("All sentences already annotated — running done …");
    execSync(`node ${process.argv[1]} done ${JSON.stringify(workDb)}`, { stdio: "inherit" });
    process.exit(0);
  }

  // Greedy bin: accumulate until budget exceeded, then start a new batch.
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

  function runBatch(batch, batchIndex) {
    const fromId = batch[0].id;
    const toId = batch[batch.length - 1].id;
    const prompt = `/annotate-file "${workDb} ${fromId} ${toId}"`;
    console.log(`\nBatch ${batchIndex + 1}: claude -p '${prompt}'`);
    return new Promise((resolve, reject) => {
      const child = spawn(
        "claude",
        [
          "-p", prompt,
          "--allowedTools", `Bash(sqlite3 ${workDb} *)`,
          "--add-dir", path.dirname(workDb),
        ],
        { stdio: "inherit" }
      );
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

  console.log("\nFinalizing …");
  execSync(`node ${process.argv[1]} done ${JSON.stringify(workDb)}`, { stdio: "inherit" });
} else {
  console.error(`Unknown subcommand: ${subcommand}. Use start, work, done, or full.`);
  process.exit(1);
}
