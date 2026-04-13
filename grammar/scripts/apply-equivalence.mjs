import fs from 'fs';
import path from 'path';

/**
 * This script applies the LLM's equivalence decisions to the main grammar-equivalences.json file.
 * It merges newly discovered equivalents into existing groups or creates new ones.
 */

function mergeGroups(existingGroups, newGroup) {
  let activeGroup = new Set(newGroup);
  let bestGroupMetadata = null;

  function updateBestMetadata(group) {
    if (!group || Array.isArray(group)) return;
    
    if (!bestGroupMetadata) {
      bestGroupMetadata = group;
      return;
    }
    
    // If the current best doesn't have a summary, but this one does, update.
    if (!bestGroupMetadata.summary && group.summary) {
      bestGroupMetadata = group;
      return;
    }
    
    // If both have summaries, keep the longer one.
    if (bestGroupMetadata.summary && group.summary && group.summary.length > bestGroupMetadata.summary.length) {
      bestGroupMetadata = group;
    }
  }

  // Find any existing groups that intersect with the new group
  const remainingGroups = [];
  for (const group of existingGroups) {
    const topics = Array.isArray(group) ? group : group.topics;
    const groupSet = new Set(topics);
    
    if ([...groupSet].some(t => activeGroup.has(t))) {
      groupSet.forEach(t => activeGroup.add(t));
      updateBestMetadata(group);
    } else {
      remainingGroups.push(group);
    }
  }
  
  // We need to handle the case where merging the newGroup with one existing group
  // now makes it intersect with another existing group that didn't intersect before.
  // So we repeat the process until no more changes occur.
  let changed = true;
  let finalGroups = remainingGroups;
  
  while (changed) {
    changed = false;
    const nextGroups = [];
    for (const group of finalGroups) {
      const topics = Array.isArray(group) ? group : group.topics;
      const groupSet = new Set(topics);
      if ([...groupSet].some(t => activeGroup.has(t))) {
        groupSet.forEach(t => activeGroup.add(t));
        updateBestMetadata(group);
        changed = true;
      } else {
        nextGroups.push(group);
      }
    }
    finalGroups = nextGroups;
  }
  
  // Construct final list, converting the merged Set back to a group object
  const mergedGroup = {
    topics: [...activeGroup]
  };

  if (bestGroupMetadata) {
    if (bestGroupMetadata.summary) mergedGroup.summary = bestGroupMetadata.summary;
    if (bestGroupMetadata.subUses) mergedGroup.subUses = bestGroupMetadata.subUses;
    if (bestGroupMetadata.cautions) mergedGroup.cautions = bestGroupMetadata.cautions;
    if (bestGroupMetadata.stub !== undefined) mergedGroup.stub = bestGroupMetadata.stub;
  }
  
  return [...finalGroups, mergedGroup];
}

async function run() {
  const decisionPath = path.join(process.cwd(), 'grammar/equivalence-decision.json');
  const equivPath = path.join(process.cwd(), 'grammar/grammar-equivalences.json');
  
  if (!fs.existsSync(decisionPath)) {
    console.error('Error: equivalence-decision.json not found.');
    process.exit(1);
  }
  
  const decisions = JSON.parse(fs.readFileSync(decisionPath, 'utf8'));
  let equivalences = [];
  if (fs.existsSync(equivPath)) {
    equivalences = JSON.parse(fs.readFileSync(equivPath, 'utf8'));
  }
  
  // Normalize existing equivalences to objects
  equivalences = equivalences.map(g => Array.isArray(g) ? { topics: g } : g);
  
  for (const decision of decisions) {
    // Only apply if the group has more than one topic (it's actually an equivalence)
    if (decision.group.length > 1) {
      equivalences = mergeGroups(equivalences, decision.group);
    }
  }
  
  // Deduplicate: occasionally multiple decisions might create redundant groups
  // Though our mergeGroups should handle most of it.
  
  fs.writeFileSync(equivPath, JSON.stringify(equivalences, null, 2));
  console.log(`Updated ${equivPath} with new equivalence groups.`);
}

run();
