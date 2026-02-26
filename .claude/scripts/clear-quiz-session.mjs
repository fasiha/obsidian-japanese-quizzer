/**
 * clear-quiz-session.mjs
 * Deletes the quiz session file. Safe to run if no session exists.
 *
 * Usage: node .claude/scripts/clear-quiz-session.mjs
 */

import { existsSync, rmSync } from "fs";
import { QUIZ_SESSION } from "./shared.mjs";

if (existsSync(QUIZ_SESSION)) {
  rmSync(QUIZ_SESSION);
  console.log("Quiz session cleared.");
} else {
  console.log("No session to clear.");
}
