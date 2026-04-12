import fs from 'fs';
import path from 'path';

function readTSV(filePath) {
  const content = fs.readFileSync(filePath, 'utf8');
  const lines = content.split('\n');
  const headers = lines[0].trim().split('\t');
  const data = [];
  for (let i = 1; i < lines.length; i++) {
    if (!lines[i].trim()) continue;
    const row = lines[i].trim().split('\t');
    const entry = {};
    headers.forEach((header, index) => {
      entry[header] = row[index];
    });
    data.push(entry);
  }
  return data;
}

console.log('Reading bunpro:', readTSV('grammar/grammar-bunpro.tsv').slice(0, 2));
console.log('Reading dbjg:', readTSV('grammar/grammar-dbjg.tsv').slice(0, 2));
