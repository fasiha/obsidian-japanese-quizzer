import fs from 'fs';
import path from 'path';

function getSourcePrefix(fileName) {
  const match = fileName.match(/grammar-(.*?)\.tsv|kanshudo-grammar\.tsv/);
  if (!match) return '';
  return match[1] || 'kanshudo';
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

// Load existing topics from equivalences
const equivalencesPath = path.join(process.cwd(), 'grammar/grammar-equivalences.json');
const equivalences = JSON.parse(fs.readFileSync(equivalencesPath, 'utf8'));
const existingTopics = new Set();
equivalences.forEach(group => {
  group.topics.forEach(topic => {
    existingTopics.add(topic);
  });
});

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
    
    // We'll assume the ID in the JSON matches the prefix:id 
    // or we need to check if the ID is already present in a different form.
    // For now, let's just use prefix:id
    const fullId = `${prefix}:${id}`;
    
    if (!existingTopics.has(fullId)) {
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

// In a real scenario, we'd need to handle the fact that 'bunpro:adjective-て-noun-de' 
// might not be 'bunpro:adjective-te-noun-de' (Romanization/slugification).
// But let's start with this.

fs.writeFileSync('grammar/new-topics.json', JSON.stringify(newTopics, null, 2));
console.log(`Found ${newTopics.length} new topics.`);
