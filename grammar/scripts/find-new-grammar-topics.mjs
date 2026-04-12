import fs from 'fs';
import path from 'path';

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

// Get the target topic from command line arguments
const targetTopic = process.argv[2];
if (!targetTopic) {
  console.error('Usage: node find-new-grammar-topics.mjs <topic-id>');
  process.exit(1);
}

// Load existing topics from equivalences
const equivalencesPath = path.join(process.cwd(), 'grammar/grammar-equivalences.json');
const equivalences = JSON.parse(fs.readFileSync(equivalencesPath, 'utf8'));
const existingTopics = new Set();
equivalences.forEach(group => {
  group.topics.forEach(topic => {
    existingTopics.add(topic);
  });
});

if (existingTopics.has(targetTopic)) {
  fs.writeFileSync('grammar/new-topics.json', JSON.stringify([], null, 2));
  console.log(`Topic ${targetTopic} is already in grammar-equivalences.json. Writing empty list.`);
  process.exit(0);
}

// Get all TSVs
const directory = path.join(process.cwd(), 'grammar');
const files = fs.readdirSync(directory).filter(f => f.endsWith('.tsv'));

const newTopics = [];

files.forEach(file => {
  const prefix = getSourcePrefix(file);
  if (!prefix) return;
  const data = readTSV(path.join(directory, file));
  
  data.forEach(row => {
    const id = row.id;
    if (!id) return;
    
    const fullId = `${prefix}:${id}`;
    
    if (fullId === targetTopic) {
      newTopics.push({
        id: fullId,
        source: prefix,
        originalId: id,
        titleJP: row['title-jp'] || '',
        titleEN: row['title-en'] || '',
        href: row['href'] || '',
        file: file
      });
    }
  });
});

fs.writeFileSync('grammar/new-topics.json', JSON.stringify(newTopics, null, 2));
console.log(`Found ${newTopics.length} new topic(s).`);

