import json, matplotlib.pyplot as plt, matplotlib
matplotlib.rcParams['font.family'] = 'Hiragino Sans'

with open('headwords.json') as f:
    headwords = json.load(f)

import sqlite3 as sqlite, os, subprocess
if not os.path.exists('bccwj.sqlite'):
    print('bccwj.sqlite not found, building it now...')
    subprocess.run(['node', 'build-bccwj-db.mjs'], check=True)
_db = sqlite.connect('bccwj.sqlite')
_db.row_factory = sqlite.Row

def bccwj_freq(entry):
    """Look up frequency by kanji headword, falling back to hiragana reading."""
    row = _db.execute(
        'SELECT frequency FROM bccwj WHERE kanji=? OR reading=? LIMIT 1',
        (entry['headword1'], entry['reading'])
    ).fetchone()
    return row['frequency'] if row else None

def plot(role):
    # role is 'v1' or 'v2'
    counts_total = {}
    counts_matched = {}
    freq_sums = {}
    for entry in headwords:
        key = entry.get(role) or '(none)'
        counts_total[key] = counts_total.get(key, 0) + 1
        freq = bccwj_freq(entry)
        if freq is not None:
            counts_matched[key] = counts_matched.get(key, 0) + 1
            freq_sums[key] = freq_sums.get(key, 0) + freq

    sorted_matched = sorted(counts_matched.items(), key=lambda x: -x[1])
    total_compounds = sum(counts_total.values())
    total_matched = sum(counts_matched.values())
    print(f"--- {role} ---")
    print(f"Total compounds: {total_compounds}, BCCWJ-matched: {total_matched} "
          f"({100*total_matched/total_compounds:.1f}%), "
          f"ignored: {total_compounds - total_matched} "
          f"({100*(total_compounds - total_matched)/total_compounds:.1f}%)")
    print(f"Unique {role} values with at least one BCCWJ match: {len(sorted_matched)}")
    print(f"\nTop 40 (ignored % = share of that {role}'s compounds not in BCCWJ):")
    for key, matched in sorted_matched[:40]:
        total = counts_total.get(key, 0)
        ignored = total - matched
        print(f"  {key:<8} {matched} matched / {total} total  "
              f"({100*ignored/total:.0f}% ignored)  freq sum: {freq_sums.get(key, 0)}")
    print()

    top = sorted_matched[:80]
    labels = [key for key, _ in top]
    values = [count for _, count in top]
    freqs = [freq_sums.get(key, 0) for key in labels]

    fig, ax1 = plt.subplots(figsize=(18, 6))
    ax1.bar(range(len(values)), values, alpha=0.7, color='steelblue')
    ax1.set_xticks(range(len(labels)))
    ax1.set_xticklabels(labels, rotation=60, ha='left', fontsize=11)
    ax1.set_ylabel(f'Number of BCCWJ-attested compound verbs', color='steelblue')
    ax1.tick_params(axis='y', labelcolor='steelblue')

    ax2 = ax1.twinx()
    ax2.plot(range(len(freqs)), freqs, color='crimson', linewidth=1.5, marker='o', markersize=3)
    ax2.set_ylabel('Sum of BCCWJ frequencies', color='crimson')
    ax2.tick_params(axis='y', labelcolor='crimson')

    ax1.set_title(f'NINJAL VV Lexicon: BCCWJ-attested compound count (bars) and total BCCWJ frequency (line) per {role} — top 80 by count')
    ax1.grid(axis='y', alpha=0.3)
    plt.tight_layout()
    out = f'/tmp/{role}-counts.png'
    plt.savefig(out, dpi=150)
    plt.close()
    print(f"Plot saved to {out}\n")

def scatter(role):
    counts_matched = {}
    freq_sums = {}
    for entry in headwords:
        key = entry.get(role) or '(none)'
        freq = bccwj_freq(entry)
        if freq is not None:
            counts_matched[key] = counts_matched.get(key, 0) + 1
            freq_sums[key] = freq_sums.get(key, 0) + freq

    by_count = sorted(counts_matched, key=lambda k: -counts_matched[k])
    top80_count = set(by_count[:80])
    by_freq = sorted(freq_sums, key=lambda k: -freq_sums[k])
    top80_freq = set(by_freq[:80])
    gate_crashers = top80_freq - top80_count

    keys = list(counts_matched.keys())
    xs = [counts_matched[k] for k in keys]
    ys = [freq_sums[k] for k in keys]

    fig, ax = plt.subplots(figsize=(10, 7))

    # Background dots: in neither top-80
    bg = [k for k in keys if k not in top80_count and k not in top80_freq]
    ax.scatter([counts_matched[k] for k in bg], [freq_sums[k] for k in bg],
               color='lightgray', s=15, zorder=1)

    # In top-80 by count only
    count_only = [k for k in keys if k in top80_count and k not in top80_freq]
    ax.scatter([counts_matched[k] for k in count_only], [freq_sums[k] for k in count_only],
               color='steelblue', s=25, zorder=2, label='top-80 by count only')

    # In both top-80s
    both = [k for k in keys if k in top80_count and k in top80_freq]
    ax.scatter([counts_matched[k] for k in both], [freq_sums[k] for k in both],
               color='mediumpurple', s=35, zorder=3, label='top-80 by both')

    # Gate-crashers: top-80 by freq but not count — label these
    ax.scatter([counts_matched[k] for k in gate_crashers], [freq_sums[k] for k in gate_crashers],
               color='crimson', s=40, zorder=4, label='top-80 by freq only (gate-crashers)')
    for k in gate_crashers:
        ax.annotate(k, (counts_matched[k], freq_sums[k]),
                    fontsize=8, textcoords='offset points', xytext=(4, 2))

    ax.set_xscale('log')
    ax.set_yscale('log')
    ax.set_xlabel(f'Number of BCCWJ-attested compound verbs (log scale)')
    ax.set_ylabel('Sum of BCCWJ frequencies (log scale)')
    ax.set_title(f'NINJAL VV Lexicon: count vs. frequency per {role}\nred = would enter top-80 chart if sorted by frequency instead of count')
    ax.legend(fontsize=9)
    ax.grid(alpha=0.3)
    plt.tight_layout()
    out = f'/tmp/{role}-scatter.png'
    plt.savefig(out, dpi=150)
    plt.close()
    print(f"Scatter plot saved to {out}\n")

plot('v1')
plot('v2')
scatter('v1')
scatter('v2')
