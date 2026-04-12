import fs from 'fs';
import path from 'path';

/**
 * This script applies the drafted linguistic descriptions to the main grammar-equivalences.json file.
 */

async function run() {
  const draftPath = path.join(process.cwd(), 'grammar/description-draft.json');
  const equivPath = path.join(process.cwd(), 'grammar/grammar-equivalences.json');
  
  if (!fs.existsSync(draftPath)) {
    console.error('Error: description-draft.json not found.');
    process.exit(1);
  }
  if (!fs.existsSync(equivPath)) {
    console.error('Error: grammar-equivalences.json not found.');
    process.exit(1);
  }
  
  const drafts = JSON.parse(fs.readFileSync(draftPath, 'utf8'));
  const equivalences = JSON.parse(fs.readFileSync(equivPath, 'utf8'));
  
  for (const draft of drafts) {
    const group = equivalences[draft.groupIndex];
    if (!group) continue;
    
    const { summary, subUses, cautions, stub } = draft.description;
    
    if (summary) group.summary = summary;
    if (subUses) group.subUses = subUses;
    if (cautions) group.cautions = cautions;
    if (stub !== undefined) group.stub = stub;
  }
  
  fs.writeFileSync(equivPath, JSON.stringify(equivalences, null, 2));
  console.log(`Updated ${equivPath} with synthesized descriptions.`);
}

run();
