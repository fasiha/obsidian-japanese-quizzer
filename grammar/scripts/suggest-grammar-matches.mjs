/**
 * suggest-grammar-matches.mjs
 * 
 * Analyzes a target grammar topic from new-topics.json and suggests potential 
 * matches from existing TSV grammar databases using an LLM.
 * 
 * Flags:
 *  --dry-run             : Print the LLM prompt for the target topic and exit.
 *  --skip-extra-fetches  : Skip fetching web content for the suggested candidates.
 *  --web-content "TEXT"  : Use the provided text as the web content for the target topic, 
 *                          bypassing the automated fetch.
 */
import fs from 'fs';
import path from 'path';
import { callLLM, fetchWebContent, logLLMInteraction, getDisplayTitle } from './llm-utils.mjs';

function getSourcePrefix(fileName) {
  const match = fileName.match(/grammar-(.*?)\.tsv|kanshudo-grammar\.tsv/);
  if (!match) return '';
  let prefix = match[1] || 'kanshudo';
  if (prefix === 'stolaf-genki') prefix = 'genki';
  return prefix;
}

function readTSV(filePath) {
  const content = fs.readFileSync(filePath, 'utf8');
  const lines = content.split('\n');
  let headerIndex = -1;
  for (let i = 0; i < lines.length; i++) {
    const trimmed = lines[i].trim();
    if (trimmed.startsWith('id') && !trimmed.startsWith('#')) {
      headerIndex = i;
      break;
    }
  }
  if (headerIndex === -1) return [];
  const headers = lines[headerIndex].trim().split('\t');
  const data = [];
  for (let i = headerIndex + 1; i < lines.length; i++) {
    const trimmed = lines[i].trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const row = trimmed.split('\t');
    const entry = {};
    headers.forEach((header, index) => {
      entry[header] = row[index];
    });
    data.push(entry);
  }
  return data;
}

async function generateSearchTerms(target, content, dryRun = false) {
  const prompt = `You are a Japanese linguistic search strategist. 
Your goal is to help find equivalent grammar entries across different databases (Bunpro, Genki, etc.).

Target Topic Information:
- Slug: ${target.id}
- Japanese Title: ${target.titleJP}
- English Title: ${target.titleEN}
- Web Content: ${content.substring(0, 10000)} // Limit content for context window

Task:
1. Analyze the grammar mechanism described.
2. Generate a list of search fragments (stems, la-patterns, kanji, and Romaji) that would likely appear in the title or description of an equivalent entry in another database.
3. Include variations in politeness (e.g., kudasai vs itadakemasen) and orthography (Hiragana, Kanji, Romaji).
4. If the web content is completely irrelevant or empty, return a JSON object with an "error" field.

Response Format:
Return ONLY a JSON object in this format:
{
  "fragments": ["fragment1", "fragment2", "fragment3", ...],
  "reasoning": "Short explanation of why these fragments were chosen."
}
OR
{
  "error": "Reason why the content is irrelevant"
}
`;

  if (dryRun) {
    console.log('\x1b[34m--- DRY RUN: LLM PROMPT ---\x1b[0m');
    console.log(prompt);
    console.log('\x1b[34m--------------------------\x1b[0m');
    process.exit(0);
  }

  try {
    const choice = await callLLM(prompt);
    const contentResponse = choice.content;
    let parsed;
    let parseError = null;

    try {
      parsed = JSON.parse(contentResponse);
    } catch (e) {
      parseError = e;
    }

    logLLMInteraction('suggest-grammar-matches', prompt, parsed ? JSON.stringify(parsed, null, 1) : contentResponse);

    if (parseError) {
      console.error(`\x1b[31mLLM generated malformed JSON: ${parseError.message}\x1b[0m`);
      process.exit(1);
    }

    if (parsed.error) {
      console.error(`\x1b[31mLLM reported irrelevant content: ${parsed.error}\x1b[0m`);
      process.exit(1);
    }

    return parsed.fragments;
  } catch (e) {
    console.error(`\x1b[31mLLM call failed: ${e.message}\x1b[0m`);
    process.exit(1);
  }
}

function normalizeFragment(s) {
  return s.replaceAll(/[\p{P}\p{S}\s]/ug, '').toLowerCase();
}

