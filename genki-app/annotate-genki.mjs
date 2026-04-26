/**
 * Genki Vocabulary Annotator
 *
 * Automatically adds JMDict vocabulary annotations to Genki lesson files.
 *
 * These files contain vocabulary items from the Genki 1 and Genki 2 Japanese
 * textbooks (original source: Genki app). Each section (## heading) represents
 * a vocabulary entry with a Japanese term and optional reading in parentheses,
 * followed by example sentences and English translations.
 *
 * This script looks up each vocabulary heading in JMDict and adds a structured
 * <details> block with vocabulary metadata in a format compatible with check-vocab.mjs:
 *
 *   <details><summary>Vocab</summary>
 *   - 漢字
 *   </details>
 *
 * For complex entries (verb phrases, compound words, conjugations), the script uses
 * manual overrides to decompose them into their component vocabulary:
 *
 *   薬を飲む → 薬, 飲む
 *   知っています → 知る
 *   熱がある → 熱, ある
 *
 * USAGE:
 *   cd /path/to/repo && node genki-app/annotate-genki.mjs <relative-path>
 *
 * EXAMPLES:
 *   node genki-app/annotate-genki.mjs genki-app/L13.md
 *   node genki-app/annotate-genki.mjs genki-app/L07.md
 *   node genki-app/annotate-genki.mjs genki-app/L01.md --add-frontmatter
 *
 * OPTIONS:
 *   --add-frontmatter    Add "llm-review: true" YAML frontmatter if missing
 *
 * OUTPUT:
 *   Writes to <filename>-annotated.md in the same directory
 *   Prints to stdout:
 *     ✓ L13.md: 56/56 sections annotated
 *     (or lists failed terms if any exist)
 *
 * REQUIREMENTS:
 *   - jmdict-simplified-node package
 *   - jmdict.sqlite in project root
 *   - Input file in standard Genki format with ## section headings
 */

import { setup, findExact, findExactIds } from "jmdict-simplified-node";
import { readFileSync, writeFileSync, readdirSync, existsSync } from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Helper: Check if Japanese tokens uniquely identify a single jmdict entry
function isUnambiguous(db, tokens) {
  if (tokens.length === 0) return false;

  const idSets = tokens.map((token) => {
    const ids = findExactIds(db, token);
    return new Set(ids);
  });

  // Intersection of all token ID sets
  let intersection = idSets[0];
  for (let i = 1; i < idSets.length; i++) {
    const newIntersection = new Set();
    for (const id of intersection) {
      if (idSets[i].has(id)) {
        newIntersection.add(id);
      }
    }
    intersection = newIntersection;
  }

  return intersection.size === 1 ? [...intersection][0] : null;
}

// Extract Japanese tokens from a string (before any English/numbers)
function extractJapaneseTokens(str) {
  const result = [];
  for (const token of str.split(/\s+/)) {
    if (token && /^[、。぀-ゟ゠-ヿ一-鿿㐀-䶿豈-﫿々ー。？！]+$/.test(token)) {
      result.push(token);
    } else if (token && !/^[0-9]+$/.test(token)) {
      // Stop at first non-Japanese, non-number token
      break;
    }
  }
  return result;
}

