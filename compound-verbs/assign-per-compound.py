"""
compound-verbs/assign-per-compound.py

Per-compound assignment with full semantic context.

For each compound, the LLM sees:
  - All suffix meanings (from the sharpened meanings file)
  - All JMDict senses of the compound verb
  - All JMDict senses of the prefix verb (v1)
  - All JMDict senses of the suffix verb (v2)

This lets the model compare the compound's senses against the prefix verb's
senses to determine what the suffix *actually contributes* — rather than
guessing from a single gloss.

Usage:
  # Assign specific compounds:
  python3 compound-verbs/assign-per-compound.py --suffix 出す --compounds 弾き出す 飛び出す 切り出す

  # Assign all compounds for a suffix:
  python3 compound-verbs/assign-per-compound.py --suffix 出す --all

  # Use a specific model:
  python3 compound-verbs/assign-per-compound.py --suffix 出す --compounds 弾き出す --model claude-haiku-4-5-20251001

  # Use local model:
  python3 compound-verbs/assign-per-compound.py --suffix 出す --compounds 弾き出す --model local

  # Dry run (print prompt, skip API call):
  python3 compound-verbs/assign-per-compound.py --suffix 出す --compounds 弾き出す --dry-run

  # Batch size (group N compounds per prompt, default 1):
  python3 compound-verbs/assign-per-compound.py --suffix 出す --all --batch-size 5
"""

import argparse
import json
import os
import re
import sqlite3
import sys
import time
from pathlib import Path

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
            os.environ.setdefault(m.group(1), m.group(2))

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

parser = argparse.ArgumentParser(
    description="Per-compound assignment with full semantic context",
    formatter_class=argparse.RawDescriptionHelpFormatter,
)
parser.add_argument("--suffix", required=True, help="Suffix verb (e.g. 出す, 立てる)")
parser.add_argument("--compounds", nargs="+", help="Specific compounds to assign")
parser.add_argument("--all", action="store_true", help="Assign all compounds for the suffix")
parser.add_argument("--model", default="claude-haiku-4-5-20251001",
                    help="Model to use (claude-*, gemini-*, or 'local')")
parser.add_argument("--temperature", type=float, default=None)
parser.add_argument("--batch-size", type=int, default=1,
                    help="Number of compounds per prompt (default: 1)")
parser.add_argument("--dry-run", action="store_true")
parser.add_argument("--local-url", default=None)
args = parser.parse_args()

SUFFIX = args.suffix
MODEL = args.model
LOCAL_URL = args.local_url or os.environ.get("LOCAL_LLM_URL", "http://localhost:8080")

if not args.compounds and not args.all:
    parser.error("Provide --compounds or --all")

# For local models, detect the actual model name for filenames.
# Try /props (llama.cpp) first, fall back to /v1/models (omlx and others).
ACTUAL_MODEL = MODEL
if MODEL == "local" and not args.dry_run:
    import requests as _req
    detected = False

    # Try llama.cpp /props endpoint
    try:
        props = _req.get(f"{LOCAL_URL}/props", timeout=5).json()
        if "detail" not in props:  # omlx returns {"detail": "Not Found"}
            ACTUAL_MODEL = (props.get("model_alias")
                            or props.get("default_generation_settings", {}).get("model")
                            or "local-unknown")
            server_temp = props.get("default_generation_settings", {}).get("params", {}).get("temperature")
            effective_temp = args.temperature if args.temperature is not None else server_temp
            print(f"Local server (llama.cpp): model={ACTUAL_MODEL}, server temperature={server_temp}")
            print(f"Effective temperature: {effective_temp}"
                  f"{' (overridden)' if args.temperature is not None else ' (server default)'}")
            detected = True
    except Exception:
        pass

    # Fall back to OpenAI-compatible /v1/models endpoint
    if not detected:
        try:
            models_resp = _req.get(f"{LOCAL_URL}/v1/models", timeout=5).json()
            model_list = models_resp.get("data", [])
            # Pick the first model ending in "-it" (instruction-tuned), or just the first
            it_models = [m for m in model_list if m.get("id", "").endswith("-it-4bit")
                         or m.get("id", "").endswith("-it")]
            chosen = it_models[0] if it_models else (model_list[0] if model_list else None)
            if chosen:
                ACTUAL_MODEL = chosen["id"]
                print(f"Local server: model={ACTUAL_MODEL} (from /v1/models)")
                detected = True
        except Exception:
            pass

    if not detected:
        print(f"WARNING: Cannot detect model from {LOCAL_URL}")
        print("Files will be saved with model name 'local-unknown'")
        ACTUAL_MODEL = "local-unknown"

