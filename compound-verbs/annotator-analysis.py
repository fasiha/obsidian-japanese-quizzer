"""
compound-verbs/annotator-analysis.py

Multi-annotator analysis using per-class binary decomposition.

Instead of one K-class problem, we run K independent binary problems:
"does this compound belong to meaning M_k? yes/no". This handles
multi-label (M1+M2) and NOTA/omit naturally — omit is just "no" on
every binary problem.

For each binary problem we compute:
  1. Krippendorff's Alpha — how well-defined is this meaning?
  2. Dawid-Skene EM — per-annotator sensitivity/specificity + true labels

Usage: python3 compound-verbs/annotator-analysis.py [--include-orig]
"""

import json
import re
import sys
from pathlib import Path
from collections import defaultdict

import numpy as np
import krippendorff

CLUSTERS = Path(__file__).parent / "clusters"

INCLUDE_ORIG = "--include-orig" in sys.argv

# fmt: off
RUNS = [
    # label, suffix, total, filename, is_orig
    ("Gemini-think (rare)",  "立てる", 51, "立てる-assignments-2026-04-05_06-27-42-475-google-gemini-2.5-thinking.txt", False),
    ("Gemini-think (all)",   "立てる", 51, "立てる-assignments-2026-04-10_16-29-00-000-gemini-2.5-thinking.txt", False),
    ("Gemini-fast (rare)",   "立てる", 51, "立てる-assignments-2026-04-05_06-27-42-475-google-gemini-2.5-fast.txt", False),
    ("Gemini-fast (all)",    "立てる", 51, "立てる-assignments-2026-04-10_16-31-00-000-gemini-2.5-fast.txt", False),
    ("Sonnet (rare)",        "立てる", 51, "立てる-assignments-2026-04-10_15-59-32-951-claude-sonnet-4-20250514.txt", False),
    ("Sonnet (all)",         "立てる", 51, "立てる-assignments-2026-04-10_15-57-23-936-claude-sonnet-4-20250514.txt", False),
    ("Haiku (rare)",         "立てる", 51, "立てる-assignments-2026-04-10_15-59-02-552-claude-haiku-4-5-20251001.txt", False),
    ("Haiku (all)",          "立てる", 51, "立てる-assignments-2026-04-10_15-55-10-603-claude-haiku-4-5-20251001.txt", False),
    ("31b@1.2 (all)",        "立てる", 51, "立てる-assignments-2026-04-10_08-03-47-432-bartowski-google_gemma-4-31B-it-GGUF-Q4_K_M.txt", False),
    ("31b@1.5 (all)",        "立てる", 51, "立てる-assignments-2026-04-10_08-14-29-977-bartowski-google_gemma-4-31B-it-GGUF-Q4_K_M.txt", False),
    ("26b@1.2 (all)",        "立てる", 51, "立てる-assignments-2026-04-10_06-38-00-102-unsloth-gemma-4-26B-A4B-it-GGUF-Q4_K_M.txt", False),
    ("26b@1.5 (all)",        "立てる", 51, "立てる-assignments-2026-04-10_06-42-00-670-unsloth-gemma-4-26B-A4B-it-GGUF-Q4_K_M.txt", False),
    ("31b@1.0 (rare,orig)",  "立てる", 51, "立てる-assignments-2026-04-05_06-27-42-475-google-gemma-4-31b.txt", True),
    ("26b@1.0 (rare,orig)",  "立てる", 51, "立てる-assignments-2026-04-05_05-54-42-970-google-gemma-4-26b-a4b.txt", True),

    ("Gemini-think (rare)",  "出す", 100, "出す-assignments-2026-04-05_18-07-00-000-google-gemini-2.5-thinking.txt", False),
    ("Gemini-think (all)",   "出す", 100, "出す-assignments-2026-04-10_16-33-00-000-gemini-2.5-thinking.txt", False),
    ("Gemini-fast (rare)",   "出す", 100, "出す-assignments-2026-04-05_18-07-00-000-google-gemini-2.5-fast.txt", False),
    ("Gemini-fast (all)",    "出す", 100, "出す-assignments-2026-04-10_16-33-00-000-gemini-2.5-fast.txt", False),
    ("Sonnet (rare)",        "出す", 100, "出す-assignments-2026-04-10_16-00-04-080-claude-sonnet-4-20250514.txt", False),
    ("Sonnet (all)",         "出す", 100, "出す-assignments-2026-04-10_15-57-48-561-claude-sonnet-4-20250514.txt", False),
    ("Haiku (rare)",         "出す", 100, "出す-assignments-2026-04-10_15-59-11-662-claude-haiku-4-5-20251001.txt", False),
    ("Haiku (all)",          "出す", 100, "出す-assignments-2026-04-10_15-55-31-577-claude-haiku-4-5-20251001.txt", False),
    ("31b@1.2 (all)",        "出す", 100, "出す-assignments-2026-04-10_08-29-54-969-bartowski-google_gemma-4-31B-it-GGUF-Q4_K_M.txt", False),
    ("31b@1.5 (all)",        "出す", 100, "出す-assignments-2026-04-10_08-43-10-693-bartowski-google_gemma-4-31B-it-GGUF-Q4_K_M.txt", False),
    ("26b@1.2 (all)",        "出す", 100, "出す-assignments-2026-04-10_06-52-15-778-unsloth-gemma-4-26B-A4B-it-GGUF-Q4_K_M.txt", False),
    ("26b@1.5 (all)",        "出す", 100, "出す-assignments-2026-04-10_06-58-53-989-unsloth-gemma-4-26B-A4B-it-GGUF-Q4_K_M.txt", False),
    ("31b@1.0 (rare,orig)",  "出す", 100, "出す-assignments-2026-04-05_06-21-50-187-google-gemma-4-31b.txt", True),
    ("26b@1.0 (rare,orig)",  "出す", 100, "出す-assignments-2026-04-05_05-53-04-662-google-gemma-4-26b-a4b.txt", True),
]
# fmt: on

