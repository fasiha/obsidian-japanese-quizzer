import fs from 'fs';
import path from 'path';
import { JSDOM } from 'jsdom';

export const LOCAL_LLM_URL = 'http://localhost:8080/v1/chat/completions';
export const SLOW_MODEL = 'gemma-4-31b-it-4bit';
export const FAST_MODEL = 'gemma-4-26b-a4b-it-4bit';
export const MODEL = FAST_MODEL;

/**
 * Helper to call the local LLM endpoint.
 */
export async function callLLM(prompt, model = MODEL, responseFormat = { type: 'json_object' }) {
  const res = await fetch(LOCAL_LLM_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: model,
      messages: [{ role: 'user', content: prompt }],
      response_format: responseFormat
    }),
  });

  if (!res.ok) {
    throw new Error(`LLM API error: ${res.status} ${res.statusText}`);
  }

  const data = await res.json();
  return data.choices[0].message;
}

/**
 * Fetches and cleans web content from a URL.
 */
export async function fetchWebContent(url) {
  console.log(`Fetching web content from ${url}...`);
  try {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`HTTP error! status: ${response.status}`);
    const html = await response.text();
    const dom = new JSDOM(html);
    
    const body = dom.window.document.body;
    const scripts = body.querySelectorAll('script, style');
    scripts.forEach(s => s.remove());
    
    return body.textContent.trim().replace(/\s+/g, ' ');
  } catch (e) {
    throw new Error(`Failed to fetch web content from ${url}: ${e.message}`);
  }
}

/**
 * Gets a display title for a grammar topic from its details.
 * Handles cases where titles are in 'title-jp'/'title-en' or just 'title'.
 */
export function getDisplayTitle(details) {
  if (!details) return '';
  const jp = details['title-jp'] || details.titleJP || '';
  const en = details['title-en'] || details.titleEN || '';
  const generic = details.title || details.id || '';

  if (jp || en) {
    return `${jp} / ${en}`.trim();
  }
  return generic;
}

/**
 * Logs the LLM interaction to a markdown file for auditing.
 */
export function logLLMInteraction(filenamePrefix, prompt, response) {
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const logPath = path.join(process.cwd(), `grammar/${filenamePrefix}-${timestamp}.md`);
  
  const logContent = `# LLM INTERACTION
Timestamp: ${new Date().toISOString()}

# PROMPT
${prompt}

# RESPONSE
${response}
`;
  fs.writeFileSync(logPath, logContent);
}
