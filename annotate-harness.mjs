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

import { execSync } from "child_process";
import { readFileSync, writeFileSync } from "fs";
import Database from "better-sqlite3";
import path from "path";
import { wordFormsPart, wordMeanings } from "./.claude/scripts/shared.mjs";

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

function runMecab(sentence) {
  const raw = execSync(`echo ${JSON.stringify(sentence)} | mecab`, {
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

  // Particle-stripped reading: remove particle morphemes, keep content morphemes only
  const contentMorphemes = span.filter((m) => !isParticleMorpheme(m));
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

    // Multi-morpheme span prefix lookups
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

const [, , subcommand, arg] = process.argv;

if (!subcommand || !arg) {
  console.error(
    "Usage:\n" +
      "  node annotate-harness.mjs start <file.md>  — create work database\n" +
      "  node annotate-harness.mjs done  <work.db>  — produce annotated Markdown"
  );
  process.exit(1);
}

if (subcommand === "start") {
  const filePath = path.resolve(arg);
  const text = readFileSync(filePath, "utf8");
  const lines = text.split("\n");

  const jmdict = new Database("jmdict.sqlite", { readonly: true });
  jmdict.pragma("journal_mode = WAL");
  const tags = JSON.parse(jmdict.prepare(`SELECT value_json FROM metadata WHERE key = 'tags'`).pluck().get() ?? "{}");

  const seen = new Set();
  let inFrontmatter = false;
  const sentences = [];

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
    const rawMorphemes = runMecab(stripped);
    const morphemes = buildMorphemeObjects(rawMorphemes);
    const hits = buildSentenceHits(morphemes, jmdict, tags);

    const entry = { id: i, text: stripped, morphemes, hits };
    if (hasRuby) entry.furigana = rubyToAnnotated(line);
    sentences.push(entry);
  }

  jmdict.close();

  const timestamp = Date.now();
  const basename = path.basename(filePath, path.extname(filePath));
  const workPath = `/tmp/${basename}-annotations-${timestamp}.db`;

  const work = new Database(workPath);
  work.exec(`
    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE sentences (
      id        INTEGER PRIMARY KEY,
      text      TEXT NOT NULL,
      furigana  TEXT,
      morphemes TEXT NOT NULL,
      hits      TEXT NOT NULL DEFAULT '[]',
      annotations TEXT NOT NULL DEFAULT '[]'
    );
  `);

  work.prepare(`INSERT INTO meta VALUES ('sourceFile', ?)`).run(filePath);

  const insertSentence = work.prepare(
    `INSERT INTO sentences (id, text, furigana, morphemes, hits) VALUES (?, ?, ?, ?, ?)`
  );
  const insertAll = work.transaction((rows) => {
    for (const s of rows) {
      insertSentence.run(
        s.id,
        s.text,
        s.furigana ?? null,
        JSON.stringify(s.morphemes, null, 2),
        JSON.stringify(s.hits)
      );
    }
  });
  insertAll(sentences);
  work.close();

  console.log(workPath);
} else if (subcommand === "done") {
  const workPath = path.resolve(arg);
  const work = new Database(workPath, { readonly: true });

  const sourceFile = work.prepare(`SELECT value FROM meta WHERE key = 'sourceFile'`).pluck().get();
  const rows = work.prepare(`SELECT id, annotations FROM sentences`).all();
  work.close();

  const sourceText = readFileSync(sourceFile, "utf8");
  const lines = sourceText.split("\n");

  const annotationMap = new Map(
    rows.map((r) => [r.id, JSON.parse(r.annotations)])
  );

  const outputLines = [];
  for (let i = 0; i < lines.length; i++) {
    outputLines.push(lines[i]);
    const entries = annotationMap.get(i);
    if (entries && entries.length > 0) {
      outputLines.push("<details><summary>Vocab</summary>");
      for (const entry of entries) {
        outputLines.push(entry.startsWith("- ") ? entry : `- ${entry}`);
      }
      outputLines.push("</details>");
    }
  }

  const timestamp = Date.now();
  const sourceDir = path.dirname(sourceFile);
  const sourceBase = path.basename(sourceFile, path.extname(sourceFile));
  const outputPath = path.join(sourceDir, `${sourceBase}.annotated.${timestamp}.md`);

  writeFileSync(outputPath, outputLines.join("\n"), "utf8");

  const annotated = rows.filter((r) => JSON.parse(r.annotations).length > 0).length;
  console.log(`Wrote ${outputPath} — ${annotated}/${rows.length} sentences annotated`);
} else {
  console.error(`Unknown subcommand: ${subcommand}. Use "start" or "done".`);
  process.exit(1);
}
