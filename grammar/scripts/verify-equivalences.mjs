import fs from 'fs';
import path from 'path';

const LOCAL_LLM_URL = 'http://localhost:8080/v1/chat/completions';
const MODEL = 'gemma-4-31b-it-4bit'; // Verifier role

/**
 * This script verifies if suggested grammar matches are actually equivalent.
 * It takes 'potential-matches.json' as input and produces 'equivalence-decision.json'.
 */

function generatePrompt(group) {
  const { target, candidates } = group;
  
  let prompt = `You are an expert linguist. Your task is to determine if the following grammar topics are equivalent (i.e., they describe the same grammatical mechanism/use case).\n\n`;
  
  prompt += `### TARGET TOPIC:\n`;
  prompt += `ID: ${target.id}\n`;
  prompt += `Title: ${target.details?.titleJP || ''} / ${target.details?.titleEN || ''}\n`;
  prompt += `Web Content: ${target.webContent || 'No web content available.'}\n\n`;
  
  if (candidates && candidates.length > 0) {
    prompt += `### CANDIDATES:\n`;
    candidates.forEach((candidate, index) => {
      prompt += `\n--- Candidate [${index + 1}] ---\n`;
      prompt += `ID: ${candidate.id}\n`;
      prompt += `Title: ${candidate.details?.titleJP || ''} / ${candidate.details?.titleEN || ''}\n`;
      prompt += `Web Content: ${candidate.webContent || 'No web content available.'}\n`;
    });
  }
  
  prompt += `\n### INSTRUCTIONS:\n`;
  prompt += `1. Review the details and web content for the target topic and all candidates.\n`;
  prompt += `2. Determine if the target topic is equivalent to any of the candidates.\n`;
  prompt += `3. Provide your response in the following JSON format:\n`;
  prompt += `{\n  "matches": ["id1", "id2"],\n  "reasoning": "Briefly explain why these are or are not matches."\n}\n`;
  prompt += `If no candidates match, the "matches" array should be empty.\n`;

  return prompt;
}

async function verifyGroup(group) {
  const prompt = generatePrompt(group);

  try {
    const res = await fetch(LOCAL_LLM_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: MODEL,
        messages: [{ role: 'user', content: prompt }],
        response_format: { type: 'json_object' }
      }),
    });

    const data = await res.json();
    const contentResponse = data.choices[0].message.content;
    const parsed = JSON.parse(contentResponse);

    // Save audit log
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
    const logPath = path.join(process.cwd(), `grammar/verify-equivalence-${timestamp}.md`);
    const logContent = `# VERIFICATION
Model: ${MODEL}
Timestamp: ${new Date().toISOString()}

# PROMPT
${prompt}

# RESPONSE
${contentResponse}
`;
    fs.writeFileSync(logPath, logContent);

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

