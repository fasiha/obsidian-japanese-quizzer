"""
compound-verbs/validation-experiment.py

Tests whether the validation step improves Dawid-Skene consensus.

For each annotator's raw assignments of a given suffix verb, runs a validation
pass with a specified validator model, applies the correction flags, then
compares Krippendorff's alpha and Dawid-Skene results on the original
annotations vs the corrected ones.

Usage:
  # Cross-validate all annotators using Haiku as the validator:
  python3 compound-verbs/validation-experiment.py --suffix 出す --validator claude-haiku-4-5-20251001

  # Cross-validate using a local model (queries /props for model name,
  # uses it in cache filenames so different models get separate caches):
  python3 compound-verbs/validation-experiment.py --suffix 出す --validator local --temperature 1.2

  # Cross-validate using Gemini 2.5 Flash:
  python3 compound-verbs/validation-experiment.py --suffix 出す --validator gemini-2.5-flash

  # Dry run — print prompts, skip API calls:
  python3 compound-verbs/validation-experiment.py --suffix 出す --validator claude-haiku-4-5-20251001 --dry-run

  # Include original (early) runs in analysis:
  python3 compound-verbs/validation-experiment.py --suffix 出す --validator claude-haiku-4-5-20251001 --include-orig

Cached validation results are saved as .txt files in clusters/ so reruns skip
completed API calls. Delete the cached file to force a re-call.

Requires:
  - ANTHROPIC_API_KEY in .env (for claude-* validators)
  - GOOGLE_API_KEY in .env (for gemini-* validators)
  - Local LLM server running on LOCAL_LLM_URL (for --validator local)
"""

import json
import re
import sys
import time
from pathlib import Path
from collections import defaultdict

import numpy as np
import krippendorff

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).parent
ROOT = SCRIPT_DIR.parent
CLUSTERS = SCRIPT_DIR / "clusters"

# ---------------------------------------------------------------------------
# Load .env
# ---------------------------------------------------------------------------

env_path = ROOT / ".env"
if env_path.exists():
    for line in env_path.read_text().splitlines():
        m = re.match(r"^\s*([^#=]+?)\s*=\s*(.*?)\s*$", line)
        if m:
            import os
            os.environ.setdefault(m.group(1), m.group(2))

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

import argparse

parser = argparse.ArgumentParser(
    description="Test whether validation improves Dawid-Skene consensus",
    epilog="""
Examples:
  # Self-validation (each annotator validates its own work):
  %(prog)s --suffix 出す --validator self

  # Self-validation, local models only (whatever's loaded on the server):
  %(prog)s --suffix 出す --validator self --local-only

  # Self-validation, API models only (skip local):
  %(prog)s --suffix 出す --validator self --api-only

  # Cross-validate all annotators using Haiku:
  %(prog)s --suffix 出す --validator claude-haiku-4-5-20251001

  # Cross-validate using local model:
  %(prog)s --suffix 出す --validator local --temperature 1.2
""",
    formatter_class=argparse.RawDescriptionHelpFormatter,
)
parser.add_argument("--suffix", required=True, help="Suffix verb to process (e.g. 出す, 立てる)")
parser.add_argument("--validator", required=True,
                    help="'self' for self-validation, or a model ID: claude-*, gemini-*, 'local'")
parser.add_argument("--dry-run", action="store_true", help="Print prompts without calling APIs")
parser.add_argument("--include-orig", action="store_true", help="Include original (early) runs")
parser.add_argument("--local-url", default=None,
                    help="Local LLM server URL (default: LOCAL_LLM_URL env var or http://localhost:8080)")
parser.add_argument("--temperature", type=float, default=None,
                    help="Temperature override for validator calls")
parser.add_argument("--local-only", action="store_true",
                    help="With --validator self, only validate runs whose model is on the local server")
parser.add_argument("--api-only", action="store_true",
                    help="With --validator self, only validate API model runs (skip local)")
args = parser.parse_args()

SUFFIX = args.suffix
VALIDATOR = args.validator
SELF_MODE = VALIDATOR == "self"
DRY_RUN = args.dry_run
INCLUDE_ORIG = args.include_orig

import os
LOCAL_URL = args.local_url or os.environ.get("LOCAL_LLM_URL", "http://localhost:8080")

# ---------------------------------------------------------------------------
# Annotator model registry: maps annotator label prefixes to callable configs.
#
# Each annotator label like "Haiku (rare)" gets matched by its prefix to
# determine provider, model ID, and whether it's a local model.
#
# For self-validation, the script calls each annotator's own model.
# For local models, it queries /props to confirm the right model is loaded
# and skips runs that don't match.
# ---------------------------------------------------------------------------

