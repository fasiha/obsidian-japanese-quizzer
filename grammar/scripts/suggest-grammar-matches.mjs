import fs from 'fs';
import path from 'path';
import { JSDOM } from 'jsdom';

const LOCAL_LLM_URL = 'http://localhost:8080/v1/chat/completions';
const MODEL = 'gemma-4-31b-it-4bit'; // Use smarter model for strategy

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

async function fetchWebContent(url) {
  try {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`HTTP error! status: ${response.status}`);
    const html = await response.text();
    const dom = new JSDOM(html);
    
    // Extract text from body, removing scripts and styles
    const body = dom.window.document.body;
    const scripts = body.querySelectorAll('script, style');
    scripts.forEach(s => s.remove());
    
    return body.textContent.trim().replace(/\\s+/g, ' ');
  } catch (e) {
    console.error(`\x1b[31mFailed to fetch web content from ${url}: ${e.message}\x1b[0m`);
    process.exit(1);
  }
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
    const res = await fetch(LOCAL_LLM_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: MODEL,
        messages: [{ role: 'user', content: prompt }],
        temperature: 0.2,
        response_format: { type: 'json_object' }
      }),
    });

    const data = await res.json();
    const choice = data.choices[0].message;
    const contentResponse = choice.content;
    let parsed;
    let parseError = null;

    try {
      parsed = JSON.parse(contentResponse);
    } catch (e) {
      parseError = e;
    }

    // Save audit log
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
    const logPath = path.join(process.cwd(), `grammar/suggest-grammar-matches-${timestamp}.md`);
    const logContent = `# FLAGS
Model: ${MODEL}
Timestamp: ${new Date().toISOString()}

# PROMPT
${prompt}

# RESPONSE
Reasoning:
${parsed?.reasoning || choice.reasoning_content || 'N/A'}

Content:
${parseError ? contentResponse : JSON.stringify(parsed, null, 2)}
`;
    fs.writeFileSync(logPath, logContent);

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

async function main() {
  const dryRun = process.argv.includes('--dry-run');

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
  console.log(`Targeting: ${target.id} (${target.titleJP} / ${target.titleEN})`);

  // 2. Fetch Web Content
  console.log(`Fetching web content from ${target.href}...`);
  const webContent = await fetchWebContent(target.href);

  // 3. Generate Search Terms using LLM
  console.log(`Generating search terms using LLM...`);
  const fragments = await generateSearchTerms(target, webContent, dryRun);
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
        id: fullId,
        titleJP: row['title-jp'] || '',
        titleEN: row['title-en'] || '',
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
      if (item.titleJP.toLowerCase().includes(fragment.toLowerCase()) || 
          item.titleEN.toLowerCase().includes(fragment.toLowerCase())) {
        matchCount++;
        matchedFragments.push(fragment);
      }
    }

    if (matchCount > 0) {
      candidates.push({
        id: item.id,
        score: matchCount,
        reason: `Matches fragments: ${matchedFragments.join(', ')}`
      });
    }
  }

  // Sort candidates by score (descending) and take top 5
  candidates.sort((a, b) => b.score - a.score);
  
  const potentialMatches = [{
    target: target.id,
    candidates: candidates.slice(0, 5).map(c => ({
      id: c.id,
      reason: c.reason
    }))
  }];

  // 5. Save results
  fs.writeFileSync('grammar/potential-matches.json', JSON.stringify(potentialMatches, null, 2));
  console.log(`Generated ${potentialMatches.length} potential match group(s) with ${candidates.length} total candidates.`);
}

main();
