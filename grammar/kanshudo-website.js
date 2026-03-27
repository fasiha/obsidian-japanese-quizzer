var document;

/** Run this in the browser at https://www.kanshudo.com/grammar/index to generate `data` */
var runme = (() => {
  /** Convert an array of objects into a TSV (tab-separated values) */
  const toTsv = (data) => {
    const comment = `# Generated on ${new Date().toISOString()} from https://www.kanshudo.com/grammar/index`;
    const header = Object.keys(data[0] ?? {}).join("\t");
    const body = data.map((row) => Object.values(row).join("\t")).join("\n");
    return `${comment}\n${header}\n${body}`;
  };

  // Walk through the page, tracking the current JLPT level via section headers.
  // Each section header is a .title1 div with an id like "sectionjlpt5", "sectionjlpt4", etc.
  // Grammar entries are .gp_mini divs that follow those headers inside .gp_grid containers.
  const items = [];
  let currentLevel = "";

  for (const el of document.querySelectorAll(".title1[id^='section'], .gp_mini")) {
    if (el.classList.contains("title1")) {
      // e.g. id="sectionjlpt5" → level="N5", id="sectionufn3" → level="Useful3"
      const jlpt = el.id.match(/sectionjlpt(\d+)/);
      const useful = el.id.match(/sectionufn(\d+)/);
      currentLevel = jlpt ? "N" + jlpt[1] : useful ? "Useful" + useful[1] : "";
    } else {
      // .gp_mini entry
      const a = el.querySelector("a");
      if (!a) continue;

      const href = a.getAttribute("href") ?? "";
      const id = href.split("/").at(-1) ?? "";
      const fullUrl = "https://www.kanshudo.com" + href;

      // The anchor text is "title&nbsp; gloss" — split on the non-breaking space
      const rawText = a.innerText ?? "";
      const parts = rawText.split(/\u00a0+/);
      const title = parts[0]?.trim() ?? "";
      const gloss = parts.slice(1).join(" ").trim();

      items.push({ id, href: fullUrl, level: currentLevel, title, gloss });
    }
  }

  copy(toTsv(items));
  return items;
})();
