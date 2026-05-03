// markdown-ast.mjs
// Markdown-aware primitives that the regex/linear-scan approach in shared.mjs
// previously suffered without (BUGs #1, #3, #4 in docs/TODO-fuzzing.md):
//
//   1. maskCodeRegions(content): use a CommonMark parser to find every code
//      fence and inline code span; replace those bytes with spaces (preserving
//      offsets and line numbers). After masking, any <details> mention inside
//      a code region is invisible to downstream scanners — fixes BUG #4.
//
//   2. findTopLevelDetailsSpans(content): a stack-based scanner that returns
//      the spans of every top-level (depth-0) <details>...</details> block.
//      Nested blocks pair correctly — fixes BUG #1.
//
// Other than those two preprocessing steps, the existing line-by-line logic
// in shared.mjs is preserved exactly so that prose context output (and thus
// LLM cache keys in vocab.json) does not churn.

import { unified } from "unified";
import remarkParse from "remark-parse";
import { visit } from "unist-util-visit";

const processor = unified().use(remarkParse);

// Replace every byte that lives inside a code fence (`code` block) or inline
// code span (`inlineCode`) with a space, preserving newlines so line numbers
// and offsets are unchanged. Returns a new string the same length as `content`.
//
// Why this works for our use case: the only bug class the masking needs to
// neutralize is `<details>` mentions inside example markdown (fenced code
// blocks documenting the syntax) and inline code (e.g. `` `<details>` ``).
// remark-parse's CommonMark scanner is the source of truth for which bytes
// belong to those code regions, so even adversarial content (e.g. nested
// backticks, indented code blocks) is handled correctly.
export function maskCodeRegions(content) {
  const tree = processor.parse(content);
  const buf = [...content];
  const mask = (start, end) => {
    for (let i = start; i < end && i < buf.length; i++) {
      if (buf[i] !== "\n") buf[i] = " ";
    }
  };
  visit(tree, (node) => {
    if (node.type === "code" || node.type === "inlineCode") {
      if (node.position) mask(node.position.start.offset, node.position.end.offset);
    }
  });
  return buf.join("");
}

// Stack-based scanner: return spans of every top-level <details>...</details>
// block in `text`. Nested <details> pairs are correctly accounted for via
// depth tracking — only the outermost spans are returned.
//
// Each entry: {
//   openTagStart,    // offset of `<details` of the opening tag
//   openTagEnd,      // offset just past `>` of the opening tag
//   closeTagStart,   // offset of `<` of the closing `</details>` tag
//   closeTagEnd,     // offset just past `>` of the closing tag
// }
//
// Stray closing tags (no matching open) are ignored. Unbalanced opens (no
// matching close before EOF) are dropped.
export function findTopLevelDetailsSpans(text) {
  const spans = [];
  const tag = /<(\/?)details\b[^>]*>/gi;
  let depth = 0;
  let openStart = -1;
  let openEnd = -1;
  let m;
  while ((m = tag.exec(text)) !== null) {
    const isClose = m[1] === "/";
    if (!isClose) {
      if (depth === 0) {
        openStart = m.index;
        openEnd = m.index + m[0].length;
      }
      depth++;
    } else {
      if (depth > 0) {
        depth--;
        if (depth === 0 && openStart >= 0) {
          spans.push({
            openTagStart: openStart,
            openTagEnd: openEnd,
            closeTagStart: m.index,
            closeTagEnd: m.index + m[0].length,
          });
          openStart = -1;
        }
      }
    }
  }
  return spans;
}

// Cache the masked content + span list per file content string. A single
// prepare-publish or fuzz run calls extractDetailsBlocks, extractContextBefore,
// extractGrammarBullets, extractVocabBulletsWithLines, and extractCounterBullets
// on each file — without caching, every call would reparse and re-scan.
// Bounded LRU keyed by content string; sized for the corpus (~280 files).
const stringCache = new Map();
const STRING_CACHE_CAP = 64;
function preprocess(content) {
  if (stringCache.has(content)) return stringCache.get(content);
  const masked = maskCodeRegions(content);
  const spans = findTopLevelDetailsSpans(masked);
  const result = { masked, spans };
  if (stringCache.size >= STRING_CACHE_CAP) {
    stringCache.delete(stringCache.keys().next().value);
  }
  stringCache.set(content, result);
  return result;
}

// Compute 1-indexed line of byte offset `idx` in `content`.
function lineAt(content, idx) {
  let line = 1;
  for (let i = 0; i < idx; i++) if (content.charCodeAt(i) === 10) line++;
  return line;
}

