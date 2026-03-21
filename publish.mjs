/**
 * publish.mjs
 * Pushes vocab.json to a GitHub secret Gist via git over SSH.
 *
 * One-time setup:
 *   1. Create a secret Gist at https://gist.github.com — paste any placeholder text.
 *      Copy the Gist ID from the URL: gist.github.com/<username>/<GIST_ID>
 *   2. Make sure github.com is in your ~/.ssh/known_hosts (any prior `git clone` or
 *      `ssh -T git@github.com` will have added it).
 *   3. Run `node prepare-publish.mjs` to generate vocab.json first.
 *
 * Usage:
 *   GIST_ID=<your-gist-id> node publish.mjs
 *   node publish.mjs <gist-id>
 *
 * The raw URL for the iOS app's vocabUrl setup parameter will be printed on success:
 *   https://gist.githubusercontent.com/<user>/<gist-id>/raw/vocab.json
 */

import { execSync } from "child_process";
import { mkdtempSync, rmSync, copyFileSync, existsSync } from "fs";
import { tmpdir } from "os";
import path from "path";
import { fileURLToPath } from "url";

const projectRoot = path.dirname(fileURLToPath(import.meta.url));

const gistId = process.argv[2] || process.env.GIST_ID;
if (!gistId) {
  console.error(
    "Error: Gist ID required.\n" +
      "  Usage: GIST_ID=<id> node publish.mjs\n" +
      "      or node publish.mjs <id>",
  );
  process.exit(1);
}

const vocabPath = path.join(projectRoot, "vocab.json");
if (!existsSync(vocabPath)) {
  console.error("vocab.json not found — run `node prepare-publish.mjs` first");
  process.exit(1);
}

const grammarPath = path.join(projectRoot, "grammar.json");
if (!existsSync(grammarPath)) {
  console.error("grammar.json not found — run `node prepare-publish.mjs` first");
  process.exit(1);
}

const grammarEquivPath = path.join(projectRoot, "grammar", "grammar-equivalences.json");
if (!existsSync(grammarEquivPath)) {
  console.error("grammar/grammar-equivalences.json not found — run `/cluster-grammar-topics` first");
  process.exit(1);
}

const transitivePairsPath = path.join(projectRoot, "transitive-intransitive", "transitive-pairs.json");
if (!existsSync(transitivePairsPath)) {
  console.error("transitive-intransitive/transitive-pairs.json not found");
  process.exit(1);
}

const tmpDir = mkdtempSync(path.join(tmpdir(), "gist-publish-"));

function run(cmd, opts = {}) {
  return execSync(cmd, { stdio: "inherit", ...opts });
}

try {
  console.log(`Cloning gist ${gistId}...`);
  run(`git clone git@gist.github.com:${gistId}.git "${tmpDir}"`);

  copyFileSync(vocabPath, path.join(tmpDir, "vocab.json"));
  copyFileSync(grammarPath, path.join(tmpDir, "grammar.json"));
  // grammar-equivalences.json lives in grammar/ locally but is published flat
  // so the Pug app can fetch it by replacing "vocab.json" with "grammar-equivalences.json"
  // in the Gist raw URL.
  copyFileSync(grammarEquivPath, path.join(tmpDir, "grammar-equivalences.json"));
  // transitive-pairs.json lives in transitive-intransitive/ locally but is published flat.
  copyFileSync(transitivePairsPath, path.join(tmpDir, "transitive-pairs.json"));

  run(`git -C "${tmpDir}" add vocab.json grammar.json grammar-equivalences.json transitive-pairs.json`);

  // Check if there's anything staged to commit
  const diff = execSync(`git -C "${tmpDir}" diff --cached --name-only`, {
    encoding: "utf8",
  }).trim();

  if (!diff) {
    console.log("\nAll files unchanged — nothing to push.");
  } else {
    const timestamp = new Date().toISOString().slice(0, 16).replace("T", " ");
    run(`git -C "${tmpDir}" commit -m "Update vocab.json ${timestamp}"`);
    run(`git -C "${tmpDir}" push`);

    // Extract GitHub username from the remote URL for the raw URL hint
    const remoteUrl = execSync(`git -C "${tmpDir}" remote get-url origin`, {
      encoding: "utf8",
    }).trim();
    // SSH remote looks like: git@gist.github.com:<username>/<gistId>.git
    const usernameMatch = remoteUrl.match(/:([^/]+)\//);
    const username = usernameMatch ? usernameMatch[1] : "<your-github-username>";

    console.log(`\nPublished successfully!`);
    console.log(`Raw URL (use this as vocabUrl in the setup deep link):`);
    console.log(
      `  https://gist.githubusercontent.com/${username}/${gistId}/raw/vocab.json`,
    );
  }
} finally {
  rmSync(tmpDir, { recursive: true, force: true });
}
