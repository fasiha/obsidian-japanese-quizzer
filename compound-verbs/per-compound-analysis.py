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
    """Parse a per-compound batch file. Returns {compound: set of M-labels}.
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
    for compound, meanings in obj.items():
        if isinstance(meanings, list):
            result[compound] = {f"M{m}" for m in meanings if isinstance(m, int)}
        else:
            result[compound] = set()
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


# Scan all batch files for this suffix
batch_files = sorted(OUTDIR.glob(f"{SUFFIX}-batch-25-*.txt"))
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


def group_into_runs(files: list[Path]) -> list[dict[str, set[str]]]:
    """Group a model's batch files into runs. Each run is a merged dict of
    {compound: set of M-labels} covering all compounds seen.

    Strategy: parse all files, then greedily assign each file to the first
    run that doesn't already have its compounds."""
    parsed = [(f, parse_batch_file(f)) for f in files]

    runs: list[dict[str, set[str]]] = []
    for f, assignments in parsed:
        compounds_in_file = set(assignments.keys())
        # Find first run with no overlap
        placed = False
        for run in runs:
            if not compounds_in_file.intersection(run.keys()):
                run.update(assignments)
                placed = True
                break
        if not placed:
            runs.append(dict(assignments))

    return runs


annotator_runs: list[tuple[str, dict[str, set[str]]]] = []
for model, files in sorted(by_model.items()):
    runs = group_into_runs(files)
    for i, run in enumerate(runs):
        label = f"{model}#{i+1}" if len(runs) > 1 else model
        annotator_runs.append((label, run))
        print(f"  Run '{label}': {len(run)} compounds")

# ---------------------------------------------------------------------------
# Build compound list (union of all compounds seen)
# ---------------------------------------------------------------------------

all_compounds = set()
for _, run in annotator_runs:
    all_compounds.update(run.keys())
compound_list = sorted(all_compounds)
n_items = len(compound_list)
n_ann = len(annotator_runs)

print(f"\n{n_ann} annotator runs, {n_items} compounds")

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
# Analysis
# ---------------------------------------------------------------------------

meaning_classes = ["M1", "M2", "M3", "M4"]
meaning_names = MEANING_NAMES.get(SUFFIX, {f"M{i+1}": f"meaning {i+1}" for i in range(4)})

print(f"\n## {SUFFIX} — Per-compound assignment ({n_ann} annotators, {n_items} compounds)\n")

# Per-meaning analysis
all_alphas = {}
all_ds = {}

for mk in meaning_classes:
    # Build binary matrix: -1 = missing, 0 = not assigned, 1 = assigned
    ann_matrix = np.full((n_ann, n_items), -1, dtype=float)
    for j, (label, run) in enumerate(annotator_runs):
        for i, compound in enumerate(compound_list):
            if compound in run:
                ann_matrix[j, i] = 1 if mk in run[compound] else 0

    # Krippendorff's alpha (treat -1 as missing)
    alpha_data = ann_matrix.copy()
    alpha_data[alpha_data < 0] = np.nan
    try:
        alpha = krippendorff.alpha(alpha_data, level_of_measurement="nominal")
    except ValueError:
        alpha = 1.0
    all_alphas[mk] = alpha

    # Dawid-Skene
    ds_matrix = ann_matrix.astype(int)  # -1 stays as missing marker
    T, sensitivity, specificity = dawid_skene_binary(ds_matrix)
    all_ds[mk] = (T, sensitivity, specificity)

# Output: Alpha table
print("### Krippendorff's Alpha per meaning\n")
print("| Meaning | α | Interpretation |")
print("|---------|---|----------------|")
for mk in meaning_classes:
    a = all_alphas[mk]
    interp = "good" if a >= 0.8 else "acceptable" if a >= 0.667 else "tentative" if a >= 0.4 else "poor"
    print(f"| {mk} ({meaning_names[mk]}) | {a:.3f} | {interp} |")
overall = np.mean(list(all_alphas.values()))
print(f"\nMean α across meanings: **{overall:.3f}**")

# Output: Per-annotator quality
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

for j, (label, _) in enumerate(annotator_runs):
    row = f"| {label} |"
    vals = []
    for mk in meaning_classes:
        _, sensitivity, specificity = all_ds[mk]
        row += f" {sensitivity[j]:.0%} | {specificity[j]:.0%} |"
        vals.append((sensitivity[j] + specificity[j]) / 2)
    bal_acc = np.mean(vals)
    row += f" {bal_acc:.0%} |"
    print(row)

# Output: D-S consensus labels
print(f"\n### Dawid-Skene consensus labels\n")

ds_labels = {}
for i, compound in enumerate(compound_list):
    labels = set()
    for mk in meaning_classes:
        T, _, _ = all_ds[mk]
        if T[i] >= 0.5:
            labels.add(mk)
    ds_labels[compound] = labels

# Count by label pattern
from collections import Counter
pattern_counts = Counter()
for compound, labels in ds_labels.items():
    pattern = "+".join(sorted(labels)) if labels else "lexicalized"
    pattern_counts[pattern] += 1

print("| Pattern | Count |")
print("|---------|-------|")
for pattern, count in pattern_counts.most_common():
    print(f"| {pattern} | {count} |")

# Uncertain items
print(f"\n### Uncertain items (Dawid-Skene posterior between 0.2 and 0.8)\n")
print("| Compound | Meaning | D-S P(yes) | Annotator votes |")
print("|----------|---------|------------|-----------------|")

for mk in meaning_classes:
    T, _, _ = all_ds[mk]
    for i, compound in enumerate(compound_list):
        if 0.2 < T[i] < 0.8:
            yes = sum(1 for j in range(n_ann)
                      if compound in annotator_runs[j][1]
                      and mk in annotator_runs[j][1][compound])
            total = sum(1 for j in range(n_ann) if compound in annotator_runs[j][1])
            print(f"| {compound} | {mk} ({meaning_names[mk]}) | {T[i]:.0%} | {yes}/{total} |")

# Full label table
print(f"\n### Full assignment table\n")
header = f"| {'Compound':<12} |"
for label, _ in annotator_runs:
    short = label[:12]
    header += f" {short:<12} |"
header += " D-S | Posteriors |"
print(header)
print("|" + "-" * 14 + "|" + ("" + "-" * 14 + "|") * n_ann + "-" * 15 + "|" + "-" * 40 + "|")

for i, compound in enumerate(compound_list):
    row = f"| {compound:<12} |"
    for j, (label, run) in enumerate(annotator_runs):
        if compound in run:
            labels = run[compound]
            cell = "+".join(sorted(labels)) if labels else "lex"
        else:
            cell = "—"
        row += f" {cell:<12} |"
    ds = ds_labels[compound]
    ds_str = "+".join(sorted(ds)) if ds else "lex"
    # Posteriors per meaning
    posteriors = []
    for mk in meaning_classes:
        T, _, _ = all_ds[mk]
        posteriors.append(f"{mk}={T[i]:.2f}")
    post_str = " ".join(posteriors)
    row += f" {ds_str:<13} | {post_str} |"
    print(row)
