import fs from 'fs';
import path from 'path';
import { callLLM, logLLMInteraction, getDisplayTitle } from './llm-utils.mjs';

/**
 * This script verifies if suggested grammar matches are actually equivalent.
 * It takes 'potential-matches.json' as input and produces 'equivalence-decision.json'.
 */

function generatePrompt(group) {
  const { target, candidates } = group;
  
  let prompt = `You are an expert linguist. Your task is to determine if the following grammar topics are equivalent (i.e., they describe the same grammatical mechanism/use case).\n\n`;
  
  prompt += `### TARGET TOPIC:\n`;
  prompt += `ID: ${target.id}\n`;
  prompt += `Title: ${getDisplayTitle(target.details)}\n`;
  prompt += `Web Content: ${target.webContent || 'No web content available.'}\n\n`;
  
  if (candidates && candidates.length > 0) {
    prompt += `### CANDIDATES:\n`;
    candidates.forEach((candidate, index) => {
      prompt += `\n--- Candidate [${index + 1}] ---\n`;
      prompt += `ID: ${candidate.id}\n`;
      prompt += `Title: ${getDisplayTitle(candidate.details)}\n`;
      prompt += `Web Content: ${candidate.webContent || 'No web content available.'}\n`;
    });
  }
  
  prompt += `\n### INSTRUCTIONS:\n`;
  prompt += `1. Review the details and web content for the target topic and all candidates.\n`;
  prompt += `2. Determine if the target topic is equivalent to any of the candidates.\n`;
  prompt += `3. Provide your response in the following JSON format:\n`;
  prompt += `{\n  "matches": ["id1", "id2"],\n  "reasoning": "Briefly explain why you chose these."\n}\n`;
  prompt += `If no candidates match, the "matches" array should be empty.\n`;

  return prompt;
}

async function verifyGroup(group) {
  const prompt = generatePrompt(group);

  try {
    const choice = await callLLM(prompt);
    const contentResponse = choice.content;
    const parsed = JSON.parse(contentResponse);

    logLLMInteraction('verify-equivalence', prompt, parsed ? JSON.stringify(parsed, null, 1) : contentResponse);

    return parsed;
  } catch (e) {
    console.error(`\x1b[31mLLM call failed for group ${group.target.id}: ${e.message}\x1b[0m`);
    return { matches: [], reasoning: `Error: ${e.message}` };
  }
}

async function main() {
  const dryRun = process.argv.includes('--dry-run');

  // 1. Load potential-matches.json
  const potentialMatchesPath = path.join(process.cwd(), 'grammar/potential-matches.json');
  if (!fs.existsSync(potentialMatchesPath)) {
    console.error('Error: potential-matches.json not found. Please run suggest-grammar-matches.mjs first.');
    process.exit(1);
  }
  const potentialMatches = JSON.parse(fs.readFileSync(potentialMatchesPath, 'utf8'));

  if (potentialMatches.length === 0) {
    console.log('No potential matches to verify.');
    return;
  }

  // We typically process one group at a time in the current pipeline
  const group = potentialMatches[0];
  console.log(`Verifying matches for: ${group.target.id}`);

  if (dryRun) {
    console.log('\x1b[34m--- DRY RUN: LLM PROMPT ---\x1b[0m');
    console.log(generatePrompt(group));
    console.log('\x1b[34m--------------------------\x1b[0m');
    process.exit(0);
  }

  const decision = await verifyGroup(group);
  
  // Construct the final output as per RFC: equivalence-decision.json
  // "group": [target.id, ...matches]
  const finalDecision = {
    group: [group.target.id, ...decision.matches],
    confidence: decision.matches.length > 0 ? 'high' : 'medium',
    reasoning: decision.reasoning
  };

  fs.writeFileSync('grammar/equivalence-decision.json', JSON.stringify(finalDecision, null, 2));
  console.log(`Decision saved to 'grammar/equivalence-decision.json'. Matches found: ${decision.matches.length}`);
}

main();

