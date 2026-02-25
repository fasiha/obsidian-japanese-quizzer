# Claude instructions for llm-review

See `README.md` for a full project overview, including the vocab bullet format,
script descriptions, quiz DB schema, and the design principle that Claude never
writes directly to SQLite — only via the scripts in `.claude/scripts/`, and it *never* writes to the user's Markdown content.

## Documentation upkeep

When implementing any new feature or making a non-trivial change, always check
whether `README.md` (and any relevant `.claude/commands/*.md` skill prompts) need
updating. Specifically:

- **`README.md`** — update the user guide section, the project layout, and any
  implementation notes that describe the affected scripts or flow.
- **Skill prompts** (`.claude/commands/*.md`) — update the step-by-step
  instructions if the script interface or workflow changes.

Do this as part of the same task, not as a separate follow-up.

---

## Quiz DB versioning

`quiz.sqlite` tracks its schema version via `PRAGMA user_version` (currently 1),
set in `.claude/scripts/init-quiz-db.mjs`.

Migration pattern for future schema changes:

```js
const v = db.pragma('user_version', { simple: true });
if (v < 2) {
  db.exec(`ALTER TABLE reviews ADD COLUMN ...`);
  db.pragma('user_version = 2');
}
```
