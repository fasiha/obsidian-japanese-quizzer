#!/usr/bin/env node
// telemetry-report.mjs
// Print a structured telemetry report from api_events for the last N hours.
// Usage: node telemetry-report.mjs [hours]   (default: 12)

import Database from 'better-sqlite3';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dir = dirname(fileURLToPath(import.meta.url));
const dbPath = join(__dir, '../../quiz.sqlite');
const hours = Number(process.argv[2] ?? 12);
const since = new Date(Date.now() - hours * 3600_000).toISOString();

const db = new Database(dbPath, { readonly: true });

const rows = db.prepare(
  `SELECT * FROM api_events WHERE timestamp >= ? ORDER BY id ASC`
).all(since);

if (rows.length === 0) {
  console.log(`No api_events in the last ${hours} hours (since ${since}).`);
  process.exit(0);
}

console.log(`\n=== Telemetry report — last ${hours}h (${rows.length} events since ${since.slice(0,16)}Z) ===\n`);

// ── 1. Token cost by event type ────────────────────────────────────────────
{
  const byType = {};
  for (const r of rows) {
    const t = r.event_type;
    if (!byType[t]) byType[t] = { calls: 0, totalIn: 0, totalOut: 0, firstIn: 0, firstCount: 0 };
    const b = byType[t];
    b.calls++;
    b.totalIn  += r.input_tokens  ?? 0;
    b.totalOut += r.output_tokens ?? 0;
    if (r.first_turn_input_tokens != null) { b.firstIn += r.first_turn_input_tokens; b.firstCount++; }
  }
  console.log('── 1. Token cost by event type ──');
  const hdr = ['event_type', 'calls', 'total_in', 'total_out', 'avg_in', 'avg_out', 'avg_first_turn_in'];
  const data = Object.entries(byType)
    .sort((a, b) => b[1].totalIn - a[1].totalIn)
    .map(([t, b]) => [
      t,
      b.calls,
      b.totalIn,
      b.totalOut,
      Math.round(b.totalIn / b.calls),
      Math.round(b.totalOut / b.calls),
      b.firstCount ? Math.round(b.firstIn / b.firstCount) : 'n/a',
    ]);
  printTable(hdr, data);
  const totalIn  = rows.reduce((s, r) => s + (r.input_tokens  ?? 0), 0);
  const totalOut = rows.reduce((s, r) => s + (r.output_tokens ?? 0), 0);
  console.log(`  Grand total: ${totalIn} input + ${totalOut} output = ${totalIn + totalOut} tokens\n`);
}

// ── 2. Overhead breakdown: first_turn vs total (question_gen + quiz_chat) ──
{
  const types = ['question_gen', 'quiz_chat'];
  const byType = {};
  for (const r of rows) {
    if (!types.includes(r.event_type)) continue;
    if (r.first_turn_input_tokens == null) continue;
    const t = r.event_type;
    if (!byType[t]) byType[t] = { n: 0, firstIn: 0, totalIn: 0, extraIn: 0 };
    byType[t].n++;
    byType[t].firstIn   += r.first_turn_input_tokens;
    byType[t].totalIn   += r.input_tokens ?? 0;
    byType[t].extraIn   += (r.input_tokens ?? 0) - r.first_turn_input_tokens;
  }
  if (Object.keys(byType).length) {
    console.log('── 2. Overhead vs payload (first_turn vs total input tokens) ──');
    const hdr = ['event_type', 'n', 'avg_first_turn_in', 'avg_total_in', 'avg_tool_history_overhead'];
    const data = Object.entries(byType).map(([t, b]) => [
      t,
      b.n,
      Math.round(b.firstIn  / b.n),
      Math.round(b.totalIn  / b.n),
      Math.round(b.extraIn  / b.n),
    ]);
    printTable(hdr, data);
    console.log('  (avg_tool_history_overhead = extra tokens from tool-call round-trips or accumulated chat history)\n');
  }
}

// ── 3. Item selection: rank analysis ───────────────────────────────────────
{
  const sel = rows.filter(r => r.event_type === 'item_selection');
  if (sel.length) {
    console.log('── 3. Item selection ──');
    for (const r of sel) {
      const ranks = JSON.parse(r.selected_ranks ?? '[]');
      const ids   = JSON.parse(r.selected_ids   ?? '[]');
      const cands = r.candidate_count ?? '?';
      console.log(`  ${r.timestamp.slice(0,16)}Z  candidates=${cands}  selected_ranks=[${ranks}]  ids=[${ids}]`);
      const max = Math.max(...ranks);
      const pct = cands !== '?' ? ` (top-${ranks.length} would be [0…${ranks.length-1}]; max rank chosen=${max}/${cands-1})` : '';
      console.log(`    → rank 0 always chosen: ${ranks[0] === 0}${pct}`);
    }
    console.log();
  }
}

