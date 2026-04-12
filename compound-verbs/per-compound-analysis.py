"""
compound-verbs/per-compound-analysis.py

Dawid-Skene and Krippendorff's Alpha analysis on per-compound assignment results.

Reads batch-25 output files from clusters/per-compound/, groups them into
annotator runs, builds binary annotation matrices (one per meaning), and
computes inter-rater reliability.

Usage:
  python3 compound-verbs/per-compound-analysis.py --suffix 出す
"""

import argparse
import json
import re
from collections import defaultdict
from pathlib import Path

import numpy as np
import krippendorff

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

parser = argparse.ArgumentParser()
parser.add_argument("--suffix", required=True)
parser.add_argument("--per-sense-only", action="store_true",
                    help="Only include files with per-sense format (array of arrays)")
parser.add_argument("--batch-size", type=int, default=None,
                    help="Only include files from a specific batch size (e.g. 10, 25)")
parser.add_argument("--collapse-model", action="store_true",
                    help="Run D-S for every combination of one-run-per-model, "
                         "so models with multiple runs don't dominate")
args = parser.parse_args()

SUFFIX = args.suffix
OUTDIR = Path(__file__).parent / "clusters" / "per-compound"

# ---------------------------------------------------------------------------
# Meaning names (same as annotator-analysis.py)
# ---------------------------------------------------------------------------

MEANING_NAMES = {
    "立てる": {"M1": "vertical/pile", "M2": "intensity/repetition", "M3": "formal/legal", "M4": "transform/status"},
    "出す": {"M1": "extract", "M2": "sudden begin", "M3": "create/produce", "M4": "forced removal"},
}

# ---------------------------------------------------------------------------
# Parse all batch files
# ---------------------------------------------------------------------------


def parse_batch_file(path: Path) -> dict[str, set[str]]:
    """Parse a batch file. Handles both formats:
    - Per-compound: {"弾き出す": [1, 4]} → {("弾き出す", -1): {M1, M4}}
    - Per-sense: {"弾き出す": [[1], [], [4], []]} → {("弾き出す", 0): {M1}, ("弾き出す", 1): set(), ...}

    Keys are (compound, sense_idx) tuples. sense_idx=-1 means per-compound (old format).
    Meaning numbers (1-4) are converted to M1-M4. Empty array = lexicalized."""
    text = path.read_text()
    idx = text.find("========== PARSED ==========")
    if idx < 0:
        return {}
    parsed_text = text[idx + len("========== PARSED =========="):].strip()
    try:
        obj = json.loads(parsed_text)
    except json.JSONDecodeError:
        return {}

    result = {}
    for compound, value in obj.items():
        if isinstance(value, list) and value and isinstance(value[0], list):
            # Per-sense format: [[1], [], [4], []]
            for si, sense_meanings in enumerate(value):
                if isinstance(sense_meanings, list):
                    result[(compound, si)] = {f"M{m}" for m in sense_meanings
                                              if isinstance(m, int) and 1 <= m <= 4}
                else:
                    result[(compound, si)] = set()
        elif isinstance(value, list):
            # Per-compound format: [1, 4]
            result[(compound, -1)] = {f"M{m}" for m in value
                                      if isinstance(m, int) and 1 <= m <= 4}
        else:
            result[(compound, -1)] = set()
    return result


def extract_model(filename: str) -> str:
    """Extract model identifier from filename.
    E.g. '出す-batch-25-2026-...-claude-haiku-4-5-20251001.txt' -> 'claude-haiku-4-5-20251001'
    """
    # Strip prefix and .txt
    name = filename.replace(".txt", "")
    # Find the timestamp pattern and take everything after it
    m = re.search(r"\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}-\d{3}-(.*)", name)
    if m:
        return m.group(1)
    return "unknown"


# Scan batch files for this suffix
if args.batch_size:
    batch_files = sorted(OUTDIR.glob(f"{SUFFIX}-batch-{args.batch_size}-*.txt"))
else:
    batch_files = sorted(OUTDIR.glob(f"{SUFFIX}-batch-*-*.txt"))

