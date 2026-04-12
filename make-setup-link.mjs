#!/usr/bin/env node
// make-setup-link.mjs
// Reads ANTHROPIC_API_KEY, VOCAB_URL, and VOCAB_URL_PAT from .env and prints
// the japanquiz://setup deep link.
// Run as:
// $ node make-setup-link.mjs | xargs xcrun simctl openurl booted

import { readFileSync } from "fs";

function loadEnv(path = ".env") {
  try {
    const text = readFileSync(path, "utf8");
    const env = {};
    for (const line of text.split("\n")) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      const eq = trimmed.indexOf("=");
      if (eq === -1) continue;
      const key = trimmed.slice(0, eq).trim();
      const val = trimmed.slice(eq + 1).trim().replace(/^['"]|['"]$/g, "");
      env[key] = val;
    }
    return env;
  } catch {
    return {};
  }
}

const env = { ...loadEnv(), ...process.env };

const key = env.ANTHROPIC_API_KEY;
const vocabUrl = env.VOCAB_URL;
const token = env.VOCAB_URL_PAT;

if (!key) {
  console.error("Error: ANTHROPIC_API_KEY not set in .env or environment");
  process.exit(1);
}
if (!vocabUrl) {
  console.error("Error: VOCAB_URL not set in .env or environment");
  process.exit(1);
}
if (!token) {
  console.warn(
    "Warning: VOCAB_URL_PAT not set — omitting token parameter.\n" +
    "         This is fine for public repos or local simulator dev, but required for private repos.",
  );
}

const params = new URLSearchParams({ key, vocabUrl });
if (token) params.set("token", token);
console.log(`japanquiz://setup?${params}`);
