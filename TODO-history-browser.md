# History Browser

## Goal

Let users revisit past quiz items and discuss them with Haiku, without losing context by accidentally tapping "Next question."

## Decisions

### History sheet (list view)

A sheet showing a table of past quiz reviews, with columns:
- Timestamp (local time)
- Type: `jmdict` or `grammar`
- Label:
  - For jmdict: enrolled furigana, or first kana reading from JMDict if no furigana
  - For grammar: topic ID (e.g. `bunpro:tenaranai`)

Tapping a row opens the review detail sheet.

### Review detail sheet (discussion view)

A new sheet that looks like the quiz sheet, with the original question stem and answer choices pre-filled and the correct answer and student's choice shown — ready to discuss with Haiku. This is intentionally *not* WordDetailSheet or GrammarDetailSheet, because those have a lot of content and require scrolling to reach the chat.

The sheet drops the user straight into a Haiku chat about that specific quiz item.

## TODOs

- [ ] Future work: search?

### Multiple-choice notes are too sparse

Currently the `reviews.notes` field for multiple-choice items only stores the `sub_use` string (written by the autograder path). It should also store all four choices so the history browser can reconstruct the full question. Fix the note-writing code at the point where a multiple-choice result is saved.

### Tentative: persist chat history across sessions

Consider storing Haiku chat turns (quiz page, review detail sheet, WordDetailSheet, GrammarDetailSheet) in the database so repeat questions about the same item can be recalled. Users often ask Haiku the same clarifying question about a word or grammar point across sessions; a persisted chat log would surface those answers without re-querying. Needs design work — table shape, UI for surfacing old turns, and whether to show them inline or in a separate log.