# ---------------------------------------------------------------------------
# Load data sources
# ---------------------------------------------------------------------------

# Meanings
sharpened_path = CLUSTERS / f"{SUFFIX}-meanings-sharpened.json"
default_path = CLUSTERS / f"{SUFFIX}-meanings.json"
meanings_path = sharpened_path if sharpened_path.exists() else default_path
if not meanings_path.exists():
    print(f"ERROR: No meanings file for {SUFFIX}", file=sys.stderr)
    sys.exit(1)
meanings = json.loads(meanings_path.read_text())
meaning_strings = [m["meaning"] for m in meanings]
print(f"Loaded {len(meaning_strings)} meanings from {meanings_path.name}")

# Survey (compound metadata: v1, reading, etc.)
survey_path = SCRIPT_DIR / "survey" / f"{SUFFIX}.json"
if not survey_path.exists():
    print(f"ERROR: No survey file at {survey_path}", file=sys.stderr)
    sys.exit(1)
survey = json.loads(survey_path.read_text())
survey_by_hw = {e["headword"]: e for e in survey}
print(f"Loaded {len(survey)} compounds from {survey_path.name}")

# JMDict
jmdict_path = ROOT / "jmdict.sqlite"
if not jmdict_path.exists():
    print(f"ERROR: jmdict.sqlite not found at {jmdict_path}", file=sys.stderr)
    sys.exit(1)
jmdict_db = sqlite3.connect(str(jmdict_path))


# ---------------------------------------------------------------------------
# JMDict lookup helpers
# ---------------------------------------------------------------------------


def jmdict_senses(text: str, reading: str = "") -> list[str]:
    """Look up all English senses for a word in jmdict.sqlite.
    When both kanji and reading are provided, finds the entry that matches
    both — this disambiguates homographs like 弾く (はじく "to flick" vs
    ひく "to play an instrument").
    Returns a list of sense strings, each being the glosses for one sense
    joined with '; '."""

    def extract_senses(entry_json: str) -> list[str]:
        entry = json.loads(entry_json)
        result = []
        for sense in entry.get("sense", []):
            glosses = [g["text"] for g in sense.get("gloss", [])
                       if g.get("lang", "eng") == "eng"]
            if glosses:
                result.append("; ".join(glosses))
        return result

    # If we have both kanji and reading, find the entry that matches both
    # to disambiguate homographs
    if text and reading:
        # Get all entries matching the kanji
        rows = jmdict_db.execute(
            "SELECT DISTINCT entries.entry_json FROM raws "
            "JOIN entries ON raws.entry_id = entries.id "
            "WHERE raws.text = ?", (text,)
        ).fetchall()
        for row in rows:
            entry = json.loads(row[0])
            entry_readings = [k.get("text", "") for k in entry.get("kana", [])]
            if reading in entry_readings:
                result = extract_senses(row[0])
                if result:
                    return result

    # Fall back to single-field lookup (reading first, then kanji)
    for lookup in [reading, text]:
        if not lookup:
            continue
        rows = jmdict_db.execute(
            "SELECT entries.entry_json FROM raws "
            "JOIN entries ON raws.entry_id = entries.id "
            "WHERE raws.text = ? LIMIT 1", (lookup,)
        ).fetchall()
        if rows:
            result = extract_senses(rows[0][0])
            if result:
                return result
    return []


def format_senses(senses: list[str]) -> str:
    """Format a list of sense strings as numbered entries, or a single line."""
    if not senses:
        return "(no dictionary entry found)"
    if len(senses) == 1:
        return senses[0]
    return " ".join(f"({i+1}) {s}." for i, s in enumerate(senses))


def format_senses_block(senses: list[str]) -> str:
    """Format senses as a multi-line numbered list for readability."""
    if not senses:
        return "  (no dictionary entry found)"
    if len(senses) == 1:
        return f"  {senses[0]}"
    return "\n".join(f"  ({i+1}) {s}" for i, s in enumerate(senses))


# ---------------------------------------------------------------------------
# Also load survey-based glosses as fallback (NINJAL senses)
# ---------------------------------------------------------------------------


