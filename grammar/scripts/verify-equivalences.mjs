import fs from 'fs';
import path from 'path';

/**
 * This script generates prompts for the LLM to perform the verification task.
 * It takes 'reference-content.json' as input.
 */

function generatePrompt(group) {
  const { target, candidates } = group;
  
  let prompt = `You are an expert linguist. Your task is to determine if the following grammar topics are equivalent (i.e., they describe the same grammatical mechanism/use case).\n\n`;
  
  prompt += `### TARGET TOPIC:\n`;
  prompt += `ID: ${target.id}\n`;
  prompt += `Title: ${target.details.titleJP || ''} / ${target.details.titleEN || ''}\n`;
  prompt += `Details: ${JSON.stringify(target.details, null, 2)}\n\n`;
  
  if (candidates && candidates.length > 0) {
    prompt += `### CANDIDATES:\n`;
    candidates.forEach((candidate, index) => {
      prompt += `\n[${index + 1}] ID: ${candidate.id}\n`;
      prompt += `Title: ${candidate.details.titleJP || ''} / ${candidate.details.titleEN || ''}\n`;
      prompt += `Details: ${JSON.stringify(candidate.details, null, 2)}\n`;
    });
  }
  
  prompt += `\n### INSTRUCTIONS:\n`;
  prompt += `1. Review the details for the target topic and all candidates.\n`;
  prompt += `2. Determine if the target topic is equivalent to any of the candidates.\n`;
  prompt += `3. Provide your response in the following JSON format:\n`;
  prompt += `{\n  "matches": ["id1", "id2"],\n  "reasoning": "Briefly explain why these are or are not matches."\n}\n`;
  prompt += `If no candidates match, the "matches" array should be empty.\n`;

  return prompt;
}

// 1. Load reference-content.json
const referenceContentPath = path.join(process.cwd(), 'grammar/reference-content.json');
if (!fs.existsSync(referenceContentPath)) {
  console.error('Error: reference-content.json not found.');
  process.exit(1);
}
const referenceContent = JSON.parse(fs.readFileSync(referenceContentPath, 'utf8'));

// 2. Generate prompts
const prompts = referenceContent.map((group, index) => ({
  index,
  group,
  prompt: generatePrompt(group)
}));

// 3. Save results
fs.writeFileSync('grammar/prompts-for-verification.json', JSON.stringify(prompts, null, 2));
console.log(`Generated ${prompts.length} prompts for verification in 'grammar/prompts-for-verification.json'.`);
