---
description: Check all Vocab bullet points in Markdown files against JMDict
---

Run the following command from the project root and read its JSON output:

```bash
node .claude/scripts/check-vocab.mjs
```

The script scans all Markdown files for `<details><summary>Vocab</summary>` blocks, extracts each bullet's leading Japanese tokens, and calls `findExact` on each token. A bullet is valid if all its tokens intersect to exactly one JMDict entry. Bullets with 0 or 2+ matches are flagged.

The JSON output has:
- `totalChecked`: total vocab items examined
- `problemCount`: number of items with issues
- `problems[]`: each with `file`, `line`, `bullet`, `tokens`, `tokenResults` (IDs per token), `matchCount`

For each problem, link directly to the offending line using markdown: `[Bunsho Dokkai 3.md:14](Bunsho Dokkai 3.md#L14)`. Then explain the likely cause and suggest corrected text that would produce exactly one match. Common causes:
- **matchCount 0, conjugated form**: e.g. `入りこも` is the 未然形 of `入り込む` — suggest the dictionary form
- **matchCount 0, mixed kanji+kana**: e.g. `事じょう` mixes kanji and kana mid-word — suggest the full kanji form (`事情`) or full kana (`じじょう`)
- **matchCount 0, not in JMDict**: onomatopoeia or very colloquial terms may need a note added instead
- **matchCount 2+**: the search term is ambiguous — suggest adding a reading token (e.g. `気味 きみ`) to disambiguate

Do NOT edit any Markdown files. Only report findings and suggestions in your response.
