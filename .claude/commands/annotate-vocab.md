---
description: Annotate a Japanese sentence with vocabulary from JMDict for N4-level learners
---

Given a Japanese sentence (or short passage) in `$ARGUMENTS`, produce a vocabulary list for an N4-level learner: someone passingly familiar with some words but for whom many will be new or uncertain.

## Step 1 — Run MeCab

Run MeCab on the input to get lemmas (dictionary forms) for each morpheme:

```bash
echo "$ARGUMENTS" | mecab
```

From the MeCab output, collect all **content word lemmas**: nouns, verbs (dictionary form), adjectives (dictionary form), and adverbs. Skip:
- Particles (助詞)
- Auxiliary verbs (助動詞)
- Punctuation
- Proper nouns / personal names (固有名詞-人名, 固有名詞-地名, etc.)
- Pure grammar morphemes (て、に、は、が、etc.)

## Step 2 — Look up each lemma in JMDict

For each content word lemma, run:

```bash
node lookup.mjs {lemma}
```

Classify the result:

- **Found**: use the entry. Skip obviously N5 words that nearly all learners know (e.g. 食べる、大きい、日本、今). When in doubt, include.
- **Not found (conjugated/inflected form)**: try the plain dictionary form. For example, if `入りこも` fails, try `入り込む`. If the base form is found, use that. You can also search for the kana form (`はいりこむ`). You can also try a prefix search to discover the right form:

```bash
node lookup.mjs '{stem}*'
```
- **Not found (elongated form)**: if the word is simply a lengthened version of a dictionary word (e.g. ゆうるり is ゆるり with a long vowel), cite the base dictionary word instead. No "Not in JMDict" note needed.
- **Not found (mimetic/onomatopoeia)**: try several lookup strategies before giving up:
  1. Try katakana: `node lookup.mjs ホフッ`
  2. Try the shortest mora stem (e.g. `node lookup.mjs 'ピュ*'` instead of the full elongated form)
  3. Grep mimetic.md for related words: `grep -i "{stem}" mimetic.md`

  If a close variant is found by any of these, note it. Either way, mark the word as not in JMDict (see output format below).

## Step 3 — Output the vocab list

Print a Markdown bullet list, one item per word, in the order the words appear in the sentence.

Format for words **found in JMDict**:
```
- {kana reading} {kanji form}
```
If the word has no kanji form (kana-only), just:
```
- {kana}
```

Format for words **not in JMDict** (mimetic words, rare adverbs, etc.):
```
- Not in JMDict: {word as it appears in text} — {concise meaning in context, one short phrase}
```

Do **not** include English meanings for JMDict words — the learner can look them up; the point is to flag which words to look up.

Do **not** annotate grammar (て-form, たら, ので, etc.) — vocabulary only.

Do **not** annotate proper names (people, places).
