var document;

/** Run this in the browser at https://wp.stolaf.edu/japanese/grammar-index/genki-i-ii-grammar-index/ to generate `data` */
var runme = () =>
  copy(
    [...document.querySelectorAll("p:has(a[title])")].map((o) => {
      const a = o.querySelector("a");
      return { href: a.href, title: a.title };
    }),
  );

/** Convert an array of objects into a TSV (tab-separated values) */
var toTsv = (data) => {
  const comment = `# Generated on ${new Date().toISOString()} from https://wp.stolaf.edu/japanese/grammar-index/genki-i-ii-grammar-index/`;
  const header = Object.keys(data[0] ?? {}).join("\t");
  const body = data.map((row) => Object.values(row).join("\t")).join("\n");
  return `${comment}\n${header}\n${body}`;
};

/**
 * Clean and validate the data.
 *
 * Options are Genki I (first year college) or Genki II (second year college).
 *
 * A few rows are dirty and we accommodate them:
 * 1. "-kata" link doesn't match it's Genki level/chapter
 * 2. "u-and-ru-verbs" link doesn't specify Genki I vs II but it's from Genki I, Chapter 3
 * 3. "-tte" has some garbage characters in the title that we remove
 */
var clean = (data) => {
  const ids = new Set();

  const results = data.map((item) => {
    if (!item.href.endsWith("/")) {
      throw new Error("Unexpected URL ending: " + item.href);
    }

    const slug = item.href.split("/").at(-2);

    if (
      !(
        slug.includes("genki-i-") ||
        slug.includes("genki-ii-") ||
        slug === "u-and-ru-verbs" // missing I vs II but it's Genki 1, Chapter 3
      )
    ) {
      throw new Error("URL missing Genki I vs II: " + item.href);
    }

    const id = (
      item.title.startsWith("-kata")
        ? "kata"
        : slug.includes("-genki-")
          ? slug.split("-genki-")[0]
          : slug
    ).split("%")[0];
    if (ids.has(id)) {
      throw new Error("Duplicate id: " + id);
    }
    ids.add(id);

    const result = {
      id,
      ...item,
      option: slug.includes("genki-ii-") ? "Genki II" : "Genki I",
      "title-en": item.title.split(" ( ")[0].split("@")[0].trim(),
    };

    delete result.title;

    return result;
  });

  if (new Set(results.map((o) => o.id)).size !== results.length) {
    throw new Error("Some items have duplicate ids");
  }

  return results;
};

const data = [
  // Paste the output of `runme()` here
];

console.log(toTsv(clean(data)));