if args.per_sense_only:
    # Filter to only files containing per-sense format (array of arrays)
    def is_per_sense(path: Path) -> bool:
        text = path.read_text()
        idx = text.find("========== PARSED ==========")
        if idx < 0:
            return False
        parsed_text = text[idx + len("========== PARSED =========="):].strip()
        try:
            obj = json.loads(parsed_text)
            first_val = next(iter(obj.values()), None)
            return (isinstance(first_val, list) and first_val
                    and isinstance(first_val[0], list))
        except (json.JSONDecodeError, StopIteration):
            return False

    batch_files = [f for f in batch_files if is_per_sense(f)]

print(f"Found {len(batch_files)} batch files for {SUFFIX}")

# Group files by model
by_model: dict[str, list[Path]] = defaultdict(list)
for f in batch_files:
    model = extract_model(f.name)
    by_model[model].append(f)

for model, files in by_model.items():
    print(f"  {model}: {len(files)} files")

# ---------------------------------------------------------------------------
# Build annotator runs
#
# Each run should cover ~100 compounds. Files from the same model are grouped
# into runs based on which compounds they contain: files covering different
# compounds are in the same run; files covering the same compounds are
# different runs.
# ---------------------------------------------------------------------------


ItemKey = tuple[str, int]  # (compound, sense_idx) — sense_idx=-1 for per-compound format


def group_into_runs(files: list[Path]) -> list[dict[ItemKey, set[str]]]:
    """Group a model's batch files into runs. Each run is a merged dict of
    {(compound, sense_idx): set of M-labels} covering all items seen.

    Strategy: parse all files, then greedily assign each file to the first
    run that doesn't already have its compounds (by headword, ignoring sense)."""
    parsed = [(f, parse_batch_file(f)) for f in files]

    runs: list[dict[ItemKey, set[str]]] = []
    for f, assignments in parsed:
        # Check overlap by compound headword (first element of tuple key)
        compounds_in_file = {k[0] for k in assignments.keys()}
        placed = False
        for run in runs:
            compounds_in_run = {k[0] for k in run.keys()}
            if not compounds_in_file.intersection(compounds_in_run):
                run.update(assignments)
                placed = True
                break
        if not placed:
            runs.append(dict(assignments))

    return runs


annotator_runs: list[tuple[str, dict[ItemKey, set[str]]]] = []
for model, files in sorted(by_model.items()):
    runs = group_into_runs(files)
    for i, run in enumerate(runs):
        label = f"{model}#{i+1}" if len(runs) > 1 else model
        annotator_runs.append((label, run))
        n_compounds = len({k[0] for k in run.keys()})
        print(f"  Run '{label}': {len(run)} items ({n_compounds} compounds)")

# ---------------------------------------------------------------------------
# Build item list (union of all (compound, sense_idx) tuples seen)
# ---------------------------------------------------------------------------

all_items: set[ItemKey] = set()
for _, run in annotator_runs:
    all_items.update(run.keys())
item_list = sorted(all_items)
n_items = len(item_list)
n_ann = len(annotator_runs)
n_compounds = len({k[0] for k in item_list})

print(f"\n{n_ann} annotator runs, {n_items} items ({n_compounds} compounds)")

# ---------------------------------------------------------------------------
# Dawid-Skene (copied from annotator-analysis.py)
# ---------------------------------------------------------------------------


def dawid_skene_binary(annotations: np.ndarray, max_iter=50, tol=1e-4):
    n_ann, n_items = annotations.shape
    T = np.zeros(n_items)
    for i in range(n_items):
        yes = no = 0
        for j in range(n_ann):
            if annotations[j, i] == 1: yes += 1
            elif annotations[j, i] == 0: no += 1
        T[i] = (yes + 0.5) / (yes + no + 1.0)

    for _ in range(max_iter):
        prev = T.sum()
        sensitivity = np.zeros(n_ann)
        specificity = np.zeros(n_ann)
        for j in range(n_ann):
            tp = fp = tn = fn = 1e-6
            for i in range(n_items):
                if annotations[j, i] < 0: continue
                if annotations[j, i] == 1:
                    tp += T[i]; fp += (1 - T[i])
                else:
                    fn += T[i]; tn += (1 - T[i])
            sensitivity[j] = tp / (tp + fn)
            specificity[j] = tn / (tn + fp)

        prevalence = T.mean()
        T_new = np.zeros(n_items)
        for i in range(n_items):
            log_p1 = np.log(prevalence + 1e-300)
            log_p0 = np.log(1 - prevalence + 1e-300)
            for j in range(n_ann):
                if annotations[j, i] < 0: continue
                if annotations[j, i] == 1:
                    log_p1 += np.log(sensitivity[j] + 1e-300)
                    log_p0 += np.log(1 - specificity[j] + 1e-300)
                else:
                    log_p1 += np.log(1 - sensitivity[j] + 1e-300)
                    log_p0 += np.log(specificity[j] + 1e-300)
            max_log = max(log_p1, log_p0)
            p1 = np.exp(log_p1 - max_log)
            p0 = np.exp(log_p0 - max_log)
            T_new[i] = p1 / (p1 + p0)
        T = T_new
        if abs(T.sum() - prev) < tol:
            break
    return T, sensitivity, specificity


