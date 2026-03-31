# Definitions hover: Obsidian plugin + sidecar JSON

Show JMDict definitions when clicking a button inside Vocab `<details>` blocks
in Obsidian reading view. Works on desktop and iOS without interfering with the
native expand/collapse of `<details>`.

---

## Part 1 — Node.js: `build-jmdict-sidecar.mjs`

New script at project root. Produces `jmdict-sidecar.json` inside
`llm-review/` (same directory as the Markdown files — the plugin walks up
from the open note to find it).

### What it does

1. Reuse `findMdFiles`, `parseFrontmatter`, `extractVocabBullets` (from
   `shared.mjs`) and `findExactIds`, `intersectSets`, `idsToWords` (from
   `jmdict-simplified-node`) — same logic as `prepare-publish.mjs`.
2. Filter to files with `llm-review: true` frontmatter.
3. For each vocab bullet, extract the leading Japanese tokens using
   `extractJapaneseTokens` (identical to `check-vocab.mjs` — stop at the
   first non-Japanese, non-whitespace token). Look up by intersecting
   `findExactIds` across all tokens. Skip/warn on 0 or 2+ matches.
4. Key each entry by the **raw bullet text** (trimmed string after the leading
   `-`, e.g. `"また 又"` or `"おいかける 追い掛ける"`). The plugin uses the
   same `extractJapaneseTokens` logic to reconstruct the lookup key from the
   rendered DOM text — see bullet extraction below.
5. Store the **complete JMDict word object** as returned by `idsToWords` plus
   a `tags` lookup map so the plugin can resolve tag codes to human-readable
   labels without knowing the schema in advance.
6. Write `jmdict-sidecar.json`.

### Sidecar JSON shape

```jsonc
{
  "generatedAt": "2026-03-30T…",
  "tags": { "adv": "adverb (fukushi)", "conj": "conjunction", … },
  "entries": {
    "また 又": { /* full idsToWords word object, verbatim */ },
    "おいかける 追い掛ける": { /* … */ },
    …
  }
}
```

`tags` is the complete JMDict tag map from
`select value_json from metadata where key='tags'` — the plugin uses it to
expand `pos`/`field`/`misc` codes in senses into readable text.

### Usage

```
node build-jmdict-sidecar.mjs
```

Add to `package.json` `scripts` as `"sidecar": "node build-jmdict-sidecar.mjs"`.

Re-run whenever new vocab is annotated. (Could later be called from
`prepare-publish.mjs` as a final step.)

---

## Part 2 — Obsidian plugin: `obsidian-vocab-hover`

### Location

`/Users/fasiha/Downloads/obsidian/Scriviner/.obsidian/plugins/obsidian-vocab-hover/`

**No build step.** Follow the pattern of the existing `timed-audio` plugin
(same vault): plain CommonJS `main.js` + `manifest.json`, no TypeScript, no
npm, no esbuild. ~150–200 lines.

```js
const { Plugin, Platform, Modal } = require("obsidian");
```

### Manifest

```json
{
  "id": "obsidian-vocab-hover",
  "name": "Vocab Definitions",
  "version": "0.1.0",
  "minAppVersion": "1.0.0",
  "description": "Show JMDict definitions for annotated vocab blocks.",
  "author": "fasiha",
  "isDesktopOnly": false
}
```

### Plugin lifecycle

**`onload()`**
1. Attempt to load `jmdict-sidecar.json`. Since the plugin activates at
   launch (not per-file), use a lazy-load strategy: on first
   `MarkdownPostProcessor` call, walk up from `ctx.sourcePath` using
   `this.app.vault.adapter` looking for `jmdict-sidecar.json` in each
   ancestor directory. Cache the result (or `null` if not found).
2. Register a `MarkdownPostProcessor`.

**`onunload()`** — close any open popover/modal.

### MarkdownPostProcessor

Called for each rendered HTML block. Walk `el.querySelectorAll('details')`.
For each `<details>`:

1. Check `<summary>` text (trimmed) equals `"Vocab"` — skip otherwise.
2. **Inject a button** inside the `<details>`, after the `<summary>`, e.g.:
   ```html
   <button class="vocab-def-btn">📖 definitions</button>
   ```
   The button click opens the popover/modal. The native `<details>`
   expand/collapse is left completely alone.
3. **Bullet extraction for lookup**: The DOM preserves newlines inside
   `<details>` even though Obsidian's CSS renders the content as a single
   wrapped line. Read `details.textContent`, split on newlines, trim each
   line, keep lines starting with `- `, drop the leading `- `. For each
   bullet string, apply `extractJapaneseTokens`-equivalent logic in JS
   (stop at first non-Japanese, non-whitespace token) to reconstruct the
   canonical lookup key, then look up in `entries`. Collect matched entries.

### Interaction: button click (desktop and iOS)

Both platforms use the same button-click flow. No `preventDefault` on
`<details>` needed.

- **Desktop**: show a `PopoverSuggest`-style floating panel. Because
  `PopoverSuggest` is designed for autocomplete (requires an input element),
  use a plain positioned `<div class="vocab-def-popover">` appended to
  `document.body`, positioned below the button via `getBoundingClientRect()`.
  Dismiss on click-outside or Escape.
- **iOS**: show a `Modal` (Obsidian API). Same card content. The modal
  provides a native dismiss gesture on iOS.
- Detect platform with `Platform.isMobile`.

### Displayed content

For each matched word, render a card showing kanji + kana header and senses:

```
又・また
  adv, conj
  1. again; once more; also
  2. (another meaning…)
```

- Header: kanji forms joined by `・` (omit `iK`-tagged forms), then `・`,
  then kana forms (omit `ik`-tagged).
- Part of speech: expand `pos` tag codes via `tags` map from the sidecar;
  show on a subdued line below the header.
- Senses: numbered; glosses within a sense joined by `"; "`.
- CSS in an inline `<style>` block injected once, or a `styles.css` file
  alongside `main.js`.

### Sidecar discovery

```
ctx.sourcePath = "Japanese/llm-review/Music/Shiki no Uta.md"
```

Walk ancestor directories from the file's directory up to vault root, checking
for `jmdict-sidecar.json` at each level via
`this.app.vault.adapter.exists(...)`. Cache the resolved path after the first
successful find. If not found anywhere, the button still appears but shows
"sidecar not found — run build-jmdict-sidecar.mjs".

---

## Resolved decisions

- **Do not interfere with `<details>` open/close** — add a button inside
  instead.
- **Sidecar location**: `llm-review/` (alongside the Markdown), not vault
  root. Plugin walks up to find it.
- **Full word object** stored in sidecar — plugin decides what to display.
- **Tag map** included in sidecar so plugin can render human-readable
  part-of-speech without hardcoding.
- **Bullet key**: leading Japanese tokens only (same as `extractJapaneseTokens`
  in shared.mjs). Non-Japanese trailing text in bullets is ignored for lookup.
- **Stale sidecar**: unknown bullets silently produce no card (not an error).
- **PopoverSuggest is for autocomplete inputs** — use a plain positioned div
  for desktop hover, `Modal` for iOS.