def survey_senses(entry: dict) -> list[str]:
    """Get all senses from the survey entry (JMDict meanings + NINJAL)."""
    result = []
    jm = entry.get("jmdictMeanings") or []
    for sense in jm:
        if isinstance(sense, list) and sense:
            result.append("; ".join(sense))
    if not result:
        ns = entry.get("ninjal_senses") or []
        for s in ns:
            if isinstance(s, dict) and s.get("definition_en"):
                result.append(s["definition_en"])
    return result


def compound_senses(hw: str, reading: str, entry: dict) -> list[str]:
    """Get all senses for a compound, preferring jmdict.sqlite, falling back
    to survey data."""
    senses = jmdict_senses(hw, reading)
    if not senses:
        senses = survey_senses(entry)
    return senses


# ---------------------------------------------------------------------------
# Build prompt
# ---------------------------------------------------------------------------


def build_prompt(suffix: str, compounds: list[dict]) -> str:
    """Build a prompt for one or more compounds.

    Each compound dict has: headword, reading, v1, v1_reading, and the
    survey entry.
    """
    meanings_block = "\n".join(
        f"  {i+1}. \"{ms}\"" for i, ms in enumerate(meaning_strings)
    )

    # Per-compound blocks
    compound_blocks = []
    for comp in compounds:
        hw = comp["headword"]
        reading = comp["reading"]
        v1 = comp["v1"]
        v1_reading = comp["v1_reading"]
        entry = comp["entry"]

        # Compound senses
        c_senses = compound_senses(hw, reading, entry)
        c_block = format_senses_block(c_senses)

        # Prefix verb senses
        v1_senses = jmdict_senses(v1, v1_reading)
        v1_block = format_senses_block(v1_senses)

        compound_blocks.append(
            f"**{hw}** ({reading})\n"
            f"  Prefix verb {v1} ({v1_reading}):\n{v1_block}\n"
            f"  Compound {hw}:\n{c_block}"
        )

    compounds_section = "\n\n".join(compound_blocks)

    if len(compounds) == 1:
        compound_word = "this compound"
        task_intro = f"Assign the following compound verb to whichever meaning(s) -{suffix} contributes in it."
    else:
        compound_word = "each compound"
        task_intro = f"Assign each of the following compound verbs to whichever meaning(s) -{suffix} contributes in it."

    return f"""You are helping prepare data for a Japanese language learning app. You will classify how the suffix -{suffix} contributes to each dictionary sense of a compound verb.

The suffix -{suffix} has these distinct meanings when appended to a prefix verb:
{meanings_block}

{task_intro}

For {compound_word}, you are given the dictionary senses of both the prefix verb and the compound. For EACH compound sense, compare it against the prefix verb's senses to determine what -{suffix} adds:

**The key test:** A compound verb sense should combine the prefix verb's contribution AND the suffix's contribution. Think of it as "to <prefix verb action> and <suffix meaning contribution>." Both parts must be present:
- If a compound sense matches a prefix verb sense with no additional contribution from -{suffix}, it is lexicalized for that sense. This is true even if the compound sense superficially resembles one of the meaning definitions — what matters is whether -{suffix} is actually adding that meaning on top of the prefix verb, not whether the compound's definition happens to contain similar words.
- If a compound sense extends a prefix verb sense in a way that clearly matches one of the numbered meanings above, assign that meaning number to that sense.
- If a compound sense doesn't clearly relate to any prefix verb sense and no transparent contribution of -{suffix} can be identified, it is lexicalized for that sense.

{compounds_section}

Reason through each compound sense individually, comparing it against the prefix verb senses. Then output a JSON object where each key is a compound headword (kanji) and each value is an array of arrays — one inner array per compound sense, in the same order as listed above. Each inner array contains the meaning numbers (integers 1–{len(meaning_strings)}) that -{suffix} contributes for that sense, or is empty [] if that sense is lexicalized.

Example for a compound with 4 senses where sense 1 shows meaning 1, sense 2 is lexicalized, sense 3 shows meaning 4, and sense 4 is lexicalized:
{{
  "{compounds[0]['headword']}": [[1], [], [4], []]
}}"""


# ---------------------------------------------------------------------------
# API callers (same as validation-experiment.py)
# ---------------------------------------------------------------------------


