import fs from 'fs';
import path from 'path';
import Anthropic from "@anthropic-ai/sdk";

/**
 * This script synthesizes a high-quality linguistic description for a group of 
 * equivalent grammar topics using reference content.
 */

function generateDescriptionPrompt(group, referenceData) {
  const { topics } = group;
  
  // Gather all reference content for all topics in the group
  const allRefs = [];
  topics.forEach(topicId => {
    const ref = referenceData.find(r => r.target.id === topicId);
    if (ref) {
      allRefs.push({
        id: topicId,
        details: ref.target.details
      });
    }
  });

  let prompt = `You are a professional Japanese linguist and educator. Your goal is to create a definitive, clear, and concise description for a grammatical mechanism that is shared across several reference sources.\n\n`;
  
  prompt += `### REFERENCE DATA:\n`;
  allRefs.forEach(ref => {
    prompt += `\nSource ID: ${ref.id}\nDetails: ${JSON.stringify(ref.details, null, 2)}\n`;
  });
  
  prompt += `\n### TASK:\n`;
  prompt += `Create a comprehensive yet concise entry for this grammar point. The output must be structured as a JSON object with the following fields:\n\n`;
  prompt += `1. "summary": A 1-2 sentence high-level explanation of what this grammar point does. Focus on the "core" mechanism.\n`;
  prompt += `2. "subUses": An array of strings. Each string should describe a specific nuance, a common pattern, or a particular context where this grammar is used.\n`;
  prompt += `3. "cautions": An array of strings. Each string should be a "positive" rule to avoid mistakes (e.g., "Only used with verbs in the dictionary form", NOT "Don't use with nouns").\n`;
  prompt += `4. "stub": (Boolean) Set to true if the reference data is too sparse to provide a high-quality description.\n\n`;
  
  prompt += `### GUIDELINES:\n`;
  prompt += `- Be precise. Use linguistic terms correctly but keep explanations accessible.\n`;
  prompt += `- Avoid quoting the reference sources verbatim; synthesize a new, better explanation.\n`;
  prompt += `- If the sources contradict each other, provide the most generally accepted explanation.\n`;
  prompt += `- Ensure "subUses" and "cautions" are distinct and additive.\n\n`;
  
  prompt += `Response must be a single JSON code block:\n`;
  prompt += `\`\`\`json\n{\n  "summary": "...",\n  "subUses": ["...", "..."],\n  "cautions": ["...", "..."],\n  "stub": false\n}\n\`\`\``;

  return prompt;
}

async function run() {
  const anthropic = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });
  
  const equivPath = path.join(process.cwd(), 'grammar/grammar-equivalences.json');
  const refPath = path.join(process.cwd(), 'grammar/reference-content.json');
  
  if (!fs.existsSync(equivPath) || !fs.existsSync(refPath)) {
    console.error('Error: Missing required input files (equivalences or reference-content).');
    process.exit(1);
  }
  
  const equivalences = JSON.parse(fs.readFileSync(equivPath, 'utf8'));
  const referenceData = JSON.parse(fs.readFileSync(refPath, 'utf8'));
  
  const descriptions = [];
  
  for (let i = 0; i < equivalences.length; i++) {
    const group = equivalences[i];
    
    // Skip if already has a substantial description
    if (group.summary && group.summary.length > 10) {
      console.log(`Skipping group ${i + 1}: already has description.`);
      continue;
    }
    
    process.stdout.write(`Drafting description for group ${i + 1}/${equivalences.length}... `);
    
    try {
      const prompt = generateDescriptionPrompt(group, referenceData);
      const response = await anthropic.messages.create({
        model: "claude-3-5-sonnet-20240620",
        max_tokens: 1500,
        messages: [{ role: "user", content: prompt }],
      });
      
      const text = response.content[0].text;
      const jsonMatch = text.match(/```json\s*([\s\S]*?)\s*```/) || [null, text];
      const parsed = JSON.parse(jsonMatch[1]);
      
      descriptions.push({
        groupIndex: i,
        description: parsed
      });
      
      process.stdout.write(`\u001b[32mDrafted\u001b[0m\n`);
    } catch (e) {
      console.error(`\nError drafting group ${i + 1}:`, e);
    }
  }
  
  fs.writeFileSync('grammar/description-draft.json', JSON.stringify(descriptions, null, 2));
  console.log(`\nSaved ${descriptions.length} drafts to 'grammar/description-draft.json'.`);
}

run();