ANNOTATOR_MODELS = {
    # label_prefix: (provider, model_id)
    # provider is "anthropic", "google", or "local"
    "Gemini-think": ("google", "gemini-2.5-pro"),
    "Gemini-fast":  ("google", "gemini-2.5-flash"),
    "Sonnet":       ("anthropic", "claude-sonnet-4-20250514"),
    "Haiku":        ("anthropic", "claude-haiku-4-5-20251001"),
    "31b":          ("local", "bartowski-google_gemma-4-31B-it-GGUF-Q4_K_M"),
    "26b":          ("local", "unsloth-gemma-4-26B-A4B-it-GGUF-Q4_K_M"),
}


def annotator_model_for(label: str) -> tuple[str, str] | None:
    """Given an annotator label like '31b@1.2 (all)', return (provider, model_id)."""
    for prefix, (provider, model_id) in ANNOTATOR_MODELS.items():
        if label.startswith(prefix):
            return provider, model_id
    return None


# Preflight for local server
LOCAL_SERVER_MODEL = None  # actual model name from /props

if not DRY_RUN and not args.api_only:
    needs_local = VALIDATOR == "local" or (SELF_MODE and not args.api_only)
    if needs_local:
        import requests
        try:
            props = requests.get(f"{LOCAL_URL}/props", timeout=5).json()
            # llama.cpp exposes model name in model_alias
            # (e.g. "unsloth/gemma-4-26B-A4B-it-GGUF:Q4_K_M")
            LOCAL_SERVER_MODEL = (
                props.get("model_alias")
                or props.get("default_generation_settings", {}).get("model")
                or "unknown"
            )
            server_temp = props.get("default_generation_settings", {}).get("params", {}).get("temperature")
            effective_temp = args.temperature if args.temperature is not None else server_temp
            print(f"Local server: model={LOCAL_SERVER_MODEL}, server temperature={server_temp}")
            print(f"Effective temperature: {effective_temp}"
                  f"{' (overridden by --temperature)' if args.temperature is not None else ' (server default)'}")
        except Exception as e:
            if VALIDATOR == "local":
                print(f"ERROR: Cannot reach local LLM at {LOCAL_URL}/props — {e}", file=sys.stderr)
                sys.exit(1)
            else:
                print(f"WARNING: Cannot reach local LLM at {LOCAL_URL}/props — {e}")
                print("Local annotator runs will be skipped.")

# For cross-validation mode, set the global validator label
if not SELF_MODE:
    if VALIDATOR == "local":
        VALIDATOR_LABEL = LOCAL_SERVER_MODEL or "local-dry-run"
    else:
        VALIDATOR_LABEL = VALIDATOR

# ---------------------------------------------------------------------------
# Run registry (same as annotator-analysis.py)
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Shared parsing logic (from annotator-analysis.py)
# ---------------------------------------------------------------------------


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
    if not matches:
        return None
    last = matches[-1]
    json_text = text[last.start():].rstrip()
    json_text = re.sub(r"\n?```\s*$", "", json_text).strip()
    return json.loads(json_text)


def extract_compound_list(text: str, suffix: str) -> list[str]:
    marker = f"Compounds ending in -{suffix}"
    idx = text.find(marker)
    if idx < 0:
        return []
    lines = text[idx:].split("\n")[1:]
    compounds = []
    for line in lines:
        trimmed = line.strip()
        if not trimmed or trimmed.startswith("Reason") or trimmed.startswith("Example"):
            break
        headword = re.sub(r"（.*）$", "", trimmed).strip()
        if headword:
            compounds.append(headword)
    return compounds


def parse_run(suffix: str, filename: str):
    """Returns (compound_list_or_None, {compound: set of M-labels})."""
    path = CLUSTERS / filename
    if not path.exists():
        return None, {}
    text = path.read_text()
    compound_list = extract_compound_list(text, suffix)
    response_idx = text.find("========== RESPONSE ==========")
    response_text = text[response_idx:] if response_idx >= 0 else text
    try:
        obj = extract_json(response_text)
    except (json.JSONDecodeError, TypeError):
        try:
            obj = extract_json(text)
        except Exception:
            return compound_list or None, {}
    if not obj:
        return compound_list or None, {}

    assignments: dict[str, set[str]] = {}
    for meaning_str, words in obj.items():
        if meaning_str == "_metadata":
            continue
        ml = meaning_label(meaning_str)
        if not isinstance(words, list):
            continue
        for w in words:
            if w not in assignments:
                assignments[w] = set()
            assignments[w].add(ml)
    return compound_list or None, assignments