MEANING_NAMES = {
    "立てる": {"M1": "vertical/pile", "M2": "intensity/repetition", "M3": "formal/legal", "M4": "transform/status"},
    "出す": {"M1": "extract", "M2": "sudden begin", "M3": "create/produce", "M4": "forced removal"},
}


def meaning_label(s: str) -> str:
    if "vertically" in s or "structural pile" in s: return "M1"
    if "repeatedly" in s or "intensity" in s: return "M2"
    if "formally state" in s or "legally establish" in s: return "M3"
    if "finished" in s or "usable state" in s or "functional status" in s: return "M4"
    if "interior to an exterior" in s or "contained" in s: return "M1"
    if "suddenly begin" in s: return "M2"
    if "new entity" in s or "created/produced" in s: return "M3"
    if "force their exit" in s or "compulsion" in s: return "M4"
    return "M?"


def extract_json(text: str):
    matches = list(re.finditer(r"^\s*\{", text, re.MULTILINE))
    if not matches: return None
    last = matches[-1]
    json_text = text[last.start():].rstrip()
    json_text = re.sub(r"\n?```\s*$", "", json_text).strip()
    return json.loads(json_text)


def extract_compound_list(text: str, suffix: str) -> list[str]:
    marker = f"Compounds ending in -{suffix}"
    idx = text.find(marker)
    if idx < 0: return []
    lines = text[idx:].split("\n")[1:]
    compounds = []
    for line in lines:
        trimmed = line.strip()
        if not trimmed or trimmed.startswith("Reason") or trimmed.startswith("Example"):
            break
        headword = re.sub(r"（.*）$", "", trimmed).strip()
        if headword: compounds.append(headword)
    return compounds


def parse_run(label: str, suffix: str, filename: str):
    """Returns (compound_list_or_None, {compound: set of M-labels})."""
    path = CLUSTERS / filename
    if not path.exists(): return None, {}
    text = path.read_text()
    compound_list = extract_compound_list(text, suffix)
    response_idx = text.find("========== RESPONSE ==========")
    response_text = text[response_idx:] if response_idx >= 0 else text
    try:
        obj = extract_json(response_text)
    except (json.JSONDecodeError, TypeError):
        try: obj = extract_json(text)
        except: return compound_list or None, {}
    if not obj: return compound_list or None, {}

    assignments: dict[str, set[str]] = {}
    for meaning_str, words in obj.items():
        ml = meaning_label(meaning_str)
        for w in words:
            if w not in assignments: assignments[w] = set()
            assignments[w].add(ml)
    return compound_list or None, assignments


