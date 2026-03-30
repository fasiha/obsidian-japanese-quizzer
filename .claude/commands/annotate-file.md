---
description: Annotate all Japanese lines in a Markdown file with vocabulary from JMDict for N4-level learners
---

Annotate every Japanese line in the file at path `$ARGUMENTS` with vocabulary bullet points.

## Step 1 — Parse the file

Run the deduplication helper on the file:

```bash
node mark-duplicates.mjs "$ARGUMENTS"
```

This prints the file contents with every duplicate Japanese line suffixed by `  <!-- DUPLICATE -->`. Work from this output for all subsequent steps. Lines **not** suffixed are unique and need annotation. Lines suffixed with `<!-- DUPLICATE -->` are exact repeats of an earlier line — skip MeCab and JMDict for those.

## Step 2 — Annotate each unique Japanese line

For each unique Japanese line (skip YAML frontmatter, blank lines, section headers in brackets, purely English/romanized lines), follow the full `annotate-vocab` procedure:

### 2a — Run MeCab

```bash
echo "{line}" | mecab
```

Collect all **content word lemmas**: nouns, verbs (dictionary form), adjectives (dictionary form), adverbs. Skip particles, auxiliary verbs, punctuation, proper nouns, pure grammar morphemes, and 無い.

### 2b — Look up each lemma in JMDict

```bash
node lookup.mjs {lemma}
```

Classify as found, not found (try conjugated/inflected base form or prefix search `node lookup.mjs '{stem}*'`), elongated form (cite base), or mimetic/onomatopoeia (try hiragana/katakana/long-vowel/gemination variants).

### 2c — Check for multi-morpheme compounds

After processing individual lemmas, scan for adjacent morphemes that form compound verbs, compound nouns, or particle compounds (e.g. ままに, ために, として). Look up the concatenation:

```bash
node lookup.mjs {combined}
```

If found, use the compound entry and drop its individual parts.

## Step 3 — Write output to {filename}.annotated.md

Derive the output path by inserting `.annotated` before the `.md` extension of the input file (e.g. `Music/Shiki no Uta.md` → `Music/Shiki no Uta.annotated.md`).

Write a Markdown file to that path with the following structure:

- Reproduce each line from the original file exactly (including section headers, blank lines, and frontmatter), preserving order.
- After each Japanese content line, insert a `<details>` vocab block (see format below).
- For **duplicate lines** (lines that appeared earlier in the file), don't insert anything.

### Vocab block format

```
<details><summary>Vocab</summary>
- {entry}
- {entry}
</details>
```

Each `{entry}` is one of:

For words **found in JMDict** with kanji:
```
- {kana reading} {kanji form}
```
For kana-only words:
```
- {kana}
```
For words **not in JMDict**:
```
- Not in JMDict: {word as it appears in text} — {concise meaning in context}
```

Do **not** include English meanings for JMDict words.
Do **not** annotate grammar (て-form, たら, ので, etc.) — vocabulary only.
Do **not** annotate proper names (people, places).

## Step 4 — Report

After writing the file, print a one-line summary: how many unique lines were annotated, how many duplicate lines were skipped, and the output path.