def parse_run_raw(suffix: str, filename: str):
    """Returns (compound_list, {meaning_string: [headwords]}) — raw meaning
    strings, not M-labels. Needed to build validation prompts that reference
    the actual meaning text."""
    path = CLUSTERS / filename
    if not path.exists():
        return None, {}
    text = path.read_text()
    compound_list = extract_compound_list(text, suffix)
    response_idx = text.find("========== RESPONSE ==========")
    response_text = text[response_idx:] if response_idx >= 0 else text
    try:
        obj = extract_json(response_text)
    except (json.JSONDecodeError, TypeError):
        try:
            obj = extract_json(text)
        except Exception:
            return compound_list or None, {}
    if not obj:
        return compound_list or None, {}

    raw_assignments: dict[str, list[str]] = {}
    for meaning_str, words in obj.items():
        if meaning_str == "_metadata":
            continue
        if not isinstance(words, list):
            continue
        raw_assignments[meaning_str] = words
    return compound_list or None, raw_assignments


# ---------------------------------------------------------------------------
# Dawid-Skene (from annotator-analysis.py)
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

    for iteration in range(max_iter):
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
# Load meanings
# ---------------------------------------------------------------------------

sharpened_path = CLUSTERS / f"{SUFFIX}-meanings-sharpened.json"
default_path = CLUSTERS / f"{SUFFIX}-meanings.json"

if sharpened_path.exists():
    meanings_path = sharpened_path
elif default_path.exists():
    meanings_path = default_path
else:
    print(f"ERROR: No meanings file found for {SUFFIX}", file=sys.stderr)
    sys.exit(1)

meanings = json.loads(meanings_path.read_text())
meaning_strings = [m["meaning"] for m in meanings]
print(f"Loaded {len(meaning_strings)} meanings from {meanings_path.name}")

# ---------------------------------------------------------------------------
# Filter runs for this suffix
# ---------------------------------------------------------------------------

suffix_runs = [
    (label, sfx, total, filename, is_orig)
    for label, sfx, total, filename, is_orig in RUNS
    if sfx == SUFFIX and (INCLUDE_ORIG or not is_orig)
]

if not suffix_runs:
    print(f"ERROR: No runs found for suffix {SUFFIX}", file=sys.stderr)
    sys.exit(1)

print(f"Found {len(suffix_runs)} annotator runs for -{SUFFIX}")

# ---------------------------------------------------------------------------
# Parse all runs
# ---------------------------------------------------------------------------

compound_list = None
annotator_data = []      # [(label, {compound: set of M-labels})]
annotator_raw = []       # [(label, {meaning_string: [headwords]})]

for label, sfx, total, filename, is_orig in suffix_runs:
    cl, assignments = parse_run(sfx, filename)
    _, raw = parse_run_raw(sfx, filename)
    if compound_list is None and cl:
        compound_list = cl
    annotator_data.append((label, assignments))
    annotator_raw.append((label, raw, filename))

if not compound_list:
    print(f"ERROR: Could not extract compound list for {SUFFIX}", file=sys.stderr)
    sys.exit(1)

n_items = len(compound_list)
n_ann = len(annotator_data)
print(f"Compound list: {n_items} items, {n_ann} annotators")

# ---------------------------------------------------------------------------
# Load glosses from survey file
# ---------------------------------------------------------------------------

survey_path = SCRIPT_DIR / "survey" / f"{SUFFIX}.json"
GLOSSES: dict[str, str] = {}  # headword → English gloss
RARE_COMPOUNDS: set[str] = set()  # compounds that need glosses in "rare" mode

