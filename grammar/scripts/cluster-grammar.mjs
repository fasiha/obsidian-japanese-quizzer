import { execSync } from 'child_process';
import path from 'path';

/**
 * Master script to run the Grammar Clustering Pipeline.
 * Sequence:
 * 1. find-new-grammar-topics
 * 2. suggest-grammar-matches
 * 3. gather-references
 * 4. verify-equivalences
 * 5. apply-equivalence
 * 6. generate-description
 * 7. write-description
 */

const scripts = [
  'find-new-grammar-topics.mjs',
  'suggest-grammar-matches.mjs',
  'gather-references.mjs',
  'verify-equivalences.mjs',
  'apply-equivalence.mjs',
  'generate-description.mjs',
  'write-description.mjs',
];

async function runPipeline() {
  console.log('\x1b[36m%s\x1b[0m', 'Starting Grammar Clustering Pipeline...');
  
  for (const script of scripts) {
    console.log('\x1b[33m%s\x1b[0m', `\nRunning ${script}...`);
    try {
      execSync(`node grammar/scripts/${script}`, {
        stdio: 'inherit',
        env: { ...process.env }
      });
      console.log('\x1b[32m%s\x1b[0m', `✓ Completed ${script}`);
    } catch (e) {
      console.error('\x1b[31m%s\x1b[0m', `✗ Failed ${script}. Stopping pipeline.`);
      process.exit(1);
    }
  }
  
  console.log('\n\x1b[36m%s\x1b[0m', 'Grammar Clustering Pipeline completed successfully!');
}

runPipeline();