def dawid_skene_binary(annotations: np.ndarray, max_iter=50, tol=1e-4):
    """
    Dawid-Skene for a binary problem.

    annotations: (n_annotators, n_items), values in {0, 1, -1 for missing}

    Returns:
        T: (n_items,) posterior P(true=1)
        sensitivity: (n_annotators,) P(says 1 | true=1)
        specificity: (n_annotators,) P(says 0 | true=0)
    """
    n_ann, n_items = annotations.shape

    # Init from majority vote
    T = np.zeros(n_items)
    for i in range(n_items):
        yes = no = 0
        for j in range(n_ann):
            if annotations[j, i] == 1: yes += 1
            elif annotations[j, i] == 0: no += 1
        T[i] = (yes + 0.5) / (yes + no + 1.0)  # Laplace smoothing

    for iteration in range(max_iter):
        prev = T.sum()

        # M-step
        sensitivity = np.zeros(n_ann)
        specificity = np.zeros(n_ann)
        for j in range(n_ann):
            tp = fp = tn = fn = 1e-6  # smoothing
            for i in range(n_items):
                if annotations[j, i] < 0: continue
                if annotations[j, i] == 1:
                    tp += T[i]
                    fp += (1 - T[i])
                else:
                    fn += T[i]
                    tn += (1 - T[i])
            sensitivity[j] = tp / (tp + fn)
            specificity[j] = tn / (tn + fp)

        # E-step
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
            # Softmax
            max_log = max(log_p1, log_p0)
            p1 = np.exp(log_p1 - max_log)
            p0 = np.exp(log_p0 - max_log)
            T_new[i] = p1 / (p1 + p0)

        T = T_new
        if abs(T.sum() - prev) < tol: break

    return T, sensitivity, specificity