if survey_path.exists():
    import sqlite3
    survey = json.loads(survey_path.read_text())

    # Load BCCWJ frequencies to determine which compounds are "rare"
    bccwj_path = SCRIPT_DIR / "bccwj.sqlite"
    bccwj_freq: dict[str, int] = {}
    if bccwj_path.exists():
        bccwj_db = sqlite3.connect(str(bccwj_path))
        for entry in survey:
            hw = entry.get("headword", "")
            if hw:
                row = bccwj_db.execute("SELECT frequency FROM bccwj WHERE kanji=?", (hw,)).fetchone()
                bccwj_freq[hw] = row[0] if row else 0
        bccwj_db.close()

    # Also open jmdict.sqlite to look up glosses by kanji or reading
    # (the raws table has both kanji forms and readings)
    jmdict_path = ROOT / "jmdict.sqlite"
    jmdict_db = None
    if jmdict_path.exists():
        jmdict_db = sqlite3.connect(str(jmdict_path))

    def jmdict_gloss(headword: str, reading: str) -> str:
        """Look up a compound in jmdict.sqlite by kanji, then by reading.
        Returns ALL senses' glosses, numbered like '(1) to flick out. (2) to calculate.',
        or just the glosses if there's only one sense."""
        if not jmdict_db:
            return ""
        for text in [headword, reading]:
            if not text:
                continue
            rows = jmdict_db.execute(
                "SELECT entries.entry_json FROM raws "
                "JOIN entries ON raws.entry_id = entries.id "
                "WHERE raws.text = ? LIMIT 1", (text,)
            ).fetchall()
            if rows:
                entry_data = json.loads(rows[0][0])
                senses = entry_data.get("sense", [])
                sense_parts = []
                for sense in senses:
                    glosses = [g["text"] for g in sense.get("gloss", [])
                               if g.get("lang", "eng") == "eng"]
                    if glosses:
                        sense_parts.append("; ".join(glosses))
                if len(sense_parts) == 1:
                    return sense_parts[0]
                elif sense_parts:
                    return " ".join(f"({i+1}) {s}." for i, s in enumerate(sense_parts))
        return ""

    for entry in survey:
        hw = entry.get("headword", "")
        reading = entry.get("reading", "")
        # Priority: survey JMDict meanings > survey NINJAL > jmdict.sqlite lookup
        # Include ALL senses, not just the first — showing only one sense biases the
        # model when a compound has multiple meanings mapping to different categories.
        gloss = ""
        jm = entry.get("jmdictMeanings", [])
        if jm:
            sense_parts = []
            for sense in jm:
                if isinstance(sense, list) and sense:
                    sense_parts.append("; ".join(sense))
            if len(sense_parts) == 1:
                gloss = sense_parts[0]
            elif sense_parts:
                gloss = " ".join(f"({i+1}) {s}." for i, s in enumerate(sense_parts))
        if not gloss:
            ns = entry.get("ninjal_senses", [])
            if ns:
                sense_parts = [s.get("definition_en", "") for s in ns
                               if isinstance(s, dict) and s.get("definition_en")]
                if len(sense_parts) == 1:
                    gloss = sense_parts[0]
                elif sense_parts:
                    gloss = " ".join(f"({i+1}) {s}." for i, s in enumerate(sense_parts))
        if not gloss:
            gloss = jmdict_gloss(hw, reading)
        if hw and gloss:
            GLOSSES[hw] = gloss
        # "Rare" = bccwjFrequency === 0 or no jmdictId (same as assign-examples.mjs)
        if bccwj_freq.get(hw, 0) == 0 or not entry.get("jmdictId"):
            RARE_COMPOUNDS.add(hw)

    if jmdict_db:
        jmdict_db.close()

    print(f"Loaded glosses for {len(GLOSSES)} compounds from {survey_path.name} + jmdict.sqlite "
          f"({len(RARE_COMPOUNDS)} rare)")
else:
    print(f"WARNING: No survey file at {survey_path} — prompts will lack glosses")


# ---------------------------------------------------------------------------
# Build validation prompt for a single annotator's assignments
# ---------------------------------------------------------------------------


def gloss_suffix(hw: str, all_glosses: bool) -> str:
    """Return '（gloss）' for this headword if glosses are warranted.
    In 'all' mode, always include. In 'rare' mode, only for rare compounds."""
    if not all_glosses and hw not in RARE_COMPOUNDS:
        return ""
    g = GLOSSES.get(hw)
    return f"（{g}）" if g else ""


def build_validation_prompt(suffix: str, raw_assignments: dict[str, list[str]],
                            all_compounds: list[str], all_glosses: bool) -> str:
    """Build a validation prompt with glosses matching the annotator's style.
    all_glosses=True for "(all)" runs, False for "(rare)" runs."""
    gloss_note = ("each entry includes an English gloss" if all_glosses
                  else "rare or lesser-known entries include an English gloss")
    meanings_block = "\n".join(
        f'  {i+1}. "{ms}"' for i, ms in enumerate(meaning_strings)
    )

    # Assigned compounds per meaning (with glosses matching style)
    assignments_block_parts = []
    assigned_set = set()
    for ms in meaning_strings:
        headwords = raw_assignments.get(ms, [])
        assigned_set.update(headwords)
        hw_str = ("、".join(f"{hw}{gloss_suffix(hw, all_glosses)}" for hw in headwords)
                  if headwords else "(none)")
        assignments_block_parts.append(f'  "{ms}":\n    {hw_str}')
    assignments_block = "\n\n".join(assignments_block_parts)

    # Lexicalized = sent but not assigned to any meaning
    lexicalized = [c for c in all_compounds if c not in assigned_set]
    lexicalized_block = ("、".join(f"{c}{gloss_suffix(c, all_glosses)}" for c in lexicalized)
                         if lexicalized else "(none)")

    return f"""You are helping prepare data for an app to teach Japanese to English speakers. You will validate the automated assignment of -{suffix} compound verbs to meaning categories.

The suffix -{suffix} has these distinct meanings when appended to a prefix verb:
{meanings_block}

Below are the current assignments of compounds to meanings ({gloss_note}), followed by compounds that were not assigned to any meaning (the "lexicalized" or opaque set whose meaning cannot be derived from the parts).

=== CURRENT ASSIGNMENTS ===
{assignments_block}

=== LEXICALIZED / UNASSIGNED ===
{lexicalized_block}

Your task: carefully review these assignments and flag any that look wrong. Look for:

1. A compound is listed under a meaning but -{suffix} does not contribute that meaning in it; it belongs somewhere else.
2. A compound is in the lexicalized bucket, but -{suffix}'s role in it is actually transparent and it should be assigned to one of the meanings above.
3. A compound is assigned to one meaning but clearly fits a second meaning equally well and is missing from it.

Do not flag trivial or borderline cases. Only flag clear errors.

Reason through the assignments, then output a JSON object with a single key "flags" whose value is an array of flag objects. If you find no issues, return {{"flags": []}}.

Each flag object has these fields:
  "headword": the compound in kanji
  "suggested": the complete list of meanings the compound should be assigned to (including any it is already correctly assigned to). Use [] to indicate the compound should be lexicalized/unassigned.
  "reason": short explanation

The meaning strings in "suggested" must be verbatim from the numbered list above. Use an empty array [] to indicate the compound should be lexicalized."""


