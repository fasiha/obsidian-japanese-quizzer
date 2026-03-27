---
description: Annotate a Japanese sentence with grammar topic IDs from Genki, Bunpro, and DBJG
---

Given a Japanese sentence (or short passage) in `$ARGUMENTS`, identify the grammar constructions present and match each to a single topic ID from one of the three grammar databases (Genki, Bunpro, DBJG).

## Step 1 — Identify grammar constructions

Read the sentence and list every grammar construction worth annotating. Focus on:
- Verb forms and endings (て-form, potential, passive, causative, conditional, volitional, etc.)
- Sentence patterns (〜ている, 〜てしまう, 〜ようにする, 〜らしい, etc.)
- Particles used in grammatical roles (には, までに, として, etc.)
- Conjunctions and connectives (から、ので、けど、が、たり〜たり, etc.)
- Auxiliary expressions (〜たことがある、〜なければならない、〜てもいい, etc.)

Skip pure vocabulary (noun, verb, or adjective meanings — those belong in `/annotate-vocab`).

For each construction, note:
- The surface form as it appears in the sentence
- A short English description (used for grepping)
- A candidate Japanese form (used for grepping)

## Step 2 — Search the grammar databases

For each construction, search all three TSV files. Try both a Japanese keyword and an English keyword. The TSV columns are:

| File | Columns |
|---|---|
| `grammar/grammar-bunpro.tsv` | id, href, option (JLPT level), title-jp, title-en |
| `grammar/grammar-dbjg.tsv` | id, href, option, title-en, alias-of |
| `grammar/grammar-stolaf-genki.tsv` | id, href, option, title-en |

Search command:

```bash
grep -i "{keyword}" grammar/grammar-bunpro.tsv grammar/grammar-dbjg.tsv grammar/grammar-stolaf-genki.tsv
```

Try multiple keywords if needed — for example, `ように` first, then `so that`, then `in order`. DBJG IDs are romanized slugs (e.g. `yoni1`, `te-iru`), so also try romaji stems.

If an initial search returns too many hits, narrow with a second keyword:

```bash
grep -i "{keyword1}" grammar/grammar-bunpro.tsv | grep -i "{keyword2}"
```

If grep results are ambiguous — multiple entries share a root form and title-en alone isn't enough to distinguish — fetch the Bunpro or Genki URL from the `href` column to read the full description:

```bash
# href values are full URLs for Bunpro and Genki entries
```

Use the WebFetch tool on the URL. Only do this when necessary to resolve ambiguity, not for every entry.

## Step 3 — Select one best match

For each construction, pick a **single** ID from whichever database has the most precise match. Prefer Bunpro when it has a good match (broadest coverage). Fall back to DBJG or Genki if they are more precise.

- If a DBJG entry has a non-empty `alias-of` field, use the canonical ID listed there instead.
- Do not invent IDs — only use IDs that actually appear in the TSV files.

## Step 4 — Output

Print a Markdown bullet list, one item per construction, in the order they appear in the sentence. Each bullet is a prefixed ID followed by a brief inline note explaining how the construction works in **this specific sentence** — the surface form, what role it plays, and why a learner should notice it:

```
- {db}:{id} — {surface form}: {one sentence explanation specific to this sentence}
```

For example:
```
- bunpro:ように — 鳥のように: compares the way she moves to a bird; "のように" attaches to a noun to mean "like ~"
- dbjg:te-iru — 待っている: ongoing action, "is waiting"; て-form + いる expresses a state in progress
- genki:potential-verbs — 食べられる: potential form of 食べる, "can eat"
```

If a construction has no match in any database, still list it but note it:

```
- not found: {surface form} — {description}
```

When in doubt about whether to include a construction, **include it**. The target reader is an N5-level learner for whom many intermediate patterns will be unfamiliar. If a construction seems noteworthy — even if finding the right database ID is uncertain — list it as a `not found` bullet with a plain-English description. The human can look it up or ignore it; it is better to over-annotate than to silently skip something a learner would struggle with.

Do **not** annotate vocabulary items — only grammar constructions.

Do **not** annotate the basic copula だ/です or the most elementary particles (は、が、を、に、へ、の) unless the sentence specifically hinges on a non-obvious use of them covered in the databases.