// ── 4. Question generation ─────────────────────────────────────────────────
{
  const gen = rows.filter(r => r.event_type === 'question_gen');
  if (gen.length) {
    console.log('── 4. Question generation ──');
    const byFormat = {};
    let prefetchCount = 0, foregroundCount = 0, retryCount = 0;
    const charCounts = [];
    for (const r of gen) {
      const fmt = r.question_format ?? 'unknown';
      byFormat[fmt] = (byFormat[fmt] ?? 0) + 1;
      if (r.prefetch === 1) prefetchCount++; else foregroundCount++;
      if ((r.generation_attempt ?? 1) > 1) retryCount++;
      if (r.question_chars != null) charCounts.push(r.question_chars);
    }
    console.log(`  Total: ${gen.length} (foreground=${foregroundCount}, prefetch=${prefetchCount}, retries=${retryCount})`);
    console.log(`  Format breakdown: ${JSON.stringify(byFormat)}`);
    if (charCounts.length) {
      const avg = Math.round(charCounts.reduce((a,b)=>a+b,0)/charCounts.length);
      const min = Math.min(...charCounts);
      const max = Math.max(...charCounts);
      console.log(`  Question chars: avg=${avg}, min=${min}, max=${max}`);
    }
    const hdr = ['word_id', 'facet', 'format', 'pfetch', 'attempt', 'first_in', 'total_in', 'out', 'api_turns', 'q_chars', 'pre_recall'];
    const data = gen.map(r => [
      r.word_id ?? '',
      (r.quiz_type ?? '').replace('meaning-reading-to-kanji','mrk').replace('reading-to-meaning','rtm').replace('meaning-to-reading','mtr').replace('kanji-to-reading','ktr'),
      (r.question_format ?? '?').replace('multiple_choice','mc').replace('free_answer','fa'),
      r.prefetch ?? '?',
      r.generation_attempt ?? 1,
      r.first_turn_input_tokens ?? 'n/a',
      r.input_tokens ?? 0,
      r.output_tokens ?? 0,
      r.api_turns ?? '?',
      r.question_chars ?? 'n/a',
      r.pre_recall != null ? r.pre_recall.toFixed(3) : 'new',
    ]);
    printTable(hdr, data);
    console.log();
  }
}

// ── 5. Quiz chat: depth, tools, mnemonic, score ───────────────────────────
{
  const chat = rows.filter(r => r.event_type === 'quiz_chat');
  if (chat.length) {
    console.log('── 5. Quiz chat ──');

    // Per-item aggregates (group by word_id + quiz_type, using timestamp proximity)
    // Use word_id+quiz_type as key; accumulate max turn, scores, mnemonic presence
    const items = {};
    for (const r of chat) {
      const key = `${r.word_id}/${r.quiz_type}`;
      if (!items[key]) items[key] = { wordId: r.word_id, facet: r.quiz_type, maxTurn: 0, scores: [], hasMnemonic: 0, totalIn: 0, turns: 0 };
      const item = items[key];
      item.maxTurn = Math.max(item.maxTurn, r.chat_turn ?? 0);
      item.totalIn += r.input_tokens ?? 0;
      item.turns++;
      if (r.score != null) item.scores.push(r.score);
      if (r.has_mnemonic) item.hasMnemonic = 1;
    }

    // Tool usage
    const toolCounts = {};
    let noToolTurns = 0;
    for (const r of chat) {
      const tools = JSON.parse(r.tools_called ?? 'null') ?? [];
      if (tools.length === 0) { noToolTurns++; continue; }
      for (const t of tools) toolCounts[t] = (toolCounts[t] ?? 0) + 1;
    }

    console.log(`  Total turns: ${chat.length}  (${noToolTurns} with no tool calls)`);
    if (Object.keys(toolCounts).length) {
      console.log(`  Tool call counts: ${JSON.stringify(toolCounts)}`);
    }

    const hdr = ['word/facet', 'max_turn', 'api_turns', 'total_in', 'score', 'mnemonic', 'pre_recall'];
    const data = Object.values(items).map(item => {
      const chatRows = chat.filter(r => r.word_id === item.wordId && r.quiz_type === item.facet);
      const totalApiTurns = chatRows.reduce((s, r) => s + (r.api_turns ?? 0), 0);
      const scoreStr = item.scores.length ? item.scores.map(s => s.toFixed(2)).join(',') : '–';
      const preRecall = chatRows[0]?.pre_recall;
      const facetShort = (item.facet ?? '').replace('meaning-reading-to-kanji','mrk').replace('reading-to-meaning','rtm').replace('meaning-to-reading','mtr').replace('kanji-to-reading','ktr');
      return [
        `${item.wordId}/${facetShort}`,
        item.maxTurn,
        totalApiTurns,
        item.totalIn,
        scoreStr,
        item.hasMnemonic ? 'yes' : 'no',
        preRecall != null ? preRecall.toFixed(3) : 'new',
      ];
    });
    printTable(hdr, data);
    console.log();
  }
}

// ── 6. Chat turn token growth (sliding window analysis) ───────────────────
{
  const chat = rows.filter(r => r.event_type === 'quiz_chat' && r.chat_turn != null);
  if (chat.length > 3) {
    // Group by turn number and average input tokens
    const byTurn = {};
    for (const r of chat) {
      const t = r.chat_turn;
      if (!byTurn[t]) byTurn[t] = [];
      byTurn[t].push(r.input_tokens ?? 0);
    }
    const turnNums = Object.keys(byTurn).map(Number).sort((a,b)=>a-b);
    if (turnNums.length > 1) {
      console.log('── 6. Chat input token growth by turn number ──');
      const hdr = ['chat_turn', 'n', 'avg_input_tokens', 'min', 'max'];
      const data = turnNums.map(t => {
        const vals = byTurn[t];
        return [t, vals.length, Math.round(vals.reduce((a,b)=>a+b,0)/vals.length), Math.min(...vals), Math.max(...vals)];
      });
      printTable(hdr, data);
      console.log('  (rising avg_input_tokens = history accumulation; use to decide sliding-window cutoff)\n');
    }
  }
}

// ── helpers ────────────────────────────────────────────────────────────────
function printTable(headers, rows) {
  const cols = headers.length;
  const widths = headers.map((h, i) => Math.max(String(h).length, ...rows.map(r => String(r[i]).length)));
  const fmt = row => '  ' + row.map((v, i) => String(v).padEnd(widths[i])).join('  ');
  console.log(fmt(headers));
  console.log('  ' + widths.map(w => '-'.repeat(w)).join('  '));
  for (const row of rows) console.log(fmt(row));
}