async function main() {
  const dryRun = process.argv.includes('--dry-run');
  const skipExtraFetches = process.argv.includes('--skip-extra-fetches');

  // Parse --web-content flag
  let webContentOverride = null;
  const webContentIndex = process.argv.findIndex(arg => arg.startsWith('--web-content='));
  if (webContentIndex !== -1) {
    webContentOverride = process.argv[webContentIndex].split('=')[1];
  } else {
    const webContentFlagIndex = process.argv.indexOf('--web-content');
    if (webContentFlagIndex !== -1 && process.argv[webContentFlagIndex + 1]) {
      webContentOverride = process.argv[webContentFlagIndex + 1];
    }
  }

  // 1. Load new topics
  const newTopicsPath = path.join(process.cwd(), 'grammar/new-topics.json');
  if (!fs.existsSync(newTopicsPath)) {
    console.error('Error: new-topics.json not found. Please run find-new-grammar-topics.mjs first.');
    process.exit(1);
  }
  const newTopics = JSON.parse(fs.readFileSync(newTopicsPath, 'utf8'));

  if (newTopics.length === 0) {
    console.log('No new topics to process.');
    fs.writeFileSync('grammar/potential-matches.json', JSON.stringify([], null, 2));
    return;
  }

  // Process only the first new topic (since we now work on one at a time)
  const target = newTopics[0];
  console.log(`Targeting: ${target.id} (${getDisplayTitle(target)})`);

  // 2. Fetch Web Content
  const webContent = webContentOverride ?? await fetchWebContent(target.href);

  // 3. Generate Search Terms using LLM
  console.log(`Generating search terms using LLM...`);
  const fragments = await generateSearchTerms(target, webContent, dryRun, skipExtraFetches);
  console.log(`Search fragments generated: ${fragments.join(', ')}`);

  // 4. Broad Search in TSVs
  const directory = path.join(process.cwd(), 'grammar');
  const files = fs.readdirSync(directory).filter(f => f.endsWith('.tsv'));
  const allData = [];

  files.forEach(file => {
    const data = readTSV(path.join(directory, file));
    const prefix = getSourcePrefix(file);
    data.forEach(row => {
      const fullId = `${prefix}:${row.id}`;
      allData.push({
        ...row,
        id: fullId,
        prefix: prefix
      });
    });
  });

  const candidates = [];
  for (const item of allData) {
    if (item.id === target.id) continue;

    let matchCount = 0;
    let matchedFragments = [];

    for (const fragment of fragments) {
      const f = normalizeFragment(fragment)
      const found = [item['title-jp'], item['title-en'], item.title, item.id].some(x => x && normalizeFragment(x).includes(f))
      if (found) {
        console.log(`Fragment found: ${f} in [${item.id}]`)
        matchCount++;
        matchedFragments.push(fragment);
      }
    }

    if (matchCount > 0) {
      candidates.push({
        id: item.id,
        score: matchCount,
        reason: `Matches fragments: ${matchedFragments.join(', ')}`,
        details: item
      });
    }
  }

  // Sort candidates by score (descending) and take top 5
  candidates.sort((a, b) => b.score - a.score);

  const topCandidates = candidates.slice(0, 25);

  // Fetch web content for candidates that have a reference URL
  const enrichedCandidates = [];
  for (const c of topCandidates) {
    let webContent = '';
    if (c.details.href && !skipExtraFetches) {
      try {
        webContent = await fetchWebContent(c.details.href);
        await new Promise((resolve) => {
          const sleeping = Math.ceil(250 + 250 * Math.random());
          setTimeout(resolve, sleeping)
        });
      } catch (e) {
        console.error(`\x1b[33mWarning: Failed to fetch content for candidate ${c.id}: ${e.message}\x1b[0m`);
      }
    }
    enrichedCandidates.push({
      id: c.id,
      reason: c.reason,
      details: c.details,
      webContent: webContent
    });
  };

  const potentialMatches = [{
    target: {
      ...target,
      webContent: webContent
    },
    candidates: enrichedCandidates
  }];

  // 5. Save results
  fs.writeFileSync('grammar/potential-matches.json', JSON.stringify(potentialMatches, null, 2));
  console.log(`Generated ${potentialMatches.length} potential match group(s) with ${candidates.length} total candidates.`);
}

main();
