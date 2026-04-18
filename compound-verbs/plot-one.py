#!/usr/bin/env python3
"""Usage: python3 plot-one.py v2 込む
         python3 plot-one.py v1 取る [--top 40]"""
import json, sys, argparse, sqlite3 as sqlite, matplotlib.pyplot as plt, matplotlib
matplotlib.rcParams['font.family'] = 'Hiragino Sans'

parser = argparse.ArgumentParser()
parser.add_argument('role', choices=['v1', 'v2'])
parser.add_argument('verb')
parser.add_argument('--top', type=int, default=80)
args = parser.parse_args()

with open('headwords.json') as f:
    headwords = json.load(f)

import os, subprocess
bccwj_path = os.path.join('..', 'bccwj.sqlite')
if not os.path.exists(bccwj_path):
    print('bccwj.sqlite not found at ../bccwj.sqlite')
    print('Build it with: node .claude/scripts/build-bccwj-db.mjs')
    sys.exit(1)
_db = sqlite.connect(bccwj_path)
_db.row_factory = sqlite.Row

def bccwj_freq(entry):
    """Look up frequency by kanji headword, falling back to hiragana reading."""
    row = _db.execute(
        'SELECT frequency FROM bccwj WHERE kanji=? OR reading=? LIMIT 1',
        (entry['headword1'], entry['reading'])
    ).fetchone()
    return row['frequency'] if row else None

matches = [e for e in headwords if e.get(args.role) == args.verb]
if not matches:
    print(f"No compounds found with {args.role}={args.verb}")
    sys.exit(1)

in_bccwj = [(e['headword1'], bccwj_freq(e)) for e in matches if bccwj_freq(e) is not None]
not_in_bccwj = [e['headword1'] for e in matches if bccwj_freq(e) is None]

in_bccwj.sort(key=lambda x: -x[1])

print(f"{args.role}={args.verb}: {len(matches)} compounds total, "
      f"{len(in_bccwj)} in BCCWJ ({100*len(in_bccwj)/len(matches):.0f}%), "
      f"{len(not_in_bccwj)} not in BCCWJ ({100*len(not_in_bccwj)/len(matches):.0f}%)")
print(f"\nNot in BCCWJ: {', '.join(not_in_bccwj) or '(none)'}")

total_freq = sum(f for _, f in in_bccwj)
print(f"\n{'#':<4} {'compound':<16} {'reading':<20} {'freq':>7}  {'cumul%':>7}")
print('-' * 58)
reading_by_headword = {e['headword1']: e['reading'] for e in matches}
cumul = 0
for i, (word, freq) in enumerate(in_bccwj, 1):
    cumul += freq
    print(f"{i:<4} {word:<16} {reading_by_headword.get(word, ''):<20} {freq:>7,}  {100*cumul/total_freq:>6.1f}%")
print()

top = in_bccwj[:args.top]
labels, values = zip(*top)

fig, ax = plt.subplots(figsize=(max(10, len(top) * 0.22), 5))
ax.bar(range(len(values)), values, color='steelblue', alpha=0.8)
ax.set_xticks(range(len(labels)))
ax.set_xticklabels(labels, rotation=60, ha='left', fontsize=10)
ax.set_ylabel('BCCWJ frequency')
ax.set_title(f'Compounds with {args.role}={args.verb} — top {len(top)} by BCCWJ frequency (of {len(in_bccwj)} attested, {len(not_in_bccwj)} unattested)')
ax.set_yscale('log')
ax.grid(axis='y', alpha=0.3)
plt.tight_layout()
out = f'/tmp/{args.role}-{args.verb}.png'
plt.savefig(out, dpi=150)
plt.close()
print(f"Plot saved to {out}")
