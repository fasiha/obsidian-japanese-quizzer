var runme = (() => {
  const toTsv = (data) => {
    const comment = `# Generated on ${new Date().toISOString()} from https://www.tofugu.com/japanese-grammar/`;
    const header = Object.keys(data[0] ?? {}).join("\t");
    const body = data.map((row) => Object.values(row).join("\t")).join("\n");
    return `${comment}\n${header}\n${body}`;
  };

  const items = [];

  for (const el of document.querySelectorAll(".article-index-item")) {
    // Extract the URL and slug from the link
    const link = el.querySelector("a");
    if (!link) continue;

    const href = link.getAttribute("href") ?? "";
    // Assuming href is "/japanese-grammar/particle-ka/" or similar
    const slug = href.split("/").filter(Boolean).at(-1) ?? "";
    const fullUrl = "https://www.tofugu.com" + href;

    // Title is typically in an h3 or heading inside the item
    const title =
      el.querySelector("h3, h4, [class*='title']")?.textContent?.trim() ?? "";

    // Gloss/description is typically in a p tag
    const gloss = el.querySelector("p")?.textContent?.trim() ?? "";

    const id = decodeURIComponent(slug);

    items.push({ id, href: fullUrl, title, gloss });
  }

  copy(toTsv(items));
  console.log(`Extracted ${items.length} grammar points`);
  return items;
})();
