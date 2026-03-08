var document;

/** Run this in the browser at https://bunpro.jp/grammar_points to generate `data` */
var runme = () =>
  copy(
    [...document.querySelectorAll("li.js_search-tile_index:has(a)")].map(
      (o) => {
        var a = o.querySelector("a");
        return {
          href: decodeURIComponent(a?.href),
          text: o.textContent.trim(),
          title: a?.title,
          option: [...o.classList.values()].filter((s) =>
            s.startsWith("js_search-option_"),
          )[0],
        };
      },
    ),
  );

/** Convert an array of objects into a TSV (tab-separated values) */
var toTsv = (data) => {
  const comment = `# Generated on ${new Date().toISOString()} from https://bunpro.jp/grammar_points`;
  const header = Object.keys(data[0] ?? {}).join("\t");
  const body = data.map((row) => Object.values(row).join("\t")).join("\n");
  return `${comment}\n${header}\n${body}`;
};

/**
 * Clean and validate each item
 *
 * Each item's ID (which will be typed into Markdown) is from the URL and is short and typable.
 *
 * Options are JLPT levels (N5 to N1, easy to hard) or unknown "NT".
 */
var clean = (data) => {
  if (!data.every((o) => o.option.startsWith("js_search-option_jlpt"))) {
    throw new Error("Some items do not have the expected option value");
  }
  if (!data.every((o) => o.text.includes("\n"))) {
    throw new Error("Some text fields do not contain a newline");
  }
  if (
    !data.every((o) => o.href.startsWith("https://bunpro.jp/grammar_points/"))
  ) {
    throw new Error("Some href fields do not have the expected format");
  }

  const results = data.map((item) => {
    const result = {
      id: item.href.split("/").at(-1),
      ...item,
      option: item.option.replace("js_search-option_", ""),
      "title-jp": item.text.split("\n")[0],
      "title-en": item.title,
    };
    delete result.title;
    delete result.text;
    return result;
  });

  if (new Set(results.map((o) => o.id)).size !== results.length) {
    throw new Error("Some items have duplicate ids");
  }

  return results;
};

var data = [
  // Paste the output of `runme()` here
];

console.log(toTsv(clean(data)));