def call_anthropic(model: str, prompt: str, temperature: float | None = None) -> str:
    import anthropic
    client = anthropic.Anthropic()
    kwargs = dict(model=model, max_tokens=16000,
                  messages=[{"role": "user", "content": prompt}])
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
    # Enable thinking for models that support it:
    # Gemini 2.5 Pro/Thinking use thinking_budget, Gemini 3 uses thinking_level
    if "gemini-3" in model:
        config.thinking_config = types.ThinkingConfig(thinking_level="medium")
    elif "thinking" in model or "pro" in model:
        config.thinking_config = types.ThinkingConfig(thinking_budget=8000)
    response = client.models.generate_content(
        model=model, contents=prompt, config=config)
    # Extract thinking and answer from response parts
    thinking_parts = []
    answer_parts = []
    for candidate in response.candidates:
        for part in candidate.content.parts:
            if getattr(part, "thought", False):
                thinking_parts.append(part.text)
            elif part.text:
                answer_parts.append(part.text)
    thinking = "\n".join(thinking_parts).strip()
    answer = "\n".join(answer_parts).strip()
    if thinking:
        return f"========== THINKING ==========\n{thinking}\n\n========== ANSWER ==========\n{answer}"
    return answer


def call_local(prompt: str, temperature: float | None = None) -> str:
    import requests
    body = {"messages": [{"role": "user", "content": prompt}], "max_tokens": 16384,
            "model": ACTUAL_MODEL}
    if temperature is not None:
        body["temperature"] = temperature
    resp = requests.post(f"{LOCAL_URL}/v1/chat/completions", json=body, timeout=30*60)
    resp.raise_for_status()
    msg = resp.json()["choices"][0]["message"]
    content = (msg.get("content") or "").strip()
    reasoning = (msg.get("reasoning_content") or msg.get("thinking") or "").strip()
    if reasoning:
        return f"========== THINKING ==========\n{reasoning}\n\n========== ANSWER ==========\n{content}"
    return content


def call_model(prompt: str) -> str:
    max_retries = 5
    for attempt in range(max_retries):
        try:
            if MODEL.startswith("claude-"):
                return call_anthropic(MODEL, prompt, args.temperature)
            elif MODEL.startswith("gemini-"):
                return call_gemini(MODEL, prompt, args.temperature)
            elif MODEL == "local":
                return call_local(prompt, args.temperature)
            else:
                raise ValueError(f"Unknown model: {MODEL}")
        except Exception as e:
            err_str = str(e).lower()
            is_rate_limit = ("rate" in err_str or "429" in err_str
                             or "overloaded" in err_str or "529" in err_str)
            if is_rate_limit and attempt < max_retries - 1:
                wait = 2 ** attempt * 5  # 5, 10, 20, 40, 80 seconds
                print(f"\n  Rate limited, waiting {wait}s (attempt {attempt+1}/{max_retries})...",
                      end=" ", flush=True)
                time.sleep(wait)
                continue
            raise


# ---------------------------------------------------------------------------
# Parse response
# ---------------------------------------------------------------------------


def extract_json_from_response(text: str) -> dict | None:
    """Extract the JSON object from a response that may contain thinking
    and/or markdown code fences."""
    # If there's an ANSWER section, only look there
    answer_marker = "========== ANSWER =========="
    if answer_marker in text:
        text = text[text.index(answer_marker) + len(answer_marker):]

    # Find all { at line starts, try first then last
    matches = list(re.finditer(r"^\s*\{", text, re.MULTILINE))
    if not matches:
        return None

    for match in [matches[0], matches[-1]]:
        json_text = text[match.start():].rstrip()
        json_text = re.sub(r"\n?```\s*$", "", json_text).strip()
        try:
            return json.loads(json_text)
        except json.JSONDecodeError:
            continue
    return None


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

OUTDIR = CLUSTERS / "per-compound"
OUTDIR.mkdir(exist_ok=True)


