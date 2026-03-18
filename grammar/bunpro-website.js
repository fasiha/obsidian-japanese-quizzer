var document;

/** Run this in the browser at https://bunpro.jp/grammar_points to generate `data` */
var runme = (() => {
  /** Convert an array of objects into a TSV (tab-separated values) */
  const toTsv = (data) => {
    const comment = `# Generated on ${new Date().toISOString()} from https://bunpro.jp/grammar_points`;
    const header = Object.keys(data[0] ?? {}).join("\t");
    const body = data.map((row) => Object.values(row).join("\t")).join("\n");
    return `${comment}\n${header}\n${body}`;
  };

  const items = [...document.querySelectorAll('[id^="grammar_point-"]')].map(
    (o) => {
      var a = o.querySelector("a");
      var href = decodeURIComponent(a.href);
      var id = href.split("/").at(-1);

      var titleJpMain = o.querySelector("h4")?.innerText ?? "";
      var titleJpReading =
        o.querySelector("p.text-tertiary-fg")?.innerText ?? "";
      var titleJp = titleJpReading
        ? titleJpMain + " → " + titleJpReading
        : titleJpMain;

      var titleEn = o.querySelector("p.text-secondary-fg")?.innerText ?? "";

      var badgeText = o.querySelector("ul span span")?.innerText?.trim() ?? "";
      var option;
      var kansaiMatch = badgeText.match(/^関西弁 Lesson (\d+)/);
      if (kansaiMatch) {
        option = "関西弁" + kansaiMatch[1];
      } else {
        option = badgeText.match(/N\d+/) ? badgeText.split(":")[0] : badgeText; // e.g. "N5", "N4", etc.
      }

      return { id, href, option, "title-jp": titleJp, "title-en": titleEn };
    },
  );
  copy(toTsv(items));
  return items;
})();
