/**
 * read-quiz-session.mjs
 * Prints the current quiz session file to stdout, or exits with code 1 if none exists.
 *
 * Usage: node .claude/scripts/read-quiz-session.mjs
 */

import { readFileSync, existsSync } from "fs";
import { QUIZ_SESSION } from "./shared.mjs";

if (!existsSync(QUIZ_SESSION)) {
  console.error("No active quiz session.");
  process.exit(1);
}

process.stdout.write(readFileSync(QUIZ_SESSION, "utf8"));