def save_result(suffix: str, compounds: list[dict], prompt: str,
                response: str, parsed: dict | None, elapsed: float = 0):
    """Save prompt + response to a timestamped archive file."""
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
    ts_file = (timestamp.replace(":", "-").replace("T", "_")
               .replace("Z", "").replace(".", "-"))
    safe_model = ACTUAL_MODEL.replace("/", "-").replace(":", "-")

    if len(compounds) == 1:
        label = compounds[0]["headword"]
    else:
        label = f"batch-{len(compounds)}"

    filename = f"{suffix}-{label}-{ts_file}-{safe_model}.txt"
    path = OUTDIR / filename

    # Record thinking config for reproducibility
    if MODEL.startswith("gemini-3"):
        thinking_note = "gemini-3 thinking_level=medium"
    elif MODEL.startswith("gemini-") and ("thinking" in MODEL or "pro" in MODEL):
        thinking_note = "gemini thinking_budget=8000"
    elif MODEL == "local":
        thinking_note = "local model native thinking (deepseek format)"
    elif MODEL.startswith("claude-"):
        thinking_note = "claude default (extended thinking not enabled)"
    else:
        thinking_note = "none"

    header_lines = [
        "========== FLAGS ==========",
        f"suffix: {suffix}",
        f"compounds: {', '.join(c['headword'] for c in compounds)}",
        f"model: {ACTUAL_MODEL}",
        f"temperature: {args.temperature}",
        f"thinking: {thinking_note}",
        f"batch-size: {len(compounds)}",
        f"elapsed-seconds: {elapsed:.1f}",
        f"timestamp: {timestamp}",
        "",
        "========== PROMPT ==========",
        prompt,
        "",
        "========== RESPONSE ==========",
        response,
    ]

    if parsed is not None:
        header_lines.extend([
            "",
            "========== PARSED ==========",
            json.dumps(parsed, ensure_ascii=False, indent=2),
        ])

    path.write_text("\n".join(header_lines))
    return path


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Resolve compound list
if args.all:
    compound_headwords = [e["headword"] for e in survey]
elif args.compounds:
    compound_headwords = args.compounds
    # Validate
    for hw in compound_headwords:
        if hw not in survey_by_hw:
            print(f"WARNING: {hw} not found in survey for {SUFFIX}")

# Build compound info dicts
compound_infos = []
for hw in compound_headwords:
    entry = survey_by_hw.get(hw)
    if not entry:
        continue
    compound_infos.append({
        "headword": hw,
        "reading": entry.get("reading", ""),
        "v1": entry.get("v1", ""),
        "v1_reading": entry.get("v1_reading", ""),
        "entry": entry,
    })

print(f"\n{len(compound_infos)} compounds to assign, batch size {args.batch_size}")

# Process in batches
all_results = {}
batch_size = args.batch_size

for i in range(0, len(compound_infos), batch_size):
    batch = compound_infos[i:i + batch_size]
    batch_label = ", ".join(c["headword"] for c in batch)
    print(f"\n[{i+1}–{i+len(batch)}/{len(compound_infos)}] {batch_label}")

    prompt = build_prompt(SUFFIX, batch)

    if args.dry_run:
        print(f"--- Prompt ({len(prompt)} chars) ---")
        print(prompt)
        print("--- End prompt ---")
        continue

    print(f"  Calling {MODEL}...", end=" ", flush=True)
    t0 = time.time()
    response = call_model(prompt)
    elapsed = time.time() - t0
    parsed = extract_json_from_response(response)

    if parsed:
        for hw, sense_assignments in parsed.items():
            if isinstance(sense_assignments, list) and all(isinstance(s, list) for s in sense_assignments):
                # Per-sense format: [[1], [], [4], []]
                all_results[hw] = sense_assignments
                parts = []
                for si, ms in enumerate(sense_assignments):
                    if ms:
                        parts.append(f"s{si+1}→{'+'.join(f'M{m}' for m in ms)}")
                    else:
                        parts.append(f"s{si+1}→lex")
                print(f"{hw}: {' '.join(parts)}", end="  ")
            elif isinstance(sense_assignments, list):
                # Legacy per-compound format: [1, 3, 4]
                all_results[hw] = sense_assignments
                label = "+".join(f"M{m}" for m in sense_assignments) if sense_assignments else "lex"
                print(f"{hw} → {label}", end="  ")
        print()
    else:
        print("ERROR: could not parse JSON from response")

    path = save_result(SUFFIX, batch, prompt, response, parsed, elapsed)
    print(f"  ({elapsed:.1f}s) Saved: {path.name}")

# Summary
if all_results and not args.dry_run:
    print(f"\n{'='*60}")
    print(f"Summary: {len(all_results)} compounds assigned")
    print(f"{'='*60}")
    for hw, sa in all_results.items():
        if isinstance(sa, list) and sa and isinstance(sa[0], list):
            # Per-sense
            parts = []
            for si, ms in enumerate(sa):
                if ms:
                    parts.append(f"s{si+1}→{'+'.join(f'M{m}' for m in ms)}")
                else:
                    parts.append(f"s{si+1}→lex")
            print(f"  {hw}: {' '.join(parts)}")
        elif isinstance(sa, list):
            labels = "+".join(f"M{m}" for m in sa) if sa else "lexicalized"
            print(f"  {hw} → {labels}")

jmdict_db.close()
