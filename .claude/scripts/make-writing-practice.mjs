#!/usr/bin/env node
// make-writing-practice.mjs
//
// Turn an annotated reading file into a back-translation practice deck.
//
// Usage:
//   node .claude/scripts/make-writing-practice.mjs NHK-easy/2026-06-14-h3-rocket.md
//
// Given a file like `foo.md`, this writes `foo.WRITING-PRACTICE.md` next to it.
//
// The idea (see docs/TODO-writing.md): an annotated file already pairs each
// Japanese paragraph with an English translation ("gloss"). A practice deck
// flips which side is hidden. We show only the English gloss. The original
// Japanese is NOT included in this file at all (so it stays hidden even when
// opened in editors like VS Code that don't collapse `<details>`); instead
// each card carries a backlink (source line + content hash) to the paragraph
// in the source file.
//
// Parsing reuses the shared, fuzz-tested content-pipeline helpers
// (`iterateDetailsBlocks` + `findContextBefore`) rather than re-implementing
// Markdown/details parsing, so it inherits their handling of code regions and
// nested blocks.
//
// Deliberately NOT included: vocabulary hints. They are too tempting a backdoor
// during a cold attempt. The source file (via the backlink) is the only
// answer key, consulted only after you have written something.
//
// No LLM calls, no network — pure extraction of content you already authored.

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { iterateDetailsBlocks, findContextBefore } from './markdown-ast.mjs';

// --- Parse arguments -------------------------------------------------------
const inputPath = process.argv[2];
if (!inputPath) {
  console.error('Usage: node make-writing-practice.mjs <path-to-annotated.md>');
  process.exit(1);
}
if (!existsSync(inputPath)) {
  console.error(`File not found: ${inputPath}`);
  process.exit(1);
}

const content = readFileSync(inputPath, 'utf8');

// --- Extract (japanese, gloss) for each Translation block ------------------
// Each annotated paragraph is a Japanese sentence followed by a
// `<details><summary>Translation</summary>...</details>` block (and usually
// Vocab/Grammar blocks). For each Translation block, the gloss is its inner
// text and the Japanese is the paragraph immediately before it.
const cards = [];
for (const block of iterateDetailsBlocks(content, 'Translation')) {
  const gloss = block.stripped.trim();
  const context = findContextBefore(content, block.fileOffset);
  // Strip a leading Markdown heading marker (`# `, `## `, ...) so the hash is
  // computed over the same text a reader sees as "the Japanese".
  const japanese = (context?.text ?? '').replace(/^#+\s+/, '').trim();
  if (!japanese || !gloss) continue;
  // Short hash of the Japanese paragraph text, used to relocate the source
  // paragraph even if line numbers shift (e.g. after edits earlier in the file).
  const hash = createHash('sha256').update(japanese).digest('hex').slice(0, 12);
  cards.push({ gloss, sourceLine: context.line, hash });
}

if (cards.length === 0) {
  console.error(
    'No (Japanese + Translation) pairs found. Is this an annotated reading file?'
  );
  process.exit(1);
}

// --- Render the practice deck ----------------------------------------------
// Readable local timestamp like "2026-06-14-11.31.31" — used in both the
// frontmatter and the output filename so re-running on the same source produces
// a fresh, separate deck (you do the same passage again days later, and the
// dated decks become your version history). NOT a Unix timestamp on purpose.
const now = new Date();
const pad = (n) => String(n).padStart(2, '0');
const stamp =
  `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}` +
  `-${pad(now.getHours())}.${pad(now.getMinutes())}.${pad(now.getSeconds())}`;

const header = `---
writing-practice: true
source: ${inputPath}
generated: ${stamp}
---

# Back-translation practice

Read each English gloss and write your Japanese underneath it. Treat **each
line as one attempt** — drop your Obsidian timestamp at the start or end of the
line so the future parser can order your revisions.

The original Japanese is deliberately not in this file. Each card has a
backlink comment (\`source-line\`, \`source-hash\`) pointing at the paragraph in
the source file — use it to look up the original once you've written something.

`;

const renderedCards = cards
  .map((card, i) => {
    const number = i + 1;
    // Quote the gloss line-by-line so multi-line glosses stay inside the quote.
    const quotedGloss = card.gloss
      .split('\n')
      .map((line) => `> ${line}`)
      .join('\n');
    return `### ${number}
<!-- source: ${inputPath}:${card.sourceLine}, source-hash: ${card.hash} -->
${quotedGloss}


`;
  })
  .join('\n');

const outputPath =
  inputPath.replace(/\.md$/, '') + `.WRITING-PRACTICE.${stamp}.md`;
writeFileSync(outputPath, header + renderedCards + '\n');

console.log(`Wrote ${cards.length} cards to ${outputPath}`);