# ---------------------------------------------------------------------------
# API callers
# ---------------------------------------------------------------------------


def call_anthropic(model: str, prompt: str, temperature: float | None = None) -> str:
    import anthropic
    client = anthropic.Anthropic()
    kwargs = dict(model=model, max_tokens=16000, messages=[{"role": "user", "content": prompt}])
    if temperature is not None:
        kwargs["temperature"] = temperature
    message = client.messages.create(**kwargs)
    return message.content[0].text.strip()


def call_gemini(model: str, prompt: str, temperature: float | None = None) -> str:
    from google import genai
    from google.genai import types

    client = genai.Client()
    config = types.GenerateContentConfig(max_output_tokens=16000)
    if temperature is not None:
        config.temperature = temperature
    # Enable thinking for pro/thinking models
    if "thinking" in model or "pro" in model:
        config.thinking_config = types.ThinkingConfig(thinking_budget=8000)
    response = client.models.generate_content(
        model=model, contents=prompt, config=config
    )
    return response.text.strip()


def call_local(prompt: str, temperature: float | None = None) -> str:
    import requests
    body = {
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 16384,
    }
    if temperature is not None:
        body["temperature"] = temperature
    resp = requests.post(
        f"{LOCAL_URL}/v1/chat/completions",
        json=body,
        timeout=30 * 60,  # 30 minutes
    )
    resp.raise_for_status()
    data = resp.json()
    msg = data["choices"][0]["message"]
    content = (msg.get("content") or "").strip()
    reasoning = (msg.get("reasoning_content") or msg.get("thinking") or "").strip()
    # Return both sections in the same format as assign-examples.mjs archives
    if reasoning:
        full = f"========== THINKING ==========\n{reasoning}\n\n========== ANSWER ==========\n{content}"
    else:
        full = content
    return full


def call_model(provider: str, model_id: str, prompt: str, temperature: float | None = None) -> str:
    """Call an LLM by provider and model ID."""
    if provider == "anthropic":
        return call_anthropic(model_id, prompt, temperature)
    elif provider == "google":
        return call_gemini(model_id, prompt, temperature)
    elif provider == "local":
        return call_local(prompt, temperature)
    else:
        raise ValueError(f"Unknown provider: {provider}")


# ---------------------------------------------------------------------------
# Cache management
# ---------------------------------------------------------------------------


def safe_model_name(model: str) -> str:
    return model.replace("/", "-").replace(":", "-")


def cache_path_for(assignment_filename: str, val_label: str, temperature: float | None) -> Path:
    """Return the path where we cache validation results for this
    (annotator assignment file, validator) pair.

    Derives the cache key from the original assignment filename, so the
    mapping from input to output is self-evident:
      input:  出す-assignments-2026-04-10_15-59-11-662-claude-haiku-4-5-20251001.txt
      output: 出す-valexp-2026-04-10_15-59-11-662-claude-haiku-4-5-20251001-by-<validator>-t1.2.txt
    """
    # Strip the "{suffix}-assignments-" prefix and ".txt" suffix to get
    # the unique part: "2026-04-10_15-59-11-662-claude-haiku-4-5-20251001"
    stem = assignment_filename
    prefix = f"{SUFFIX}-assignments-"
    if stem.startswith(prefix):
        stem = stem[len(prefix):]
    if stem.endswith(".txt"):
        stem = stem[:-4]

    safe_validator = safe_model_name(val_label)
    temp_suffix = f"-t{temperature}" if temperature is not None else ""
    return CLUSTERS / f"{SUFFIX}-valexp-{stem}-by-{safe_validator}{temp_suffix}.txt"


