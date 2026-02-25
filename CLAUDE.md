# Claude instructions for llm-review

See `README.md` for a full project overview, including the vocab bullet format,
script descriptions, quiz DB schema, and the design principle that Claude never
writes directly to SQLite — only via the scripts in `.claude/scripts/`, and it *never* writes to the user's Markdown content.

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
