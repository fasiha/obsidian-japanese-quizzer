# TODO: HTML reader enhancements

This document covers improvements to the pandoc-based HTML reading workflow,
where `annotate-vocab-inline.mjs` post-processes annotated Markdown files and
the result is piped through `pandoc` to produce a self-contained HTML page.

---

## What is already built

`annotate-vocab-inline.mjs` reads an annotated Markdown file line-by-line and:

- Tracks source lines vs. `<details>` block lines separately so that
  sentence IDs (1-based source-line indices) stay stable even after
  Translation and Grammar `<details>` blocks are inserted by
  `annotate-harness.mjs done`.
- Recognises `<details><summary>Vocab</summary>` blocks and, for each
  top-level vocab bullet inside one, queries `jmdict.sqlite` and emits an
  expanded annotation: dictionary form, reading(s), and English senses.
  Sense selection is guided by a per-occurrence sidecar
  (`<basename>.vocab-inline-data.json`) produced by
  `annotate-harness.mjs done --senses`, so the same word can carry different
  senses in different sentences.
- Passes Translation, Grammar, and any other non-Vocab `<details>` blocks
  through verbatim without counting their lines toward sentence IDs.

---

## Feature: toggle furigana on the sentence above (done)

### Goal

Add a "show furigana" button to each Vocab `<details>` block. Clicking it
replaces the plain sentence text (the paragraph just above the block) with a
pre-rendered `<ruby>` version of that same sentence, and clicking again
restores the plain text.

### What we built

- `annotate-vocab-inline.mjs` now buffers `lastProseLine` (the most recent
  non-blank "real" source line) as it streams through the file, captures it as
  `vocabSentenceText` when a Vocab block opens, and accumulates one
  `{ text, segs }` furigana candidate per resolved bullet
  (`buildFuriganaCandidate`, `vocabFuriganaCandidates`) by looking up the
  bullet's specific kanji-form + kana-reading pair directly in `jmdict.sqlite`'s
  `furigana` table — the exact per-occurrence resolution
  `lookupFurigana(text:reading:db:)` performs on the iOS side (see breadcrumbs
  below for why we resolve this way instead of bundling every possible form).
- `resolveSentenceFurigana` runs the merged two-step algorithm (below) and
  emits one `<span class="furigana-sentence" hidden>…</span>` per Vocab block,
  just before its closing `</details>`.
- `dark.html` was renamed to `header.html`, exempted from the `*.html`
  gitignore rule (`!header.html`), and committed — it is now a *required*
  pandoc header (`pandoc -s -H header.html …`), not just a cosmetic dark-mode
  stylesheet. It carries the toggle button's CSS and the swap script.
- The script (in `header.html`) finds each `.furigana-sentence` span, locates
  its Vocab `<details>`, walks backward through sibling `<details>` (Grammar/
  Translation) to find the sentence `<p>`, and inserts a `<div class=
  "furigana-toggle-row"><button>ふりがな</button></div>` right after
  `<summary>`. Clicking the button **swaps `sentence.innerHTML`** between the
  original and furigana-annotated HTML (captured once on page load) — it does
  *not* toggle `hidden` on two separately-located elements, see breadcrumbs.

### Breadcrumbs / things we unearthed along the way

- **The furigana-resolution algorithm already exists in Swift.**
  `sentenceFuriganaSegments` in `SentenceFuriganaView.swift` is the canonical
  two-step algorithm (exact-form match, then single-kanji fallback). Our
  Node.js port (`annotateChunk` + the kanji-reading map in
  `annotate-vocab-inline.mjs`) mirrors it line-for-line so behaviour stays
  consistent between the iOS reader and the HTML reader.
- **We deliberately did NOT bundle `writtenForms` (maximum-kanji collapsed
  forms from `vocab.json`).** Early on we considered bundling every kanji×kana
  combination for client-side resolution, but that's quadratic per entry (e.g.
  3 kanji × 6 kana = 18 lookups) and still leaves the *which-form-applies-here*
  decision to client-side JS with no sentence context. Swift doesn't use
  `writtenForms` for sentence annotation either — it queries the `furigana`
  table directly with one specific `(text, reading)` pair (the word's resolved
  form), only falling back to `writtenForms` on a direct-lookup miss (version
  skew guard). We do the same: resolve one `(text, reading)` pair per bullet
  straight from the bullet text itself (`buildFuriganaCandidate`), at build
  time, where the actual sentence is available to disambiguate.
- **`<summary>` swallows click events natively.** Putting the toggle button
  inside `<summary>` causes a click to also toggle the `<details>` open/closed
  — and this default activation behaviour isn't reliably cancelable via
  `event.preventDefault()`/`stopPropagation()` on the bubbled click from a
  child button. Fix: place the button in a sibling `<div>` immediately after
  `<summary>`, not inside it.