def load_cached_response(assignment_filename: str, val_label: str, temperature: float | None) -> str | None:
    """Load a cached validation response if it exists."""
    path = cache_path_for(assignment_filename, val_label, temperature)
    if not path.exists():
        return None
    text = path.read_text()
    idx = text.find("========== RESPONSE ==========")
    if idx < 0:
        return None
    return text[idx + len("========== RESPONSE =========="):].strip()


def save_cached_response(assignment_filename: str, label: str, val_label: str,
                         temperature: float | None, prompt: str, response: str):
    """Save a validation response to the cache."""
    path = cache_path_for(assignment_filename, val_label, temperature)
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
    header = "\n".join([
        "========== FLAGS ==========",
        f"suffix: {SUFFIX}",
        f"annotator: {label}",
        f"assignment-file: {assignment_filename}",
        f"validator: {val_label}",
        f"temperature: {temperature}",
        f"timestamp: {timestamp}",
        f"experiment: validation-experiment.py",
        "",
        "========== PROMPT ==========",
        prompt,
        "",
        "========== RESPONSE ==========",
        response,
    ])
    path.write_text(header)


# ---------------------------------------------------------------------------
# Parse validation flags and apply corrections
# ---------------------------------------------------------------------------


def extract_json_first(text: str):
    """Like extract_json but takes the FIRST {...} match, not the last.
    Validation responses are typically just JSON (possibly in a code fence),
    so the first { is the root object.

    If the text contains an ANSWER section (from local models with thinking),
    only search within the answer portion."""
    answer_marker = "========== ANSWER =========="
    if answer_marker in text:
        text = text[text.index(answer_marker) + len(answer_marker):]
    matches = list(re.finditer(r"^\s*\{", text, re.MULTILINE))
    if not matches:
        return None
    first = matches[0]
    json_text = text[first.start():].rstrip()
    json_text = re.sub(r"\n?```\s*$", "", json_text).strip()
    return json.loads(json_text)


def parse_validation_flags(response_text: str) -> list[dict]:
    """Parse flags from a validation response. Returns list of
    {headword, suggested: [meaning_strings], reason}."""
    try:
        obj = extract_json_first(response_text)
    except (json.JSONDecodeError, TypeError):
        # Fall back to last-match (for responses with reasoning before JSON)
        try:
            obj = extract_json(response_text)
        except (json.JSONDecodeError, TypeError):
            return []
    if not obj or not isinstance(obj.get("flags"), list):
        return []

    valid_meanings = set(meaning_strings)
    valid_flags = []
    for flag in obj["flags"]:
        if not isinstance(flag, dict):
            continue
        headword = flag.get("headword", "")
        suggested = flag.get("suggested", [])
        reason = flag.get("reason", "")
        if not headword or not isinstance(suggested, list):
            continue
        # Check all suggested meanings are valid
        if any(s not in valid_meanings for s in suggested):
            continue
        valid_flags.append({"headword": headword, "suggested": suggested, "reason": reason})
    return valid_flags


def apply_flags(raw_assignments: dict[str, list[str]],
                flags: list[dict]) -> dict[str, list[str]]:
    """Apply validation flags to raw assignments, returning corrected assignments.
    Each flag says: this headword should be in exactly these meanings (or [] for lexicalized)."""
    # Deep copy
    corrected = {ms: list(hws) for ms, hws in raw_assignments.items()}
    # Ensure all meaning strings have an entry
    for ms in meaning_strings:
        if ms not in corrected:
            corrected[ms] = []

    for flag in flags:
        hw = flag["headword"]
        new_meanings = set(flag["suggested"])

        # Remove headword from all meanings
        for ms in meaning_strings:
            if hw in corrected[ms]:
                corrected[ms].remove(hw)

        # Add headword to new meanings
        for ms in new_meanings:
            if hw not in corrected[ms]:
                corrected[ms].append(hw)

    return corrected


def raw_to_mlabels(raw_assignments: dict[str, list[str]]) -> dict[str, set[str]]:
    """Convert {meaning_string: [headwords]} to {compound: set of M-labels}."""
    result: dict[str, set[str]] = {}
    for meaning_str, headwords in raw_assignments.items():
        ml = meaning_label(meaning_str)
        for hw in headwords:
            if hw not in result:
                result[hw] = set()
            result[hw].add(ml)
    return result


# ---------------------------------------------------------------------------
# Run D-S analysis on a set of annotator data
# ---------------------------------------------------------------------------


