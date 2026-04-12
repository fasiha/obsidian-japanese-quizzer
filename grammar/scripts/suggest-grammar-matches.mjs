import fs from 'fs';
import path from 'path';

/**
 * Simplified logic to find potential matches using keyword search.
 * It will load 'new-topics.json' and all TSVs, then for each new topic,
 * search for candidate matches based on Japanese and English titles.
 */

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

// 1. Load new topics
const newTopicsPath = path.join(process.cwd(), 'grammar/new-topics.json');
if (!fs.existsSync(newTopicsPath)) {
  console.error('Error: new-topics.json not found. Please run find-new-grammar-topics.mjs first.');
  process.exit(1);
}
const newTopics = JSON.parse(fs.readFileSync(newTopicsPath, 'utf8'));

// 2. Load all TSV data into an index for searching
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
      row: row,
      file: file,
      prefix: prefix
    });
  });
});

// 3. Search for candidates
const potentialMatches = [];

newTopics.forEach(target => {
  const candidates = [];
  
  // We skip the target itself in matches
  const otherData = allData.filter(item => item.id !== target.id);

  // Strategy: keyword search on titles
  // We'll use the Japanese and English titles from the new topic as keywords.
  const keywords = [
    target.titleJP,
    target.titleEN
  ].filter(k => k && k.length > 0);

  for (const item of otherData) {
    let score = 0;
    
    // Exact match for ID (just in case, though unlikely)
    if (item.id === target.id) score += 10;

    // Title-based matching
    if (target.titleJP && item.titleJP === target.titleJP) score += 5;
    if (target.titleEN && item.titleEN === target.titleEN) score += 5;

    // Fuzzy title matches
    if (target.titleJP && item.titleJP.includes(target.titleJP)) score += 2;
    if (target.titleEN && item.titleEN.includes(target.titleEN)) score += 2;
    if (target.titleJP && item.titleEN.includes(target.titleJP)) score += 2;
    if (target.titleEN && item.titleJP.includes(target.titleEN)) score += 2;

    if (score > 0) {
      candidates.push({
        id: item.id,
        score,
        reason: `Matches on: ${target.titleJP || 'N/A'} / ${target.titleEN || 'N/A'}`
      });
    }
  }

  // Sort candidates by score (descending) and take top N
  candidates.sort((a, b) => b.score - a.score);

  if (candidates.length > 0) {
    potentialMatches.push({
      target: target.id,
      candidates: candidates.slice(0, 5).map(c => ({
        id: c.id,
        reason: c.reason
      }))
    });
  }
} );

// 4. Save results
fs.writeFileSync('grammar/potential-matches.json', JSON.stringify(potentialMatches, null, 2));
console.log(`Generated ${potentialMatches.length} potential match groups.`);