def run_analysis(suffix: str, suffix_runs: list):
    meaning_classes = ["M1", "M2", "M3", "M4"]
    meaning_names = MEANING_NAMES[suffix]

    # Parse
    compound_list = None
    annotator_data = []  # list of (name, {compound: set of M-labels})
    for label, sfx, total, filename, is_orig in suffix_runs:
        if is_orig and not INCLUDE_ORIG: continue
        cl, assignments = parse_run(label, sfx, filename)
        if compound_list is None and cl: compound_list = cl
        annotator_data.append((label, assignments))

    if not compound_list: return
    n_items = len(compound_list)
    n_ann = len(annotator_data)

    print(f"\n## {suffix} — Binary Decomposition ({n_ann} raters, {n_items} items)\n")

    # === Per-class binary analysis ===
    all_alphas = {}
    all_ds_results = {}

    for mk in meaning_classes:
        # Build binary annotation matrix: 1 = assigned to this meaning, 0 = not
        ann_matrix = np.zeros((n_ann, n_items), dtype=int)
        for j, (name, assignments) in enumerate(annotator_data):
            for i, compound in enumerate(compound_list):
                labels = assignments.get(compound, set())
                ann_matrix[j, i] = 1 if mk in labels else 0

        # Krippendorff's alpha
        alpha_data = ann_matrix.astype(float)
        try:
            alpha = krippendorff.alpha(alpha_data, level_of_measurement="nominal")
        except ValueError:
            alpha = 1.0  # perfect agreement (all same value)
        all_alphas[mk] = alpha

        # Dawid-Skene binary
        T, sensitivity, specificity = dawid_skene_binary(ann_matrix)
        all_ds_results[mk] = (T, sensitivity, specificity)

    # === Output 1: Per-meaning alpha ===
    print(f"### Krippendorff's Alpha per meaning\n")
    print(f"| Meaning | α | Interpretation |")
    print(f"|---------|---|----------------|")
    for mk in meaning_classes:
        a = all_alphas[mk]
        interp = "good" if a >= 0.8 else "acceptable" if a >= 0.667 else "tentative" if a >= 0.4 else "poor"
        print(f"| {mk} ({meaning_names[mk]}) | {a:.3f} | {interp} |")

    overall_alpha = np.mean(list(all_alphas.values()))
    print(f"\nMean α across meanings: **{overall_alpha:.3f}**")

    # === Output 2: Per-annotator sensitivity/specificity ===
    print(f"\n### Per-annotator Dawid-Skene quality\n")

    # Header
    header = "| Annotator |"
    sep = "|-----------|"
    for mk in meaning_classes:
        header += f" {mk} sens | {mk} spec |"
        sep += "--------|--------|"
    header += " Avg sens |"
    sep += "----------|"
    print(header)
    print(sep)

    annotator_avg_sens = []
    for j, (name, _) in enumerate(annotator_data):
        row = f"| {name} |"
        sens_vals = []
        for mk in meaning_classes:
            _, sensitivity, specificity = all_ds_results[mk]
            row += f" {sensitivity[j]:.0%} | {specificity[j]:.0%} |"
            sens_vals.append(sensitivity[j])
        avg_sens = np.mean(sens_vals)
        annotator_avg_sens.append((avg_sens, name, j))
        row += f" {avg_sens:.0%} |"
        print(row)

    # === Output 3: Hard items per meaning ===
    print(f"\n### Uncertain items (Dawid-Skene posterior between 0.2 and 0.8)\n")
    print(f"| Compound | Meaning | D-S P(yes) | Rater yes/no |")
    print(f"|----------|---------|------------|--------------|")

    uncertain_items = []
    for mk in meaning_classes:
        T, _, _ = all_ds_results[mk]
        for i, compound in enumerate(compound_list):
            if 0.2 < T[i] < 0.8:
                # Count yes/no votes
                yes = sum(1 for j in range(n_ann)
                          if mk in annotator_data[j][1].get(compound, set()))
                no = n_ann - yes
                uncertain_items.append((T[i], compound, mk, yes, no))

    uncertain_items.sort(key=lambda x: abs(x[0] - 0.5))
    for p, compound, mk, yes, no in uncertain_items:
        print(f"| {compound} | {mk} ({meaning_names[mk]}) | {p:.0%} | {yes}y/{no}n |")

    # === Output 4: D-S estimated true labels vs majority vote ===
    print(f"\n### D-S true labels vs majority (threshold 0.5)\n")

    ds_labels = {}  # compound -> set of M labels
    mv_labels = {}  # compound -> set of M labels

    for i, compound in enumerate(compound_list):
        ds_set = set()
        mv_set = set()
        for mk in meaning_classes:
            T, _, _ = all_ds_results[mk]
            if T[i] >= 0.5:
                ds_set.add(mk)
            # Majority vote
            yes = sum(1 for j in range(n_ann)
                      if mk in annotator_data[j][1].get(compound, set()))
            if yes > n_ann / 2:
                mv_set.add(mk)
        ds_labels[compound] = ds_set
        mv_labels[compound] = mv_set

    disagreements = []
    for compound in compound_list:
        ds = ds_labels[compound]
        mv = mv_labels[compound]
        if ds != mv:
            ds_str = "+".join(sorted(ds)) if ds else "omit"
            mv_str = "+".join(sorted(mv)) if mv else "omit"
            disagreements.append((compound, ds_str, mv_str))

    if disagreements:
        print(f"{len(disagreements)} items differ:\n")
        print(f"| Compound | D-S | Majority |")
        print(f"|----------|-----|----------|")
        for compound, ds, mv in disagreements:
            print(f"| {compound} | {ds} | {mv} |")
    else:
        print("D-S and majority vote agree on all items.")

    # === Output 5: Summary — annotator ranking by balanced accuracy ===
    print(f"\n### Annotator ranking (balanced accuracy = mean of sensitivity and specificity)\n")
    print(f"| Rank | Annotator | Balanced accuracy |")
    print(f"|------|-----------|-------------------|")

    bal_acc = []
    for j, (name, _) in enumerate(annotator_data):
        vals = []
        for mk in meaning_classes:
            _, sensitivity, specificity = all_ds_results[mk]
            vals.append((sensitivity[j] + specificity[j]) / 2)
        bal_acc.append((np.mean(vals), name))

    bal_acc.sort(reverse=True)
    for rank, (acc, name) in enumerate(bal_acc, 1):
        print(f"| {rank} | {name} | {acc:.0%} |")


# === Main ===
for suffix in ["立てる", "出す"]:
    suffix_runs = [r for r in RUNS if r[1] == suffix]
    run_analysis(suffix, suffix_runs)