- **Toggling `hidden` on two elements doesn't visually swap anything.** Pandoc
  absorbs the `<span class="furigana-sentence">` into wherever it lands inside
  the Vocab block's bullet list (typically the last `<li>`, since there's no
  blank line forcing it into its own block) — nowhere near the sentence `<p>`.
  Toggling `hidden` on both just hides the sentence and reveals an
  out-of-place span. Fix: capture both HTML strings once on load and directly
  swap `sentence.innerHTML` between them; the span stays hidden forever as a
  pure data carrier, and its DOM location stops mattering.
- **Pre-existing `<ruby>` spans must be preserved verbatim, including
  multi-pair ones** like `<ruby>美<rt>み</rt>緒<rt>お</rt></ruby>` (character
  name "Mio") or `<ruby>柏<rt>かし</rt>尾<rt>お</rt>川<rt>がわ</rt></ruby>`
  (proper noun). `splitRubyChunks` treats `/<ruby>.*?<\/ruby>/gis` matches as
  opaque blocks — new annotation only happens in the plain-text gaps between
  them.

### Design decisions

**Build-time resolution, not runtime lookup.**
The furigana for each sentence is computed once by `annotate-vocab-inline.mjs`
at the time it processes the Vocab block. The script knows the sentence text
(buffered from the preceding source line) and all the JMDict entry IDs for
every word in the block, so it can run the same two-step algorithm that the
iOS app uses (see below). The resolved `<ruby>` HTML is emitted as a hidden
`<span>` inside the Vocab `<details>` block. The JavaScript just swaps
elements — no dictionary lookups at runtime.

**One resolved sentence per Vocab block (not per bullet).**
All vocab bullets in a block annotate the same sentence, so the furigana
resolution aggregates all bullets' contributions into a single fully annotated
sentence string. Each bullet may cover a different word, and the furigana from
all of them is merged into one pass.

**The sentence may already contain `<ruby>` tags.**
The input sentence is not always plain text. `annotate-harness.mjs` sometimes
inserts `<ruby>` markup for words identified in an earlier pass. The resolution
algorithm must parse existing `<ruby>` spans (treating them as already
annotated ranges that Step 1 should not overwrite) before adding new ones.

### Two-step furigana resolution algorithm (mirrors Swift)

Implemented in Node.js inside `annotate-vocab-inline.mjs`, matching
`sentenceFuriganaSegments` in `SentenceFuriganaView.swift`:

**Step 1 — exact-form match.**
For each vocab word in the Vocab block, query `jmdict.sqlite`'s `furigana`
table for all `(text, reading, segs)` rows whose `text` matches any kanji form
of that entry. Search the sentence for each kanji form verbatim. When found,
splice in the `segs` furigana array (rendered as `<ruby>base<rt>reading</rt></ruby>`).
First-found wins; overlapping annotations are skipped.

**Step 2 — single-kanji fallback.**
After Step 1, any kanji character that is still unannotated and appears exactly
once in the sentence can be annotated safely if all matched furigana entries
agree on the same reading for that individual kanji. This handles conjugated
forms where the full dictionary-form match in Step 1 failed.

### HTML structure emitted

Inside the Vocab `<details>` block, immediately after the `<summary>` tag, the
script injects:

```html
<span class="furigana-sentence" hidden>…pre-rendered ruby HTML…</span>
```

A pandoc header (`--include-in-header`) injects a `<style>` block to hide
`.furigana-sentence` by default, and a small `<script>` block that:

1. On `DOMContentLoaded`, adds a "show furigana" toggle button to the
   `<summary>` of every Vocab `<details>` element that contains a
   `.furigana-sentence` span.
2. On button click, locates the sentence paragraph above the Vocab block
   (walking `previousElementSibling` on the parent, skipping any Grammar or
   Translation `<details>` siblings), hides the plain paragraph, and shows the
   pre-rendered ruby span (or reverses the swap).

### Structural note on sibling layout

The sentence `<p>` and the Vocab `<details>` are siblings under the same
parent element. Between them there may be up to two other `<details>` blocks
(Grammar and Translation), inserted by `annotate-harness.mjs done`. The
JavaScript must skip those siblings when walking backward to find the sentence
paragraph.

### Work plan

- [x] Buffer the sentence text inside `annotate-vocab-inline.mjs` so it is
      available when the Vocab block opens (`lastProseLine` → `vocabSentenceText`).
- [x] Parse any existing `<ruby>` spans in the buffered sentence into
      pre-annotated (opaque) ranges so Step 1/2 do not overwrite them
      (`splitRubyChunks`).
- [x] Implement Step 1 and Step 2 in Node.js (`buildFuriganaCandidate`,
      `annotateChunk`, `resolveSentenceFurigana`).
- [x] Emit the `<span class="furigana-sentence" hidden>` inside the Vocab
      `<details>` block, just before its closing tag.
- [x] Write a pandoc header file with the toggle `<style>` and `<script>`.
      Renamed `dark.html` → `header.html`, exempted it from `.gitignore`
      (`!header.html`), and committed it as a required pandoc header.
- [x] Document the updated `node annotate-vocab-inline.mjs | pandoc -s -H
      header.html …` invocation in `ANNOTATING.md`.