// Manual overrides for complex headings that decompose into multiple vocab items
const overrides = new Map([
  // Conjugations and related forms
  ["知っています（しっています）", ["知る"]],
  ["知りません（しりません）", ["知る"]],
  ["太っています（ふとっています）", ["太る"]],
  ["やせています", ["やせる"]],
  ["遅くなる（おそくなる）", ["遅く", "なる"]],

  // Multi-word phrases - split into components
  ["薬を飲む（くすりをのむ）", ["薬", "飲む"]],
  ["熱がある（ねつがある）", ["熱", "ある"]],
  ["興味がある（きょうみがある）", ["興味", "ある"]],
  ["元気がない（げんきがない）", ["元気", "ない"]],
  ["保険に入る（ほけんにはいる）", ["保険", "入る"]],
  ["お湯を沸かす（おゆをわかす）", ["湯", "沸かす"]],
  ["ひげをそる", ["髭", "剃る"]],
  ["宝くじに当たる（たからくじにあたる）", ["宝くじ", "当たる"]],
  ["お湯が沸く（おゆがわく）", ["湯", "沸く"]],
  ["昼寝をする（ひるねをする）", ["昼寝", "する"]],
  ["風が吹く（かぜがふく）", ["風", "吹く"]],
  ["コピーを取る（コピーをとる）", ["コピー", "取る"]],
  ["雨がやむ（あめがやむ）", ["雨", "やむ"]],

  // Single word phrases (extract main word)
  ["みんなで", ["みんな"]],
  ["残念（ですね）（ざんねん（ですね））", ["残念"]],
  ["楽しみです（たのしみです）", ["楽しみ"]],
  ["授業中に（じゅぎょうちゅうに）", ["授業"]],
  ["ほかの", ["外"]],
  ["～と申します（～ともうします）", ["申し上げる"]],
  ["本当は（ほんとうは）", ["本当"]],
  ["係の者（かかりのもの）", ["係"]],
  ["お疲れ様（でした）（おつかれさま（でした））", ["疲れる"]],
  ["お休みになる（おやすみになる）", ["休む"]],
  ["最後に（さいごに）", ["最後"]],
  ["ものすごく", ["ものすごい"]],

  // Grammar patterns - extract the main word
  ["全然 ＋ negative（ぜんぜん ＋ negative）", ["全然"]],
  ["何も ＋ negative（なにも ＋ negative）", ["何"]],
  ["別に ＋ negative（べつに ＋ negative）", ["別に"]],
  ["まだ ＋ negative", ["まだ"]],
  ["～について", ["就く"]],
  ["～に比べて（～にくらべて）", ["比べる"]],
  ["～ていらっしゃる", ["いらっしゃる"]],
  ["～ておる", ["居る"]],

  // Numbers and time-related
  ["二時半（にじはん）", ["時", "半"]],
  ["今学期（こんがっき）", ["学期"]],

  // Alternatives (pick first)
  ["どっち／どちら", ["どちら"]],

  // Adverbs with readings
  ["歩いて（あるいて）", ["歩く"]],
  ["あまり ＋ negative", ["あまり"]],
  ["そうですか", ["左様"]],
  ["どうですか", ["どう"]],
  ["結構です（けっこうです）", ["結構"]],
  ["本当ですか（ほんとうですか）", ["本当"]],
  ["こんなふう", ["様"]],
  ["多くの～（おおくの～）", ["多い"]],
  ["よろしくお伝えください（よろしくおつたえください）", ["伝える"]],
  ["～顔をする（～かおをする）", ["顔", "する"]],
  ["～度（～ど）", ["度"]],
]);

// Parse command line arguments
const inputFile = process.argv[2];
const addFrontmatter = process.argv.includes("--add-frontmatter");

if (!inputFile) {
  console.error("Usage: node annotate-genki.mjs <input-file> [--add-frontmatter]");
  console.error("Example: node annotate-genki.mjs genki-app/L13.md");
  console.error("         node annotate-genki.mjs genki-app/L01.md --add-frontmatter");
  process.exit(1);
}

// Handle both relative paths (from project root) and local references
let inputPath;
if (inputFile.startsWith("genki-app/") || inputFile.startsWith("./")) {
  inputPath = path.join(__dirname, "..", inputFile);
} else {
  // Assume it's a local filename in genki-app/ directory
  inputPath = path.join(__dirname, inputFile);
}

let content = readFileSync(inputPath, "utf8");

// Handle frontmatter if --add-frontmatter flag is provided
if (addFrontmatter) {
  // Check if file already has frontmatter
  if (!content.startsWith("---")) {
    content = "---\nllm-review: true\n---\n\n" + content;
  }
}

// Find project root by looking for jmdict.sqlite
let projectRoot = __dirname;
while (!existsSync(path.join(projectRoot, "jmdict.sqlite"))) {
  const parent = path.dirname(projectRoot);
  if (parent === projectRoot) break; // Reached filesystem root
  projectRoot = parent;
}

const { db } = await setup(path.join(projectRoot, "jmdict.sqlite"));

// Split into lines
const lines = content.split("\n");

const result = [];
let i = 0;
let totalSections = 0;
let annotatedSections = 0;
const failedTerms = [];

