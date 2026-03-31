// generate-all-topics.mjs
// Reads the three grammar TSV files and writes grammar/all-topics.json.
// Run from the project root: node grammar/generate-all-topics.mjs
// The output is committed to the repo so the TestHarness can load any topic
// without requiring prepare-publish.mjs to have been run first.

import { readFileSync, writeFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const grammarDir = dirname(fileURLToPath(import.meta.url));

function parseTSV(filename) {
  const text = readFileSync(join(grammarDir, filename), "utf8");
  const lines = text.split("\n").filter((l) => l && !l.startsWith("#"));
  const [header, ...rows] = lines;
  const cols = header.split("\t");
  return rows
    .map((r) => {
      const vals = r.split("\t");
      const obj = {};
      cols.forEach((c, i) => (obj[c] = vals[i] ?? ""));
      return obj;
    })
    .filter((r) => r.id);
}

const topics = {};

for (const row of parseTSV("grammar-stolaf-genki.tsv")) {
  const key = "genki:" + row.id;
  topics[key] = {
    source: "genki",
    id: row.id,
    titleEn: row["title-en"],
    titleJp: null,
    level: row.option,
    href: row.href || null,
    sources: [],
    equivalenceGroup: null,
  };
}

for (const row of parseTSV("grammar-bunpro.tsv")) {
  const key = "bunpro:" + row.id;
  topics[key] = {
    source: "bunpro",
    id: row.id,
    titleEn: row["title-en"],
    titleJp: row["title-jp"] || null,
    level: row.option,
    href: row.href || null,
    sources: [],
    equivalenceGroup: null,
  };
}

for (const row of parseTSV("grammar-dbjg.tsv")) {
  const key = "dbjg:" + row.id;
  topics[key] = {
    source: "dbjg",
    id: row.id,
    titleEn: row["title-en"],
    titleJp: null,
    level: row.option,
    href: row.href || null,
    sources: [],
    equivalenceGroup: null,
  };
}

for (const row of parseTSV("kanshudo-grammar.tsv")) {
  const key = "kanshudo:" + row.id;
  topics[key] = {
    source: "kanshudo",
    id: row.id,
    titleEn: row.title,
    titleJp: null,
    level: row.level,
    href: row.href || null,
    sources: [],
    equivalenceGroup: null,
  };
}

for (const row of parseTSV("grammar-imabi.tsv")) {
  const key = "imabi:" + row.id;
  topics[key] = {
    source: "imabi",
    id: row.id,
    titleEn: row.title,
    titleJp: null,
    level: row.level,
    href: row.href || null,
    sources: [],
    equivalenceGroup: null,
  };
}

const output = {
  generatedAt: new Date().toISOString(),
  sources: {
    genki: { name: "Genki I & II (textbook)", type: "textbook" },
    bunpro: { name: "Bunpro", type: "online" },
    dbjg: { name: "Dictionary of Basic Japanese Grammar", type: "book" },
    kanshudo: { name: "Kanshudo grammar index", type: "online" },
    imabi: { name: "IMABI", type: "online" },
  },
  topics,
};

writeFileSync(
  join(grammarDir, "all-topics.json"),
  JSON.stringify(output, null, 2)
);
console.log(
  `Written ${Object.keys(topics).length} topics to grammar/all-topics.json`
);
