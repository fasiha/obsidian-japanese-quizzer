var fs = require("fs");
var all = JSON.parse(fs.readFileSync("./transitive-pairs.json", "utf8"));
var res = all
  .filter((o) => !o.ambiguousReason && o.drills)
  .map(
    (o) =>
      `## ${o.intransitive.kana} (${o.intransitive.kanji.join(", ")}) vs ${o.transitive.kana} (${o.transitive.kanji.join(", ")})\n\n` +
      o.drills
        .map(
          (d) =>
            `${d.intransitive.ja} (${d.intransitive.en}) — ${d.transitive.ja} (${d.transitive.en})`,
        )
        .join("\n"),
  );
console.log(res.join("\n\n"));
