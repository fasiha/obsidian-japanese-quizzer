import fs from 'fs';
import path from 'path';

/**
 * This script aggregates the necessary data from the TSV index to provide 
 * complete context to the LLM for a specific comparison.
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

// 1. Load potential-matches.json
const potentialMatchesPath = path.join(process.cwd(), 'grammar/potential-matches.json');
if (!fs.existsSync(potentialMatchesPath)) {
  console.error('Error: potential-matches.json not found.');
  process.exit(1);
}
const potentialMatches = JSON.parse(fs.readFileSync(potentialMatchesPath, 'utf8'));

// 2. Load all TSV data into a searchable index
const directory = path.join(process.cwd(), 'grammar');
const files = fs.readdirSync(directory).filter(f => f.endsWith('.tsv'));
const index = new Map();

files.forEach(file => {
  const data = readTSV(path.join(directory, file));
  const prefix = getSourcePrefix(file);
  data.forEach(row => {
    const fullId = `${prefix}:${row.id}`;
    index.set(fullId, {
      id: fullId,
      titleJP: row['title-jp'] || '',
      titleEN: row['title-en'] || '',
      ...row 
    });
  });
});

// 3. Gather reference content
const referenceContent = [];

potentialMatches.forEach(group => {
  const targetId = group.target;
  const targetData = index.get(targetId);
  
  const candidates = group.candidates.map(c => {
    const data = index.get(c.id);
    return data ? { id: c.id, details: data } : null;
  }).filter(Boolean);

  if (targetData) {
    referenceContent.push({
      target: {
        id: targetId,
        details: targetData
      },
      candidates: candidates
    });
  }
});

// 4. Save results
fs.writeFileSync('grammar/reference-content.json', JSON.stringify(referenceContent, null, 2));
console.log(`Gathered reference content for ${referenceContent.length} groups.`);