def compute_alphas_and_ds(data: list[tuple[str, dict[str, set[str]]]],
                          compounds: list[str]):
    """Given annotator data as [(label, {compound: set of M-labels})],
    compute per-meaning Krippendorff's alpha and D-S results.
    Returns {mk: alpha} and {mk: (T, sensitivity, specificity)}."""
    meaning_classes = ["M1", "M2", "M3", "M4"]
    n_items = len(compounds)
    n_ann = len(data)

    alphas = {}
    ds_results = {}

    for mk in meaning_classes:
        ann_matrix = np.zeros((n_ann, n_items), dtype=int)
        for j, (name, assignments) in enumerate(data):
            for i, compound in enumerate(compounds):
                labels = assignments.get(compound, set())
                ann_matrix[j, i] = 1 if mk in labels else 0

        alpha_data = ann_matrix.astype(float)
        try:
            alpha = krippendorff.alpha(alpha_data, level_of_measurement="nominal")
        except ValueError:
            alpha = 1.0
        alphas[mk] = alpha

        T, sensitivity, specificity = dawid_skene_binary(ann_matrix)
        ds_results[mk] = (T, sensitivity, specificity)

    return alphas, ds_results


# ---------------------------------------------------------------------------
# Main experiment
# ---------------------------------------------------------------------------

validator_display = "self" if SELF_MODE else (VALIDATOR_LABEL if not SELF_MODE else VALIDATOR)
print(f"\n{'='*60}")
print(f"Validation experiment: -{SUFFIX}")
print(f"Validator: {validator_display}")
print(f"{'='*60}\n")

# Step 1: Run validation for each annotator
corrected_data = []  # [(label, {compound: set of M-labels})]
flag_counts = []     # [(label, n_flags)]

for idx, (label, raw, filename) in enumerate(annotator_raw):
    print(f"[{idx+1}/{n_ann}] {label}...", end=" ", flush=True)

    # Resolve which model validates this annotator's assignments
    if SELF_MODE:
        model_info = annotator_model_for(label)
        if model_info is None:
            print("SKIP (no model mapping)")
            corrected_data.append((label, raw_to_mlabels(raw)))
            flag_counts.append((label, -1))
            continue
        provider, model_id = model_info

        # Filter by --local-only / --api-only
        if args.local_only and provider != "local":
            print("SKIP (--local-only)")
            corrected_data.append((label, raw_to_mlabels(raw)))
            flag_counts.append((label, -1))
            continue
        if args.api_only and provider == "local":
            print("SKIP (--api-only)")
            corrected_data.append((label, raw_to_mlabels(raw)))
            flag_counts.append((label, -1))
            continue

        # For local models, check that the right model is loaded
        if provider == "local":
            if LOCAL_SERVER_MODEL is None:
                print("SKIP (local server not available)")
                corrected_data.append((label, raw_to_mlabels(raw)))
                flag_counts.append((label, -1))
                continue
            # Normalize both names for comparison: replace /: with -
            def normalize_model_name(s: str) -> str:
                return s.replace("/", "-").replace(":", "-").replace("_", "-").lower()
            if normalize_model_name(model_id) not in normalize_model_name(LOCAL_SERVER_MODEL):
                print(f"SKIP (need {model_id}, server has {LOCAL_SERVER_MODEL})")
                corrected_data.append((label, raw_to_mlabels(raw)))
                flag_counts.append((label, -1))
                continue
            val_label = LOCAL_SERVER_MODEL
        else:
            val_label = model_id

        val_temperature = args.temperature
    else:
        # Cross-validation: one validator for all
        if VALIDATOR == "local":
            provider = "local"
            model_id = LOCAL_SERVER_MODEL or "local"
        elif VALIDATOR.startswith("claude-"):
            provider = "anthropic"
            model_id = VALIDATOR
        elif VALIDATOR.startswith("gemini-"):
            provider = "google"
            model_id = VALIDATOR
        else:
            print(f"ERROR: unknown validator {VALIDATOR}")
            corrected_data.append((label, raw_to_mlabels(raw)))
            flag_counts.append((label, -1))
            continue
        val_label = VALIDATOR_LABEL
        val_temperature = args.temperature

    # Match gloss style to the annotator's original run:
    # "(all)" labels used all glosses, "(rare)" used rare-only,
    # local models (no "rare"/"all" in label) always used all glosses
    use_all_glosses = "(rare)" not in label
    prompt = build_validation_prompt(SUFFIX, raw, compound_list, use_all_glosses)

    if DRY_RUN:
        print("(dry run — skipping API call)")
        corrected_data.append((label, raw_to_mlabels(raw)))
        flag_counts.append((label, 0))
        if idx == 0:
            print(f"\n--- Sample prompt ({len(prompt)} chars) ---")
            print(prompt[:500])
            print("...\n")
        continue

    # Check cache
    cached = load_cached_response(filename, val_label, val_temperature)
    if cached is not None:
        print(f"(cached, validator={val_label})", end=" ")
        response_text = cached
    else:
        try:
            print(f"(calling {val_label})", end=" ", flush=True)
            response_text = call_model(provider, model_id, prompt, val_temperature)
            save_cached_response(filename, label, val_label, val_temperature, prompt, response_text)
        except Exception as e:
            print(f"ERROR: {e}")
            corrected_data.append((label, raw_to_mlabels(raw)))
            flag_counts.append((label, -1))
            continue

    flags = parse_validation_flags(response_text)
    corrected_raw = apply_flags(raw, flags)
    corrected_mlabels = raw_to_mlabels(corrected_raw)
    corrected_data.append((label, corrected_mlabels))
    flag_counts.append((label, len(flags)))
    print(f"{len(flags)} flags")

