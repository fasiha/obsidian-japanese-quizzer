/**
 * publish.mjs
 * Pushes vocab.json and related files to a private GitHub repo via git over SSH.
 *
 * One-time setup:
 *   1. Create a private GitHub repo (e.g. github.com/you/pug-files).
 *   2. Clone it locally: git clone git@github.com:you/pug-files ../pug-files
 *   3. Set PUBLISH_REPO_PATH in .env (default: ../pug-files relative to this file).
 *   4. Run `node prepare-publish.mjs` to generate vocab.json and corpus.json first.
 *
 * Usage:
 *   node publish.mjs
 *
 * The raw base URL for the iOS app's vocabUrl setup parameter:
 *   https://raw.githubusercontent.com/<user>/pug-files/main/vocab.json
 */

import { execSync } from "child_process";
import { readFileSync, copyFileSync, mkdirSync, existsSync } from "fs";
import path from "path";
import { fileURLToPath } from "url";

const projectRoot = path.dirname(fileURLToPath(import.meta.url));

// --- Load .env for PUBLISH_REPO_PATH ---

function loadEnv(envPath) {
  if (!existsSync(envPath)) return {};
  const env = {};
  for (const line of readFileSync(envPath, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    const val = trimmed.slice(eq + 1).trim().replace(/^['"]|['"]$/g, "");
    env[key] = val;
  }
  return env;
}

const env = { ...loadEnv(path.join(projectRoot, ".env")), ...process.env };

const rawRepoPath = env.PUBLISH_REPO_PATH
  ? env.PUBLISH_REPO_PATH.replace(/\$([A-Z_][A-Z0-9_]*)/g, (_, v) => process.env[v] ?? "")
  : null;
const repoPath = rawRepoPath
  ? path.resolve(projectRoot, rawRepoPath)
  : path.resolve(projectRoot, "../pug-files");

if (!existsSync(repoPath)) {
  console.error(
    `Error: publish repo not found at ${repoPath}\n` +
      "Clone your private GitHub repo there, or set PUBLISH_REPO_PATH in .env.",
  );
  process.exit(1);
}

// --- Verify required source files exist ---

const filesToPublish = [
  { src: path.join(projectRoot, "vocab.json"),       dest: "vocab.json" },
  { src: path.join(projectRoot, "grammar.json"),     dest: "grammar.json" },
  { src: path.join(projectRoot, "grammar", "grammar-equivalences.json"), dest: "grammar-equivalences.json" },
  { src: path.join(projectRoot, "transitive-intransitive", "transitive-pairs.json"), dest: "transitive-pairs.json" },
  { src: path.join(projectRoot, "corpus.json"),      dest: "corpus.json" },
];

for (const { src, dest } of filesToPublish) {
  if (!existsSync(src)) {
    console.error(`${dest} not found — run \`node prepare-publish.mjs\` first`);
    process.exit(1);
  }
}

// --- Collect images listed in corpus.json ---

let images = [];
try {
  const corpus = JSON.parse(readFileSync(path.join(projectRoot, "corpus.json"), "utf8"));
  images = corpus.images ?? [];
} catch (err) {
  console.warn(`[publish] Could not parse corpus.json for images: ${err.message}`);
}

function run(cmd, opts = {}) {
  return execSync(cmd, { stdio: "inherit", ...opts });
}

// --- Copy JSON files into the repo ---

for (const { src, dest } of filesToPublish) {
  copyFileSync(src, path.join(repoPath, dest));
}

// --- Copy images into the repo, preserving subdirectory structure ---

for (const { localPath, repoPath: imageDest } of images) {
  const absLocalPath = path.resolve(projectRoot, localPath);
  if (!existsSync(absLocalPath)) {
    console.warn(`[publish] Image not found, skipping: ${localPath}`);
    continue;
  }
  const destPath = path.join(repoPath, imageDest);
  mkdirSync(path.dirname(destPath), { recursive: true });
  copyFileSync(absLocalPath, destPath);
}

// --- Commit and push ---

run(`git -C "${repoPath}" add -A`);

const diff = execSync(`git -C "${repoPath}" diff --cached --name-only`, {
  encoding: "utf8",
}).trim();

if (!diff) {
  console.log("\nAll files unchanged — nothing to push.");
} else {
  const timestamp = new Date().toISOString().slice(0, 16).replace("T", " ");
  run(`git -C "${repoPath}" commit -m "Update ${timestamp}"`);
  run(`git -C "${repoPath}" push`);

  // Extract username and repo name from the remote URL for the raw URL hint.
  const remoteUrl = execSync(`git -C "${repoPath}" remote get-url origin`, {
    encoding: "utf8",
  }).trim();
  // SSH remote looks like: git@github.com:<username>/<repo>.git
  // HTTPS remote looks like: https://github.com/<username>/<repo>.git
  const match = remoteUrl.match(/github\.com[:/]([^/]+)\/([^/.]+)/);
  const username = match ? match[1] : "<your-github-username>";
  const repoName = match ? match[2] : "<your-repo>";

  console.log(`\nPublished successfully!`);
  console.log(`Raw base URL (use vocab.json path as vocabUrl in the setup deep link):`);
  console.log(`  https://raw.githubusercontent.com/${username}/${repoName}/main/vocab.json`);
}
