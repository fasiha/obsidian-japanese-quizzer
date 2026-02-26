/**
 * write-quiz-session.mjs
 * Writes a quiz session plan to .claude/quiz-session.txt by filtering
 * the pre-built context file (.claude/quiz-context.txt) for the given IDs.
 *
 * Run get-quiz-context.mjs first to generate the context file.
 *
 * Usage: node .claude/scripts/write-quiz-session.mjs <id1> <id2> ...
 *
 * The session file is read by read-quiz-session.mjs and deleted by
 * clear-quiz-session.mjs when the quiz is finished.
 */

import { readFileSync, writeFileSync, existsSync } from "fs";
import { QUIZ_CONTEXT, QUIZ_SESSION } from "./shared.mjs";

const ids = process.argv.slice(2);
if (ids.length === 0) {
  console.error("Usage: write-quiz-session.mjs <id1> <id2> ...");
  process.exit(1);
}

if (!existsSync(QUIZ_CONTEXT)) {
  console.error(
    "No quiz context file found. Run get-quiz-context.mjs first.",
  );
  process.exit(1);
}

const contextLines = readFileSync(QUIZ_CONTEXT, "utf8").split("\n");

const sessionLines = [];
for (const id of ids) {
  const line = contextLines.find((l) => l.startsWith(id + "  "));
  if (line) {
    sessionLines.push(line);
  } else {
    console.error(`Warning: ID ${id} not found in quiz context`);
  }
}

if (sessionLines.length === 0) {
  console.error("No matching words found in context.");
  process.exit(1);
}

const timestamp = new Date().toISOString();
const lines = [
  `# Quiz session started ${timestamp}`,
  `# Delete this file or run clear-quiz-session.mjs to discard`,
  "",
  ...sessionLines,
];

writeFileSync(QUIZ_SESSION, lines.join("\n") + "\n");
console.log(`Session written: ${sessionLines.length} words → ${QUIZ_SESSION}`);