# Step 2: Compute D-S on original vs corrected
meaning_names = MEANING_NAMES.get(SUFFIX, {f"M{i+1}": f"meaning {i+1}" for i in range(4)})
meaning_classes = ["M1", "M2", "M3", "M4"]

print(f"\n{'='*60}")
print(f"Results: -{SUFFIX} validated by {validator_display}")
print(f"{'='*60}\n")

# Flag summary
print("### Flags per annotator\n")
print("| Annotator | Flags |")
print("|-----------|-------|")
for label, n in flag_counts:
    status = str(n) if n >= 0 else "ERROR"
    print(f"| {label} | {status} |")

total_flags = sum(n for _, n in flag_counts if n > 0)
print(f"\nTotal flags applied: {total_flags}")

# Alpha comparison
orig_alphas, orig_ds = compute_alphas_and_ds(annotator_data, compound_list)
corr_alphas, corr_ds = compute_alphas_and_ds(corrected_data, compound_list)

print(f"\n### Krippendorff's Alpha: original vs validated\n")
print(f"| Meaning | Original α | Validated α | Δ |")
print(f"|---------|-----------|------------|---|")
for mk in meaning_classes:
    oa = orig_alphas[mk]
    ca = corr_alphas[mk]
    delta = ca - oa
    sign = "+" if delta > 0 else ""
    print(f"| {mk} ({meaning_names.get(mk, mk)}) | {oa:.3f} | {ca:.3f} | {sign}{delta:.3f} |")

orig_mean = np.mean(list(orig_alphas.values()))
corr_mean = np.mean(list(corr_alphas.values()))
delta_mean = corr_mean - orig_mean
sign = "+" if delta_mean > 0 else ""
print(f"| **Mean** | **{orig_mean:.3f}** | **{corr_mean:.3f}** | **{sign}{delta_mean:.3f}** |")

# D-S label comparison: how many items changed their consensus label?
print(f"\n### Dawid-Skene consensus changes\n")
print("Items where the D-S consensus label changed after validation:\n")

changes = []
for i, compound in enumerate(compound_list):
    orig_set = set()
    corr_set = set()
    for mk in meaning_classes:
        T_orig, _, _ = orig_ds[mk]
        T_corr, _, _ = corr_ds[mk]
        if T_orig[i] >= 0.5:
            orig_set.add(mk)
        if T_corr[i] >= 0.5:
            corr_set.add(mk)
    if orig_set != corr_set:
        orig_str = "+".join(sorted(orig_set)) if orig_set else "omit"
        corr_str = "+".join(sorted(corr_set)) if corr_set else "omit"
        changes.append((compound, orig_str, corr_str))

if changes:
    print(f"| Compound | Original D-S | Validated D-S |")
    print(f"|----------|-------------|--------------|")
    for compound, orig, corr in changes:
        print(f"| {compound} | {orig} | {corr} |")
    print(f"\n{len(changes)} items changed out of {n_items}.")
else:
    print("No items changed — D-S consensus is identical before and after validation.")

# Per-annotator balanced accuracy comparison
print(f"\n### Per-annotator balanced accuracy: original vs validated\n")
print(f"| Annotator | Original | Validated | Δ |")
print(f"|-----------|---------|----------|---|")

for j in range(n_ann):
    label = annotator_data[j][0]
    orig_vals = []
    corr_vals = []
    for mk in meaning_classes:
        _, o_sens, o_spec = orig_ds[mk]
        _, c_sens, c_spec = corr_ds[mk]
        orig_vals.append((o_sens[j] + o_spec[j]) / 2)
        corr_vals.append((c_sens[j] + c_spec[j]) / 2)
    orig_ba = np.mean(orig_vals)
    corr_ba = np.mean(corr_vals)
    delta = corr_ba - orig_ba
    sign = "+" if delta > 0 else ""
    print(f"| {label} | {orig_ba:.0%} | {corr_ba:.0%} | {sign}{delta:.1%} |")