// Yield every top-level <details>...</details> block whose summary matches
// `summaryType` (case-insensitive, anchored to start of inner — matching the
// historical `summaryRegex.test(inner)` semantics for non-nested cases).
//
// Each yielded entry: {
//   fileOffset,        // offset of `<details` of the opening tag
//   innerStartOffset,  // offset just past `>` of the opening tag
//   innerEndOffset,    // offset of `<` of the closing `</details>` tag
//   blockLine,         // 1-indexed line of the opening `<details`
//   innerStartLine,    // 1-indexed line of `innerStartOffset`
//   stripped,          // inner content with leading <summary>...</summary> removed
// }
//
// Bullets that callers extract from `stripped.split("\n")` are correctly
// line-numbered by adding the 0-indexed offset within `stripped` to
// `innerStartLine` — matching the previous `extractVocabBulletsWithLines`
// derivation exactly.
export function* iterateDetailsBlocks(content, summaryType) {
  const { masked, spans } = preprocess(content);
  const summaryTest = new RegExp(
    `<summary>\\s*${summaryType}\\s*</summary>`,
    "i",
  );
  for (const span of spans) {
    const inner = content.slice(span.openTagEnd, span.closeTagStart);
    const innerMasked = masked.slice(span.openTagEnd, span.closeTagStart);
    // Match historical behavior: the old `extractDetailsBlocks` used
    // unanchored `summaryRegex.test(inner)` so a block was `summaryType` if
    // `<summary>X</summary>` appeared anywhere in the inner content. We
    // preserve that to avoid output drift; in practice every real block
    // starts with the summary tag, so anchoring would be equivalent on the
    // corpus.
    if (!summaryTest.test(innerMasked)) continue;
    const stripped = inner.replace(/<summary>[\s\S]*?<\/summary>/i, "");
    yield {
      fileOffset: span.openTagStart,
      innerStartOffset: span.openTagEnd,
      innerEndOffset: span.closeTagStart,
      blockLine: lineAt(content, span.openTagStart),
      innerStartLine: lineAt(content, span.openTagEnd),
      stripped,
    };
  }
}

// Restore the historical line-by-line backward scan, but operate on the
// code-region-masked content so <details> mentions inside code fences /
// inline code are invisible (BUG #4). When the scanner encounters a
// </details> closing tag at end-of-line, it uses the precomputed top-level
// spans to jump to the line BEFORE the matching <details> opening — fixing
// BUG #3 (the previous nibble-back-to-first-`<details` heuristic landed
// inside the outer block when nested blocks were present).
//
// Returns { text, line } where text is the joined sentence text (per-line
// trim, single-space join — matching historical output verbatim) and line
// is the 1-based line number of the LAST (bottom-most) line of the
// paragraph (or null if no paragraph found).
export function findContextBefore(content, endIdx) {
  const { masked, spans } = preprocess(content);
  const origLines = content.slice(0, endIdx).split("\n");
  const maskedLines = masked.slice(0, endIdx).split("\n");
  // For each top-level details span, the 0-indexed line of the opening tag.
  const spanByCloseLine = new Map(); // 0-indexed close-line -> openLine (0-indexed)
  for (const sp of spans) {
    const openLine0 = lineAt(content, sp.openTagStart) - 1;
    const closeLine0 = lineAt(content, sp.closeTagStart) - 1;
    spanByCloseLine.set(closeLine0, openLine0);
  }

  let i = maskedLines.length - 1;
  // Skip blank lines and entire <details>...</details> blocks going backward.
  while (i >= 0) {
    const trimmed = maskedLines[i].trim();
    if (trimmed === "") {
      i--;
      continue;
    }
    if (trimmed === "</details>") {
      // Multi-line block close on its own line: jump to opener via precomputed spans.
      const openLine0 = spanByCloseLine.get(i);
      if (openLine0 != null && openLine0 < i) {
        i = openLine0 - 1;
      } else {
        // Fallback: nibble back to first `<details` (legacy behavior; only
        // reached for malformed input where no matching top-level span exists).
        i--;
        while (i >= 0 && !maskedLines[i].trim().startsWith("<details")) i--;
        i--;
      }
      continue;
    }
    if (trimmed.startsWith("<details")) {
      // Single-line block on this line: skip it.
      i--;
      continue;
    }
    break;
  }
  if (i < 0) return { text: null, line: null };
  // Collect contiguous prose lines. Stop at blank/bullet/<details>/<summary>/
  // </details>. Use `origLines` for the output text so masked code regions
  // never leak into the cache key (in practice prose lines never have code
  // spans in this corpus, but the masking would corrupt them if they did).
  const paraLines = [];
  const lastSentenceLineIdx = i;
  while (i >= 0) {
    const m = maskedLines[i].trim();
    if (
      m === "" ||
      m.startsWith("-") ||
      m.startsWith("<details") ||
      m.startsWith("</details") ||
      m.startsWith("<summary")
    )
      break;
    paraLines.unshift(origLines[i].trim());
    i--;
  }
  if (paraLines.length === 0) return { text: null, line: null };
  return { text: paraLines.join(" "), line: lastSentenceLineIdx + 1 };
}