# ---------------------------------------------------------------------------
# Analysis function
# ---------------------------------------------------------------------------

meaning_classes = ["M1", "M2", "M3", "M4"]
meaning_names = MEANING_NAMES.get(SUFFIX, {f"M{i+1}": f"meaning {i+1}" for i in range(4)})


def run_analysis(runs: list[tuple[str, dict[ItemKey, set[str]]]], title: str = ""):
    """Run D-S + Krippendorff analysis on a set of annotator runs."""
    # Build item list from these runs
    all_run_items: set[ItemKey] = set()
    for _, run in runs:
        all_run_items.update(run.keys())
    items = sorted(all_run_items)
    n_i = len(items)
    n_a = len(runs)
    n_c = len({k[0] for k in items})

    if title:
        print(f"\n## {title}\n")
    else:
        print(f"\n## {SUFFIX} — Per-sense assignment ({n_a} annotators, {n_i} items from {n_c} compounds)\n")

    all_alphas = {}
    all_ds = {}

    for mk in meaning_classes:
        ann_matrix = np.full((n_a, n_i), -1, dtype=float)
        for j, (label, run) in enumerate(runs):
            for i, item in enumerate(items):
                if item in run:
                    ann_matrix[j, i] = 1 if mk in run[item] else 0

        alpha_data = ann_matrix.copy()
        alpha_data[alpha_data < 0] = np.nan
        try:
            alpha = krippendorff.alpha(alpha_data, level_of_measurement="nominal")
        except ValueError:
            alpha = 1.0
        all_alphas[mk] = alpha

        ds_matrix = ann_matrix.astype(int)
        T, sensitivity, specificity = dawid_skene_binary(ds_matrix)
        all_ds[mk] = (T, sensitivity, specificity)

    return items, runs, all_alphas, all_ds