while (i < lines.length) {
  const line = lines[i];

  // Check if this is a section heading
  if (line.startsWith("## ")) {
    totalSections++;
    const heading = line.slice(3).trim();
    result.push(line);

    // Check if there's an override for this heading
    let vocabTerms = []; // Array of {term, id} or just strings for overrides

    if (overrides.has(heading)) {
      // For overrides, look up the ID
      const overrideTerms = overrides.get(heading);
      vocabTerms = overrideTerms.map(term => {
        const results = findExact(db, term);
        if (results.length > 0) {
          return { term, id: results[0].id };
        }
        return { term, id: null };
      });
    } else {
      // Extract the term to look up
      // Simple approach: remove everything in parentheses (both full-width and half-width)
      let cleanHeading = heading.replace(/～/g, "").trim();
      // Remove all parentheses and their content (including nested, handle both full/half-width)
      let prevLength = cleanHeading.length;
      while (cleanHeading.includes("（") || cleanHeading.includes("(")) {
        // Remove full-width and half-width parens with content
        cleanHeading = cleanHeading.replace(/[（(][^（)]*[）)]/g, "").trim();
        // Safety check: if nothing was removed, break to avoid infinite loop
        if (cleanHeading.length === prevLength) break;
        prevLength = cleanHeading.length;
      }
      // Final cleanup of any remaining parens
      cleanHeading = cleanHeading.replace(/[（）()]/g, "").trim();

      // Extract content from all parentheses for additional lookup attempts
      const parenMatches = [...heading.matchAll(/[（][^（）]*[）]/g)];
      const parensContent = parenMatches.map(m => m[0].slice(1, -1));

      // Try to find in jmdict
      let found = null;

      const tryTerms = [];

      // Try the clean heading first
      if (cleanHeading) {
        tryTerms.push(cleanHeading);
        // Also try without する for suru-verbs
        if (cleanHeading.endsWith("する")) {
          tryTerms.push(cleanHeading.slice(0, -2));
        }
      }

      // Try parentheses content in order
      for (const content of parensContent) {
        if (content && content !== cleanHeading) {
          tryTerms.push(content);
          if (content.endsWith("する")) {
            tryTerms.push(content.slice(0, -2));
          }
        }
      }

      // Try each term
      for (const term of tryTerms) {
        const results = findExact(db, term);
        if (results.length > 0) {
          found = results[0];
          break;
        }
      }

      if (found) {
        vocabTerms = [{ word: found, id: found.id }];
      } else {
        failedTerms.push(heading);
      }
    }

    // Add the rest of the section
    i++;
    while (i < lines.length && !lines[i].startsWith("## ")) {
      const contentLine = lines[i];
      result.push(contentLine);

      // If this is the English details block and we have vocab terms, add them
      if (vocabTerms.length > 0 && contentLine.includes("</details>") && !lines[i + 1]?.startsWith("##")) {
        const bullets = [];

        for (const item of vocabTerms) {
          let bullet = null;
          let baseBullet = null; // Without ID prefix

          if (item.word) {
            // From direct jmdict lookup
            const word = item.word;
            const kanji = word.kanji.filter((k) => !k.tags.includes("iK")).map((k) => k.text);
            const kana = word.kana.filter((k) => !k.tags.includes("ik")).map((k) => k.text);
            const reading = kana[0];
            const writing = kanji.length > 0 ? kanji[0] : reading;
            // Format: "reading kanji" or "reading"
            if (reading !== writing) {
              baseBullet = `${reading} ${writing}`;
            } else {
              baseBullet = `${reading}`;
            }

            // Check if this is unambiguous
            const tokens = extractJapaneseTokens(baseBullet);
            const ambiguousId = isUnambiguous(db, tokens);

            if (ambiguousId) {
              // Unambiguous - use bullet without ID
              bullet = `- ${baseBullet}`;
            } else {
              // Ambiguous - add ID prefix
              bullet = `- ${item.id} ${baseBullet}`;
            }
          } else if (item.term) {
            // From override lookup
            if (item.id) {
              // Look up full word info to get reading
              const results = findExact(db, item.term);
              if (results.length > 0) {
                const word = results[0];
                const kanji = word.kanji.filter((k) => !k.tags.includes("iK")).map((k) => k.text);
                const kana = word.kana.filter((k) => !k.tags.includes("ik")).map((k) => k.text);
                const reading = kana[0];
                const writing = kanji.length > 0 ? kanji[0] : reading;
                if (reading !== writing) {
                  baseBullet = `${reading} ${writing}`;
                } else {
                  baseBullet = `${reading}`;
                }

                // Check if unambiguous
                const tokens = extractJapaneseTokens(baseBullet);
                const ambiguousId = isUnambiguous(db, tokens);

                if (ambiguousId) {
                  bullet = `- ${baseBullet}`;
                } else {
                  bullet = `- ${item.id} ${baseBullet}`;
                }
              } else {
                // Fallback if lookup failed - just use ID and term
                bullet = `- ${item.id} ${item.term}`;
              }
            } else {
              // Fallback if ID lookup failed
              bullet = `- ${item.term}`;
            }
          }

          if (bullet) {
            bullets.push(bullet);
          }
        }

        if (bullets.length > 0) {
          const vocabAnnotation = `<details><summary>Vocab</summary>
${bullets.join("\n")}
</details>`;
          result.push(vocabAnnotation);
          annotatedSections++;
        }
        vocabTerms = []; // Mark as added
      }

      i++;
    }
  } else {
    result.push(line);
    i++;
  }
}

// Write output file
const outputPath = inputPath.replace(/\.md$/, "-annotated.md");
writeFileSync(outputPath, result.join("\n"));

// Log statistics
const filename = path.basename(inputFile);
console.log(`✓ ${filename}: ${annotatedSections}/${totalSections} sections annotated`);
if (failedTerms.length > 0) {
  console.log(`  Failed terms: ${failedTerms.join(", ")}`);
}
