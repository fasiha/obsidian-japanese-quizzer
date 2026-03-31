var document;

/** Run this in the browser at https://www.kanshudo.com/grammar/overview to generate `data` */
var runme = (() => {
  /** Convert an array of objects into a TSV (tab-separated values) */
  const toTsv = (data) => {
    const comment = `# Generated on ${new Date().toISOString()} from https://www.kanshudo.com/grammar/overview`;
    const header = Object.keys(data[0] ?? {}).join("\t");
    const body = data.map((row) => Object.values(row).join("\t")).join("\n");
    return `${comment}\n${header}\n${body}`;
  };

  // Each grammar entry is a .gp_search div containing:
  //   .details-link  — href="/grammar/SLUG" (the canonical URL slug)
  //   .gp_url a      — id="gp_link_XXXX" (internal Kanshudo ID), text = Japanese title
  //   .gp_sum        — English gloss
  //   .jlpt_container (optional) — onclick="jlptClicked(ID, N)" where N is the JLPT level
  //   .ufn_container  (optional) — onclick="ufnGrammarClicked('...', N)" where N is UFN level
  const items = [];

  for (const el of document.querySelectorAll(".gp_search[data-item='g']")) {
    const detailsLink = el.querySelector("a.details-link");
    if (!detailsLink) continue;

    const href = detailsLink.getAttribute("href") ?? "";
    const fullUrl = "https://www.kanshudo.com" + href;
    // Decode the URL-encoded path segment to a human-readable id (e.g. "%E3%80%85" → "々")
    const slug = href.split("/").at(-1) ?? "";

    const urlAnchor = el.querySelector(".gp_url a");
    const title = urlAnchor?.textContent?.trim() ?? "";

    const gloss = el.querySelector(".gp_sum")?.textContent?.trim() ?? "";

    // JLPT level: read from the span class inside .jlpt_container, e.g. "ja-jlpt_5" → "N5"
    const jlptSpan = el.querySelector(".jlpt_container span");
    const jlptMatch = jlptSpan?.className?.match(/ja-jlpt_(\d+)/);

    // UFN (Useful for Newcomers) level: read from span class, e.g. "ja-ufn_1" → "Useful1"
    const ufnSpan = el.querySelector(".ufn_container span");
    const ufnMatch = ufnSpan?.className?.match(/ja-ufn_(\d+)/);

    // Collapse JLPT and UFN into a single level string, matching the convention of the other TSVs.
    // JLPT takes priority; UFN is used as fallback; blank if neither is present.
    const jlpt = jlptMatch ? "N" + jlptMatch[1] : "";
    const ufn = ufnMatch ? "Useful" + ufnMatch[1] : "";
    const level = [jlpt, ufn].filter(Boolean).join(" ");

    // Decode the URL-encoded slug to a human-readable id (e.g. "%E3%80%85" → "々", "passive_voice" → "passive_voice")
    const id = decodeURIComponent(slug);

    items.push({ id, href: fullUrl, level, title, gloss });
  }

  copy(toTsv(items));
  return items;
})();