def print_results(items, runs, all_alphas, all_ds, full_table=True):
    """Print alpha table, per-annotator quality, consensus labels, uncertain items,
    and optionally the full assignment table."""
    n_a = len(runs)

    # Alpha table
    print("### Krippendorff's Alpha per meaning\n")
    print("| Meaning | α | Interpretation |")
    print("|---------|---|----------------|")
    for mk in meaning_classes:
        a = all_alphas[mk]
        interp = "good" if a >= 0.8 else "acceptable" if a >= 0.667 else "tentative" if a >= 0.4 else "poor"
        print(f"| {mk} ({meaning_names[mk]}) | {a:.3f} | {interp} |")
    overall = np.mean(list(all_alphas.values()))
    print(f"\nMean α across meanings: **{overall:.3f}**")

    # Per-annotator quality
    print(f"\n### Per-annotator Dawid-Skene quality\n")
    header = "| Annotator |"
    sep = "|-----------|"
    for mk in meaning_classes:
        header += f" {mk} sens | {mk} spec |"
        sep += "--------|--------|"
    header += " Bal acc |"
    sep += "---------|"
    print(header)
    print(sep)

    for j, (label, _) in enumerate(runs):
        row = f"| {label} |"
        vals = []
        for mk in meaning_classes:
            _, sensitivity, specificity = all_ds[mk]
            row += f" {sensitivity[j]:.0%} | {specificity[j]:.0%} |"
            vals.append((sensitivity[j] + specificity[j]) / 2)
        bal_acc = np.mean(vals)
        row += f" {bal_acc:.0%} |"
        print(row)

    # D-S consensus labels
    print(f"\n### Dawid-Skene consensus labels\n")
    ds_labels = {}
    for i, item in enumerate(items):
        labels = set()
        for mk in meaning_classes:
            T, _, _ = all_ds[mk]
            if T[i] >= 0.5:
                labels.add(mk)
        ds_labels[item] = labels

    from collections import Counter
    pattern_counts = Counter()
    for item, labels in ds_labels.items():
        pattern = "+".join(sorted(labels)) if labels else "lexicalized"
        pattern_counts[pattern] += 1
    print("| Pattern | Count |")
    print("|---------|-------|")
    for pattern, count in pattern_counts.most_common():
        print(f"| {pattern} | {count} |")

    # Uncertain items
    print(f"\n### Uncertain items (Dawid-Skene posterior between 0.2 and 0.8)\n")
    print("| Item | Meaning | D-S P(yes) | Annotator votes |")
    print("|------|---------|------------|-----------------|")
    for mk in meaning_classes:
        T, _, _ = all_ds[mk]
        for i, item in enumerate(items):
            if 0.2 < T[i] < 0.8:
                yes = sum(1 for j in range(n_a)
                          if item in runs[j][1] and mk in runs[j][1][item])
                total = sum(1 for j in range(n_a) if item in runs[j][1])
                compound, si = item
                item_label = f"{compound} s{si+1}" if si >= 0 else compound
                print(f"| {item_label} | {mk} ({meaning_names[mk]}) | {T[i]:.0%} | {yes}/{total} |")

    if not full_table:
        return

    # Full label table
    print(f"\n### Full assignment table\n")
    header = f"| {'Item':<20} |"
    for label, _ in runs:
        short = label[:12]
        header += f" {short:<12} |"
    header += " D-S | Posteriors |"
    print(header)
    print("|" + "-" * 22 + "|" + ("" + "-" * 14 + "|") * n_a + "-" * 15 + "|" + "-" * 40 + "|")

    for i, item in enumerate(items):
        compound, si = item
        item_label = f"{compound} s{si+1}" if si >= 0 else compound
        row = f"| {item_label:<20} |"
        for j, (label, run) in enumerate(runs):
            if item in run:
                labels = run[item]
                cell = "+".join(sorted(labels)) if labels else "lex"
            else:
                cell = "—"
            row += f" {cell:<12} |"
        ds = ds_labels[item]
        ds_str = "+".join(sorted(ds)) if ds else "lex"
        posteriors = []
        for mk in meaning_classes:
            T, _, _ = all_ds[mk]
            posteriors.append(f"{mk}={T[i]:.2f}")
        post_str = " ".join(posteriors)
        row += f" {ds_str:<13} | {post_str} |"
        print(row)


# ---------------------------------------------------------------------------
# Run analysis
# ---------------------------------------------------------------------------

if args.collapse_model:
    # Group annotator runs by model (strip #N suffix)
    from itertools import product

    runs_by_model: dict[str, list[tuple[str, dict]]] = defaultdict(list)
    for label, run in annotator_runs:
        base_model = label.split("#")[0]
        runs_by_model[base_model].append((label, run))

    model_names = sorted(runs_by_model.keys())
    model_run_lists = [runs_by_model[m] for m in model_names]

    print(f"\nModels: {', '.join(f'{m} ({len(runs_by_model[m])} runs)' for m in model_names)}")
    combos = list(product(*model_run_lists))
    print(f"Generating {len(combos)} combinations (one run per model)\n")

    # Summary table across all combinations
    all_combo_alphas = []

    for ci, combo in enumerate(combos):
        combo_runs = list(combo)
        combo_label = " + ".join(label for label, _ in combo_runs)
        title = f"Combination {ci+1}/{len(combos)}: {combo_label}"
        items, runs, alphas, ds = run_analysis(combo_runs, title)
        print_results(items, runs, alphas, ds, full_table=False)
        all_combo_alphas.append((combo_label, alphas))

    # Summary comparison
    print(f"\n## Summary: mean α across all {len(combos)} combinations\n")
    print(f"| Combination | M1 α | M2 α | M3 α | M4 α | Mean α |")
    print(f"|-------------|------|------|------|------|--------|")
    for label, alphas in all_combo_alphas:
        mean_a = np.mean(list(alphas.values()))
        row = f"| {label} | "
        row += " | ".join(f"{alphas[mk]:.3f}" for mk in meaning_classes)
        row += f" | **{mean_a:.3f}** |"
        print(row)
else:
    items, runs, all_alphas, all_ds = run_analysis(annotator_runs)
    print_results(items, runs, all_alphas, all_ds)
