#!/usr/bin/env python3
"""
Analyze Google Antigravity (AGY) token usage, API-equivalent costs, and active
session intervals from local transcript JSONL files.

Scans Antigravity's three local surfaces:
    ~/.gemini/antigravity-cli/brain/<conv-id>/.system_generated/logs/transcript.jsonl
    ~/.gemini/antigravity/brain/<conv-id>/.system_generated/logs/transcript.jsonl
    ~/.gemini/antigravity-ide/brain/<conv-id>/.system_generated/logs/transcript.jsonl

Optionally supplements cache_write_tokens from sibling SQLite stores at
    ~/.gemini/<surface>/conversations/<conv-id>.db (gen_metadata protobuf).

Usage:
    python3 analyze_usage.py [OPTIONS]

Options:
    --range <spec>       Time range: today, week, month, YYYY-MM-DD, or YYYY-MM-DD:YYYY-MM-DD
    --data-dir <path>    Override ~/.gemini root or brain directory (repeatable, for testing)
    --cache-dir <path>   Override ~/Library/Caches/AGYMonitor cache directory
    --project <keyword>  Filter sessions by project/workspace/surface keyword
    --by-project         Group text results by project
    --by-day             Group text results by day
    --json               Output JSON instead of text table
    --no-sessions        With --json: omit the per-session array (smaller payload)
    --no-cache           Bypass the incremental scan cache (read AND write)
    --offline            Skip remote LiteLLM fetch; use fresh/stale cache or fallback pricing
    --gap-minutes N      Active-time sessionization gap in minutes (default 10)
    --time-year YYYY     Emit per-day active-time totals for a whole year (JSON only)
"""
from __future__ import annotations

import argparse
from collections import defaultdict
from datetime import datetime, timedelta, timezone
import fnmatch
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import sys
import tempfile
import time
from typing import Any, Dict, List, Optional, Set, Tuple
import urllib.parse
import urllib.request

__version__ = "2.0.0"

# ---------------------------------------------------------------------------
# Antigravity surfaces & cache paths
# ---------------------------------------------------------------------------
SURFACE_NAMES: Tuple[str, ...] = (
    "antigravity-cli",
    "antigravity",
    "antigravity-ide",
)

DEFAULT_GEMINI_ROOT = Path.home() / ".gemini"
DEFAULT_CACHE_DIR = Path.home() / "Library" / "Caches" / "AGYMonitor"

# Runtime-configurable cache paths (overridable via --cache-dir or AGY_CACHE_DIR)
PRICING_CACHE_PATH = DEFAULT_CACHE_DIR / "litellm_pricing.json"
SCAN_CACHE_PATH = DEFAULT_CACHE_DIR / "scan-cache.json"

# ---------------------------------------------------------------------------
# Active-time tracking
# ---------------------------------------------------------------------------
DEFAULT_GAP_MINUTES = 10
_GAP_MINUTES = DEFAULT_GAP_MINUTES

# Accepted event epoch range: [1970-01-01, 9999-01-01) UTC.
# Rejects Go zero-time sentinels ("0001-01-01T00:00:00Z") and garbage timestamps.
_TIME_EPOCH_MIN = 0
_TIME_EPOCH_MAX = 253370764800  # 9999-01-01T00:00:00Z

# ---------------------------------------------------------------------------
# Model classification & pricing
# ---------------------------------------------------------------------------
MODEL_CLASSES: Tuple[str, ...] = (
    "carbon",
    "argon",
    "neon",
    "hydrogen",
    "flash",
    "claude",
    "other",
)

EMOJI: Dict[str, str] = {
    "carbon":   "\U0001f535",  # 🔵
    "argon":    "\U0001f7e2",  # 🟢
    "neon":     "\U0001f534",  # 🔴
    "hydrogen": "\U0001f7e3",  # 🟣
    "flash":    "\u26a1",      # ⚡
    "claude":   "\U0001f7e0",  # 🟠
    "other":    "\u26aa",      # ⚪
}

LITELLM_PRICING_URL = (
    "https://raw.githubusercontent.com/BerriAI/litellm/main/"
    "model_prices_and_context_window.json"
)
PRICING_CACHE_TTL = 86400  # 24 hours in seconds

# Offline API-equivalent fallback pricing (USD per 1M tokens) by ModelClass.
# Uses Google's official non-promotional standard list rates for Gemini 4 / 3.8.
FALLBACK_PRICING: Dict[str, Dict[str, float]] = {
    "carbon":   {"input": 4.00, "output": 20.00, "cache_write": 5.00,   "cache_read": 0.20},
    "argon":    {"input": 4.00, "output": 20.00, "cache_write": 5.00,   "cache_read": 0.20},
    "neon":     {"input": 3.00, "output": 15.00, "cache_write": 3.75,   "cache_read": 0.15},
    "hydrogen": {"input": 1.50, "output":  7.50, "cache_write": 1.875,  "cache_read": 0.075},
    "flash":    {"input": 1.50, "output":  7.50, "cache_write": 1.875,  "cache_read": 0.15},
    "claude":   {"input": 3.00, "output": 15.00, "cache_write": 3.75,   "cache_read": 0.30},
    "other":    {"input": 0.15, "output":  0.60, "cache_write": 0.1875, "cache_read": 0.0375},
}

# Ordered family-level API-equivalent fallback pricing (USD per 1M tokens) covering
# all Antigravity codename families and partner models (checked via fnmatch before
# falling back to class-level FALLBACK_PRICING).
FALLBACK_FAMILY_PRICING: List[Tuple[str, Dict[str, float]]] = [
    ("gemini-4-hydrogen*",             {"input": 1.50, "output":  7.50, "cache_write": 1.875,  "cache_read": 0.075}),
    ("gemini-flash-worker-agy*",       {"input": 1.50, "output":  7.50, "cache_write": 1.875,  "cache_read": 0.075}),
    ("gemini-pro-orchestrator-neon*",  {"input": 3.00, "output": 15.00, "cache_write": 3.75,   "cache_read": 0.15}),
    ("gemini-4-neon*",                 {"input": 3.00, "output": 15.00, "cache_write": 3.75,   "cache_read": 0.15}),
    ("gemini-pro-orchestrator-argon*", {"input": 4.00, "output": 20.00, "cache_write": 5.00,   "cache_read": 0.20}),
    ("gemini-4-argon*",                {"input": 4.00, "output": 20.00, "cache_write": 5.00,   "cache_read": 0.20}),
    ("gemini-4-carbon*",               {"input": 4.00, "output": 20.00, "cache_write": 5.00,   "cache_read": 0.20}),
    ("gemini-pro-orchestrator*",       {"input": 4.00, "output": 20.00, "cache_write": 5.00,   "cache_read": 0.20}),
    ("gemini-3.8-flash-lite*",         {"input": 0.50, "output":  3.00, "cache_write": 0.625,  "cache_read": 0.05}),
    ("gemini-3.8-flash*",              {"input": 1.50, "output":  7.50, "cache_write": 1.875,  "cache_read": 0.15}),
    ("gemini-3.5-flash-lite*",         {"input": 0.30, "output":  2.50, "cache_write": 0.375,  "cache_read": 0.03}),
    ("gemini-3.5-flash*",              {"input": 1.50, "output":  9.00, "cache_write": 1.875,  "cache_read": 0.15}),
    ("gemini-3*-pro*",                 {"input": 2.00, "output": 12.00, "cache_write": 2.50,   "cache_read": 0.20}),
    ("gemini-2.5-pro*",                {"input": 1.25, "output": 10.00, "cache_write": 1.5625, "cache_read": 0.125}),
    ("gemini-2.5-flash-lite*",         {"input": 0.10, "output":  0.40, "cache_write": 0.125,  "cache_read": 0.01}),
    ("gemini-2.5-flash*",              {"input": 0.30, "output":  2.50, "cache_write": 0.375,  "cache_read": 0.03}),
    ("gemini-*-pro*",                  {"input": 2.00, "output": 12.00, "cache_write": 2.50,   "cache_read": 0.20}),
    ("gemini-*-ultra*",                {"input": 4.00, "output": 20.00, "cache_write": 5.00,   "cache_read": 0.20}),
    ("gemini-*-flash-lite*",           {"input": 0.30, "output":  1.50, "cache_write": 0.375,  "cache_read": 0.03}),
    ("gemini-*-flash*",                {"input": 0.75, "output":  3.75, "cache_write": 0.9375, "cache_read": 0.075}),
    ("claude-opus-*",                  {"input": 5.00, "output": 25.00, "cache_write": 6.25,   "cache_read": 0.50}),
    ("claude-sonnet-*",                {"input": 3.00, "output": 15.00, "cache_write": 3.75,   "cache_read": 0.30}),
    ("claude-haiku-*",                 {"input": 1.00, "output":  5.00, "cache_write": 1.25,   "cache_read": 0.10}),
    ("gpt-oss-*",                      {"input": 0.15, "output":  0.60, "cache_write": 0.1875, "cache_read": 0.0375}),
]

AGY_MODEL_ALIASES: Dict[str, str] = {
    "gemini-flash-worker-agy": "gemini-4-hydrogen",
    "gemini-pro-orchestrator-neon": "gemini-4-neon",
    "gemini-pro-orchestrator-argon": "gemini-4-argon",
    "gemini-pro-orchestrator": "gemini-4-carbon",
}

# Standard (non-promotional) list-price floors applied on top of LiteLLM entries
# so introductory promo windows do not understate API-equivalent value.
STANDARD_LIST_PRICE_FLOORS: Dict[str, Dict[str, float]] = {
    "gemini-4-carbon":   {"input": 4.00, "output": 20.00, "cache_write": 5.00,  "cache_read": 0.20},
    "gemini-4-argon":    {"input": 4.00, "output": 20.00, "cache_write": 5.00,  "cache_read": 0.20},
    "gemini-4-neon":     {"input": 3.00, "output": 15.00, "cache_write": 3.75,  "cache_read": 0.15},
    "gemini-4-hydrogen": {"input": 1.50, "output":  7.50, "cache_write": 1.875, "cache_read": 0.075},
    "gemini-3.8-flash":  {"input": 1.50, "output":  7.50, "cache_write": 1.875, "cache_read": 0.15},
}

MODEL_PRICING: Dict[str, Dict[str, float]] = {k: dict(v) for k, v in FALLBACK_PRICING.items()}
_LITELLM_RAW: Dict[str, Any] = {}
_PRICING_SOURCE = "fallback"

# Self-diagnostic counters surfaced in JSON and text outputs.
_SCAN_STATS: Dict[str, int] = {
    "raw_usage_lines": 0,
    "unique_messages": 0,
    "null_msg_id_lines": 0,
    "usage_upgraded_lines": 0,
    "skipped_lines": 0,
    "sentinel_ts_lines": 0,
    "skipped_encrypted_pb": 0,
    "sqlite_supplemented_steps": 0,
    "files_failed": 0,
    "null_ts_lines": 0,
    "prefiltered_lines": 0,
    "cache_hit_files": 0,
    "cache_miss_files": 0,
    "cache_pruned_files": 0,
    "time_event_lines": 0,
}

SCAN_CACHE_FORMAT_VERSION = 1
_CACHE_ACTIVE = False


def set_cache_dir(cache_dir: Path) -> None:
    """Configure pricing and incremental scan cache file locations."""
    global PRICING_CACHE_PATH, SCAN_CACHE_PATH
    PRICING_CACHE_PATH = cache_dir / "litellm_pricing.json"
    SCAN_CACHE_PATH = cache_dir / "scan-cache.json"


def _init_cache_dir_from_env_or_arg(arg_cache_dir: Optional[str]) -> None:
    raw = arg_cache_dir or os.environ.get("AGY_CACHE_DIR")
    if raw:
        set_cache_dir(Path(raw).expanduser())
    else:
        set_cache_dir(DEFAULT_CACHE_DIR)


# ---------------------------------------------------------------------------
# Incremental per-file scan cache
# ---------------------------------------------------------------------------
def _tz_stamp() -> List[Any]:
    """Static system-timezone fingerprint stamped into the cache header."""
    return [time.tzname[0], time.tzname[1], time.timezone, time.altzone, time.daylight]


def _valid_cache_entry(e: Any) -> bool:
    """Strict structural validation of one per-file cache entry."""
    try:
        if not isinstance(e, dict):
            return False
        if not isinstance(e.get("mtime_ns"), int) or not isinstance(e.get("size"), int):
            return False
        db_sig = e.get("db_sig")
        if not (isinstance(db_sig, list) and len(db_sig) == 4
                and all(isinstance(x, int) for x in db_sig)):
            return False
        if not isinstance(e.get("conv_id"), str) or not e.get("conv_id"):
            return False
        for k in ("peek_ts", "first_ts"):
            v = e.get(k)
            if v is not None and not isinstance(v, str):
                return False
        if not isinstance(e.get("first_msg"), str):
            return False
        for aggk in ("agg", "agg_no_ts"):
            agg = e.get(aggk)
            if not isinstance(agg, dict):
                return False
            for day, models in agg.items():
                if not isinstance(day, str) or not isinstance(models, dict):
                    return False
                for ms, sums in models.items():
                    if not isinstance(ms, str):
                        return False
                    if not (isinstance(sums, list) and len(sums) == 5
                            and all(isinstance(x, int) and x >= 0 for x in sums)):
                        return False
        steps = e.get("steps")
        if not isinstance(steps, dict):
            return False
        for sidx, srec in steps.items():
            if not isinstance(sidx, str):
                return False
            if not (isinstance(srec, list) and len(srec) == 7
                    and isinstance(srec[0], str) and isinstance(srec[1], str)
                    and all(isinstance(x, int) and x >= 0 for x in srec[2:])):
                return False
        unindexed = e.get("unindexed")
        if not isinstance(unindexed, list):
            return False
        for urec in unindexed:
            if not (isinstance(urec, list) and len(urec) == 7
                    and isinstance(urec[0], str) and isinstance(urec[1], str)
                    and all(isinstance(x, int) and x >= 0 for x in urec[2:])):
                return False
        cbd = e.get("counters_by_day")
        if not isinstance(cbd, dict):
            return False
        for day, c in list(cbd.items()) + [("", e.get("counters_no_ts"))]:
            if not isinstance(day, str):
                return False
            if not (isinstance(c, list) and len(c) == 4 and all(isinstance(x, int) for x in c)):
                return False
        for k in (
            "skipped_lines",
            "sentinel_ts_lines",
            "sqlite_supplemented_steps",
            "prefiltered_lines",
            "null_ts_lines",
            "time_event_lines",
        ):
            if not isinstance(e.get(k), int):
                return False
        tm = e.get("time")
        if not isinstance(tm, list):
            return False
        for iv in tm:
            if not (isinstance(iv, list) and len(iv) == 3
                    and isinstance(iv[0], int) and isinstance(iv[1], int)
                    and _TIME_EPOCH_MIN <= iv[0] <= iv[1] < _TIME_EPOCH_MAX
                    and isinstance(iv[2], dict)):
                return False
            for cls, n in iv[2].items():
                if cls not in MODEL_CLASSES or not isinstance(n, int) or n < 1:
                    return False
        return True
    except Exception:
        return False


def _load_scan_cache() -> Dict[str, Any]:
    """Load the per-file scan cache; any anomaly silently returns {}."""
    try:
        with open(SCAN_CACHE_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return {}
        if data.get("format_version") != SCAN_CACHE_FORMAT_VERSION:
            return {}
        if data.get("script_version") != __version__:
            return {}
        if data.get("tz") != _tz_stamp():
            return {}
        if data.get("gap_minutes") != _GAP_MINUTES:
            return {}
        files = data.get("files")
        if not isinstance(files, dict):
            return {}
        # Drop only individual malformed entries instead of discarding the entire cache.
        valid_files: Dict[str, Any] = {}
        for path, entry in files.items():
            if isinstance(path, str) and _valid_cache_entry(entry):
                valid_files[path] = entry
        return valid_files
    except Exception:
        return {}


def _write_scan_cache(files: Dict[str, Any]) -> None:
    """Atomic write (NamedTemporaryFile in same directory + os.replace)."""
    tmp_path: Optional[Path] = None
    try:
        SCAN_CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        doc = {
            "format_version": SCAN_CACHE_FORMAT_VERSION,
            "script_version": __version__,
            "tz": _tz_stamp(),
            "gap_minutes": _GAP_MINUTES,
            "files": files,
        }
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=str(SCAN_CACHE_PATH.parent),
            prefix=f"{SCAN_CACHE_PATH.name}.",
            suffix=".tmp",
            delete=False,
        ) as f:
            tmp_path = Path(f.name)
            json.dump(doc, f, allow_nan=False)
        os.replace(tmp_path, SCAN_CACHE_PATH)
    except Exception:
        if tmp_path is not None:
            try:
                tmp_path.unlink(missing_ok=True)
            except Exception:
                pass


# ---------------------------------------------------------------------------
# LiteLLM & fallback pricing
# ---------------------------------------------------------------------------
def _fetch_litellm_pricing(offline: bool = False) -> Optional[Dict[str, Any]]:
    """Fetch pricing JSON from LiteLLM GitHub with 24h local cache in ~/Library/Caches/AGYMonitor/."""
    cache_corrupt = False
    if PRICING_CACHE_PATH.exists():
        try:
            age = time.time() - PRICING_CACHE_PATH.stat().st_mtime
            if age < PRICING_CACHE_TTL or offline:
                with open(PRICING_CACHE_PATH, "r", encoding="utf-8") as f:
                    cached = json.load(f)
                if isinstance(cached, dict):
                    return cached
                cache_corrupt = True
        except Exception:
            cache_corrupt = True

    if offline or os.environ.get("AGY_OFFLINE_PRICING") == "1":
        return None

    # Cold-start / corrupt-cache negative backoff: avoid 5s network timeout on every scan while offline.
    backoff_path = PRICING_CACHE_PATH.with_name(f"{PRICING_CACHE_PATH.name}.backoff")
    if (not PRICING_CACHE_PATH.exists() or cache_corrupt) and backoff_path.exists():
        try:
            if (time.time() - backoff_path.stat().st_mtime) < 3600:
                return None
        except Exception:
            pass

    try:
        req = urllib.request.Request(
            LITELLM_PRICING_URL,
            headers={"User-Agent": f"AGYMonitor/{__version__}"},
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            raw_bytes = resp.read(16 * 1024 * 1024)
        data = json.loads(raw_bytes.decode("utf-8"))
        if not isinstance(data, dict):
            return None
    except Exception:
        if PRICING_CACHE_PATH.exists():
            try:
                with open(PRICING_CACHE_PATH, "r", encoding="utf-8") as f:
                    stale = json.load(f)
                if isinstance(stale, dict):
                    try:
                        t = time.time() - (PRICING_CACHE_TTL - 3600)
                        os.utime(PRICING_CACHE_PATH, (t, t))
                    except Exception:
                        pass
                    return stale
            except Exception:
                pass
            # Corrupt or non-dict pricing cache file: remove best-effort so `.backoff` takes effect.
            try:
                PRICING_CACHE_PATH.unlink(missing_ok=True)
            except Exception:
                pass
        try:
            backoff_path.parent.mkdir(parents=True, exist_ok=True)
            backoff_path.write_text("1", encoding="utf-8")
        except Exception:
            pass
        return None

    tmp_path: Optional[Path] = None
    try:
        PRICING_CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=str(PRICING_CACHE_PATH.parent),
            prefix=f"{PRICING_CACHE_PATH.name}.",
            suffix=".tmp",
            delete=False,
        ) as f:
            tmp_path = Path(f.name)
            json.dump(_sanitize_json_value(data), f, allow_nan=False)
        os.replace(tmp_path, PRICING_CACHE_PATH)
        try:
            backoff_path.unlink(missing_ok=True)
        except Exception:
            pass
    except Exception:
        if tmp_path is not None:
            try:
                tmp_path.unlink(missing_ok=True)
            except Exception:
                pass
    return data


def _per_token_to_per_million(cost_per_token: float) -> float:
    return cost_per_token * 1_000_000.0


def _is_num(val: Any) -> bool:
    if isinstance(val, bool) or not isinstance(val, (int, float)):
        return False
    try:
        return math.isfinite(val)
    except OverflowError:
        return False


def _sanitize_json_value(obj: Any) -> Any:
    """Recursively replace any non-finite float (NaN/Inf) with 0.0 for strict JSON."""
    if isinstance(obj, float):
        return obj if math.isfinite(obj) else 0.0
    if isinstance(obj, dict):
        return {k: _sanitize_json_value(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_sanitize_json_value(v) for v in obj]
    if isinstance(obj, tuple):
        return [_sanitize_json_value(v) for v in obj]
    return obj


def _extract_litellm_entry(entry: Any) -> Optional[Dict[str, float]]:
    """Extract per-1M pricing from a LiteLLM model entry, guarding against malformed data."""
    if not isinstance(entry, dict):
        return None
    inp = entry.get("input_cost_per_token")
    out = entry.get("output_cost_per_token")
    if not _is_num(inp) or not _is_num(out):
        return None
    if inp < 0 or out < 0:
        return None
    cw = entry.get("cache_creation_input_token_cost")
    if not _is_num(cw) or cw < 0:
        cw = inp * 1.25
    cr = entry.get("cache_read_input_token_cost")
    if not _is_num(cr) or cr < 0:
        cr = inp * 0.1
    res = {
        "input":       _per_token_to_per_million(float(inp)),
        "output":      _per_token_to_per_million(float(out)),
        "cache_write": _per_token_to_per_million(float(cw)),
        "cache_read":  _per_token_to_per_million(float(cr)),
    }
    if not all(math.isfinite(v) for v in res.values()):
        return None
    return res


def _apply_standard_list_floor(
    candidates: List[str],
    pricing: Dict[str, float],
) -> Dict[str, float]:
    """Enforce non-promotional Google standard list rates when LiteLLM carries a promo rate."""
    for c in candidates:
        floor = STANDARD_LIST_PRICE_FLOORS.get(c.lower())
        if floor is not None:
            return {k: max(pricing[k], floor[k]) for k in floor}
    return pricing


def load_pricing(offline: bool = False) -> None:
    """Populate MODEL_PRICING & _LITELLM_RAW from LiteLLM (24h cached) or FALLBACK_PRICING."""
    global MODEL_PRICING, _LITELLM_RAW, _PRICING_SOURCE

    MODEL_PRICING = {k: dict(v) for k, v in FALLBACK_PRICING.items()}
    raw = _fetch_litellm_pricing(offline=offline)
    if not raw:
        _LITELLM_RAW = {}
        _PRICING_SOURCE = "fallback"
        return

    _LITELLM_RAW = raw
    _PRICING_SOURCE = "litellm"

    # Update public representative tiers when available in LiteLLM; standard list floors
    # apply so temporary promo windows do not understate Gemini 4 API-equivalent value.
    sonnet_pat = re.compile(r"^claude-sonnet-(\d+)(?:-(\d{1,2}))?$")
    newest_sonnet: Optional[Tuple[Tuple[int, int], str]] = None
    for key in raw.keys():
        m = sonnet_pat.match(key)
        if m:
            ver = (int(m.group(1)), int(m.group(2)) if m.group(2) else 0)
            if newest_sonnet is None or ver > newest_sonnet[0]:
                newest_sonnet = (ver, key)
    if newest_sonnet is not None:
        extracted = _extract_litellm_entry(raw[newest_sonnet[1]])
        if extracted:
            MODEL_PRICING["claude"] = extracted

    for codename in ("carbon", "argon", "neon", "hydrogen"):
        base_name = f"gemini-4-{codename}"
        for candidate in (base_name, f"gemini/{base_name}", f"vertex_ai/{base_name}"):
            if candidate in raw:
                extracted = _extract_litellm_entry(raw[candidate])
                if extracted:
                    MODEL_PRICING[codename] = _apply_standard_list_floor([base_name], extracted)
                    break


_MODIFIER_SUFFIX_RE = re.compile(r"(?:-(?:tiered|xhigh|high|medium|low|minimal))+$", re.IGNORECASE)
_VERSION_SUFFIX_RE = re.compile(r"-v\d+:\d+$")
_BRACKET_SUFFIX_RE = re.compile(r"\[\w+\]$")


def _candidate_model_names(model_str: str) -> List[str]:
    """Generate canonical LiteLLM lookup candidates for an AGY model identifier."""
    if not model_str or not isinstance(model_str, str):
        return []
    s = model_str.strip()
    if not s:
        return []

    out: List[str] = []

    def _add(v: str) -> None:
        if v and v not in out:
            out.append(v)

    _add(s)
    s_clean = _BRACKET_SUFFIX_RE.sub("", s).split("@", 1)[0]
    s_clean = _VERSION_SUFFIX_RE.sub("", s_clean)
    _add(s_clean)

    # Strip provider prefixes like vertex_ai/, gemini/, anthropic/, openai/
    bare = s_clean
    while "/" in bare:
        head, tail = bare.split("/", 1)
        if head.lower() in (
            "gemini", "google", "vertex_ai", "anthropic", "bedrock",
            "openai", "azure_ai", "openrouter", "together_ai", "groq",
        ):
            bare = tail
        else:
            break
    _add(bare)

    # Also try without AGY reasoning-effort / tiered suffixes (e.g. -tiered-xhigh)
    no_mod = _MODIFIER_SUFFIX_RE.sub("", bare)
    _add(no_mod)

    # Map AGY-internal orchestrator/worker aliases to canonical Gemini 4 IDs
    alias = AGY_MODEL_ALIASES.get(no_mod.lower())
    if alias:
        _add(alias)

    # For Claude models, LiteLLM uses hyphens for version numbers (4.6 -> 4-6)
    if "claude" in bare.lower():
        _add(bare.replace(".", "-"))
        _add(no_mod.replace(".", "-"))

    return out


def lookup_model_pricing(model_str: str) -> Optional[Dict[str, float]]:
    """Look up per-1M token pricing for `model_str` in LiteLLM data."""
    if not _LITELLM_RAW or not model_str:
        return None

    candidates = _candidate_model_names(model_str)
    # 1. Direct match
    for c in candidates:
        if c in _LITELLM_RAW:
            p = _extract_litellm_entry(_LITELLM_RAW[c])
            if p is not None:
                return _apply_standard_list_floor(candidates, p)

    # 2. Provider-prefixed match
    prefixes = (
        "gemini/",
        "vertex_ai/",
        "anthropic/",
        "bedrock/",
        "openai/",
        "openrouter/",
        "openrouter/openai/",
        "groq/openai/",
        "together_ai/openai/",
    )
    for c in candidates:
        for prefix in prefixes:
            key = prefix + c
            if key in _LITELLM_RAW:
                p = _extract_litellm_entry(_LITELLM_RAW[key])
                if p is not None:
                    return _apply_standard_list_floor(candidates, p)

    return None


def lookup_fallback_pricing(model_str: str) -> Dict[str, float]:
    """Return offline API-equivalent per-1M pricing for any AGY or partner model."""
    m = (model_str or "").strip().lower()
    if m:
        # Strip optional provider prefix before pattern matching
        bare = m.rsplit("/", 1)[-1]
        for pattern, pricing in FALLBACK_FAMILY_PRICING:
            if fnmatch.fnmatchcase(bare, pattern) or fnmatch.fnmatchcase(m, pattern):
                return pricing
    cls = classify_model(model_str)
    return MODEL_PRICING.get(cls, FALLBACK_PRICING.get(cls, FALLBACK_PRICING["other"]))


# ---------------------------------------------------------------------------
# Classification, timestamps & active-time helpers
# ---------------------------------------------------------------------------
def classify_model(raw: str) -> str:
    """Classify an Antigravity model string into carbon/argon/neon/hydrogen/flash/claude/other.

    Matches `ModelClass.classify(_:)` in `Sources/Core_ModelClass.swift`:
      1. contains "hydrogen" or "flash-worker-agy" -> "hydrogen"
      2. contains "argon"    -> "argon" (checked BEFORE "orchestrator" so
         "gemini-pro-orchestrator-argon" maps to "argon")
      3. contains "neon"     -> "neon" (checked BEFORE "orchestrator" so
         "gemini-pro-orchestrator-neon" maps to "neon")
      4. contains "carbon" or "orchestrator" or ("gemini" and "pro") or "ultra" -> "carbon"
      5. contains "flash" or "lite" -> "flash"
      6. contains "claude" or "opus" or "sonnet" or "haiku" -> "claude"
      7. otherwise -> "other"
    """
    if not raw or not isinstance(raw, str):
        return "other"
    m = raw.strip().lower()
    if not m:
        return "other"
    if "hydrogen" in m or "flash-worker-agy" in m:
        return "hydrogen"
    if "argon" in m:
        return "argon"
    if "neon" in m:
        return "neon"
    if "carbon" in m or "orchestrator" in m or ("gemini" in m and "pro" in m) or "ultra" in m:
        return "carbon"
    if "flash" in m or "lite" in m:
        return "flash"
    if "claude" in m or "opus" in m or "sonnet" in m or "haiku" in m:
        return "claude"
    return "other"


def is_sentinel_timestamp(ts_str: Any) -> bool:
    """True when `ts_str` is Go's zero time (`0001-01-01...`) or pre-1970 sentinel."""
    if not isinstance(ts_str, str):
        return False
    s = ts_str.strip()
    if not s:
        return False
    if s.startswith("0001-01-01") or s.startswith("0000-"):
        return True
    if len(s) >= 4 and s[:4].isdigit() and int(s[:4]) < 1970:
        return True
    return False


def parse_iso_ts(ts_str: Any) -> Optional[datetime]:
    """Parse an ISO-8601 timestamp string to an aware datetime, rejecting sentinels."""
    if not ts_str or not isinstance(ts_str, str):
        return None
    s = ts_str.strip()
    if not s or is_sentinel_timestamp(s):
        return None
    if s.endswith("Z") or s.endswith("z"):
        s = s[:-1] + "+00:00"
    # Python 3.9's datetime.fromisoformat requires exactly 0, 3, or 6 fractional
    # digits (Go's RFC3339Nano emits variable 1-9 digits like .123456789+00:00).
    s = _normalize_iso_fraction(s)
    try:
        dt = datetime.fromisoformat(s)
    except Exception:
        return None
    if dt.tzinfo is None or dt.year < 1970:
        return None
    return dt


_ISO_FRAC_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2})\.(\d+)(.*)$")
_ISO_TZ_NOCOLON_RE = re.compile(r"([+-]\d{2})(\d{2})$")


def _normalize_iso_fraction(s: str) -> str:
    """Normalize fractional seconds and +HHMM offsets so Python 3.9 fromisoformat succeeds."""
    s = _ISO_TZ_NOCOLON_RE.sub(r"\1:\2", s)
    m = _ISO_FRAC_RE.match(s)
    if not m:
        return s
    frac = m.group(2)
    if len(frac) == 3 or len(frac) == 6:
        return s
    frac6 = (frac + "000000")[:6]
    return f"{m.group(1)}.{frac6}{m.group(3)}"


def _ts_to_epoch(dt: Optional[datetime]) -> Optional[int]:
    if dt is None or dt.tzinfo is None:
        return None
    ep = int(dt.replace(microsecond=0).timestamp())
    if not (_TIME_EPOCH_MIN <= ep < _TIME_EPOCH_MAX):
        return None
    return ep


def _gap_merge(pairs_sorted: List[Tuple[int, int]], gap: int) -> List[Tuple[int, int]]:
    """Merge sorted (start, end) epoch pairs whose gap is <= `gap`."""
    merged: List[List[int]] = []
    for a, b in pairs_sorted:
        if merged and a - merged[-1][1] <= gap:
            if b > merged[-1][1]:
                merged[-1][1] = b
        else:
            merged.append([a, b])
    return [(x[0], x[1]) for x in merged]


def _dominant_model(counts: Dict[str, int]) -> Optional[str]:
    """Dominant ModelClass inside one active interval; ties break by MODEL_CLASSES order."""
    if not counts:
        return None
    return max(
        counts.items(),
        key=lambda kv: (kv[1], -MODEL_CLASSES.index(kv[0])),
    )[0]


def _first_offset_change(lo: datetime, hi: datetime) -> datetime:
    """First instant in (lo, hi] whose local UTC offset differs from lo's."""
    off = lo.astimezone().utcoffset()
    lo_e, hi_e = int(lo.timestamp()), int(hi.timestamp())
    while hi_e - lo_e > 1:
        mid = (lo_e + hi_e) // 2
        if datetime.fromtimestamp(mid, timezone.utc).astimezone().utcoffset() == off:
            lo_e = mid
        else:
            hi_e = mid
    return datetime.fromtimestamp(hi_e, timezone.utc)


def _wall_sec(t: datetime, off: timedelta, day: Any) -> int:
    wall = t.astimezone(timezone.utc).replace(tzinfo=None) + off
    delta = (wall - datetime(day.year, day.month, day.day)).total_seconds()
    return int(min(max(delta, 0), 86400))


def _split_interval_by_local_day(a: datetime, b: datetime) -> List[Tuple[str, int, int]]:
    """Split aware interval [a, b] at local midnights and DST transitions."""
    pieces: List[Tuple[str, int, int]] = []
    cur = a
    while True:
        day = cur.astimezone().date()
        day_key = day.strftime("%Y-%m-%d")
        next_mid = (datetime(day.year, day.month, day.day) + timedelta(days=1)).astimezone()
        if next_mid <= cur:
            next_mid = cur + timedelta(days=1)
        seg_end = min(b, next_mid)
        sub = cur
        while True:
            off = sub.astimezone().utcoffset() or timedelta(0)
            if seg_end.astimezone().utcoffset() == off:
                nxt = seg_end
            else:
                nxt = _first_offset_change(sub, seg_end)
            s = _wall_sec(sub, off, day)
            e = _wall_sec(nxt, off, day)
            pieces.append((day_key, s, e))
            if nxt >= seg_end:
                break
            sub = nxt
        if seg_end >= b:
            break
        cur = seg_end
    return pieces


def cost_for_message(usage: Dict[str, int], model_str: str) -> float:
    """Compute API-equivalent USD cost for token usage on `model_str`."""
    p = lookup_model_pricing(model_str)
    if p is None:
        p = lookup_fallback_pricing(model_str)
    return (
        usage.get("input_tokens", 0)  * p["input"]       / 1_000_000.0
      + usage.get("output_tokens", 0) * p["output"]      / 1_000_000.0
      + usage.get("cache_write", 0)   * p["cache_write"] / 1_000_000.0
      + usage.get("cache_read", 0)    * p["cache_read"]  / 1_000_000.0
    )


def empty_usage() -> Dict[str, Any]:
    return {
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_write": 0,
        "cache_read": 0,
        "messages": 0,
        "cost": 0.0,
    }


def add_usage(target: Dict[str, Any], source: Dict[str, Any]) -> None:
    for k in ("input_tokens", "output_tokens", "cache_write", "cache_read", "messages"):
        target[k] += source[k]
    target["cost"] = target.get("cost", 0.0) + source.get("cost", 0.0)


def fmt(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}m"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(n)


def fmt_full(n: int) -> str:
    return f"{n:,}"


def aggregate_group(model_usages: Dict[str, Dict[str, Any]]) -> Dict[str, Any]:
    agg: Dict[str, Any] = {
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_write": 0,
        "cache_read": 0,
        "messages": 0,
        "cost": 0.0,
    }
    for mu in model_usages.values():
        for k in ("input_tokens", "output_tokens", "cache_write", "cache_read", "messages"):
            agg[k] += mu[k]
        agg["cost"] += mu.get("cost", 0.0)
    agg["total"] = (
        agg["input_tokens"]
        + agg["output_tokens"]
        + agg["cache_write"]
        + agg["cache_read"]
    )
    return agg


# ---------------------------------------------------------------------------
# Protobuf wire reader & SQLite gen_metadata supplemental cache_write reader
# ---------------------------------------------------------------------------
def _read_varint(buf: bytes, pos: int, end: int) -> Tuple[Optional[int], int]:
    """Decode one protobuf varint from buf[pos:end]; return (None, end) on truncation."""
    result = 0
    shift = 0
    while pos < end and shift < 70:
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, pos
        shift += 7
    return None, end


def _iter_proto_fields(buf: bytes, start: int = 0, end: Optional[int] = None) -> Optional[List[Tuple[int, int, Any]]]:
    """Parse protobuf wire fields in buf[start:end]. Returns None if malformed."""
    if end is None:
        end = len(buf)
    pos = start
    fields: List[Tuple[int, int, Any]] = []
    while pos < end:
        tag, pos = _read_varint(buf, pos, end)
        if tag is None or tag == 0:
            return None
        field_num = tag >> 3
        wire_type = tag & 0x7
        if field_num <= 0:
            return None
        if wire_type == 0:
            val, pos = _read_varint(buf, pos, end)
            if val is None:
                return None
            fields.append((field_num, 0, val))
        elif wire_type == 1:
            if pos + 8 > end:
                return None
            fields.append((field_num, 1, buf[pos:pos + 8]))
            pos += 8
        elif wire_type == 2:
            length, pos = _read_varint(buf, pos, end)
            if length is None or length < 0 or pos + length > end:
                return None
            fields.append((field_num, 2, buf[pos:pos + length]))
            pos += length
        elif wire_type == 5:
            if pos + 4 > end:
                return None
            fields.append((field_num, 5, buf[pos:pos + 4]))
            pos += 4
        else:
            return None
    return fields


def _unpack_varints(buf: bytes) -> List[int]:
    """Decode a packed repeated varint byte payload into integers."""
    out: List[int] = []
    pos = 0
    end = len(buf)
    while pos < end:
        val, next_pos = _read_varint(buf, pos, end)
        if val is None or next_pos <= pos:
            break
        out.append(val)
        pos = next_pos
    return out


def _decode_printable_utf8(buf: bytes) -> str:
    """Decode length-delimited bytes to a stripped UTF-8 string if printable, else ''."""
    if not buf:
        return ""
    try:
        text = buf.decode("utf-8").strip()
    except UnicodeDecodeError:
        return ""
    if not text or not text.isprintable():
        return ""
    return text


def decode_gen_metadata_row(blob: bytes) -> Tuple[List[int], int, str]:
    """Decode `(f2_step_indices, cache_write_tokens, model_str)` from CortexStepGeneratorMetadata.

    Paths:
      - `f2` (packed varint or varint): covered transcript `step_index` values
      - `f1` (ChatModelMetadata) -> `f4` (ModelUsageStats) -> `f4` (cache_write_tokens)
      - `f1` (ChatModelMetadata) -> `f19` (model_id) / `f21` (display_label)
    """
    if not blob:
        return [], 0, ""
    outer = _iter_proto_fields(blob)
    if outer is None:
        return [], 0, ""
    step_indices: List[int] = []
    best_cw = 0
    model_id = ""
    model_label = ""
    for fnum, wtype, val in outer:
        if fnum == 2:
            if wtype == 2:
                step_indices.extend(_unpack_varints(val))
            elif wtype == 0 and isinstance(val, int) and not isinstance(val, bool):
                step_indices.append(val)
            continue
        if fnum != 1 or wtype != 2:
            continue
        chat_meta = _iter_proto_fields(val)
        if chat_meta is None:
            continue
        for fnum2, wtype2, val2 in chat_meta:
            if fnum2 == 4 and wtype2 == 2:
                usage_stats = _iter_proto_fields(val2)
                if usage_stats is None:
                    continue
                for fnum3, wtype3, val3 in usage_stats:
                    if fnum3 == 4 and wtype3 == 0 and isinstance(val3, int) and val3 > best_cw:
                        best_cw = val3
            elif fnum2 == 19 and wtype2 == 2 and not model_id:
                model_id = _decode_printable_utf8(val2)
            elif fnum2 == 21 and wtype2 == 2 and not model_label:
                model_label = _decode_printable_utf8(val2)
    return step_indices, best_cw, (model_id or model_label)


def decode_gen_metadata_cache_write(blob: bytes) -> int:
    """Decode `cache_write_tokens` from CortexStepGeneratorMetadata protobuf bytes."""
    _, best_cw, _ = decode_gen_metadata_row(blob)
    return best_cw


def _db_signature(db_path: Optional[Path]) -> List[int]:
    """Return [db_mtime_ns, db_size, wal_mtime_ns, wal_size] for cache invalidation."""
    if db_path is None:
        return [0, 0, 0, 0]
    sig = [0, 0, 0, 0]
    try:
        st = db_path.stat()
        sig[0] = st.st_mtime_ns
        sig[1] = st.st_size
    except OSError:
        return [0, 0, 0, 0]
    wal_path = db_path.with_name(db_path.name + "-wal")
    try:
        wst = wal_path.stat()
        sig[2] = wst.st_mtime_ns
        sig[3] = wst.st_size
    except OSError:
        pass
    return sig


def read_sqlite_step_metadata(db_path: Optional[Path]) -> Tuple[Dict[int, int], Dict[int, str]]:
    """Read `(step_index -> cache_write_tokens, step_index -> model_str)` from sibling DB.

    Handles the SQLite WAL read-only pitfall: opening a WAL-mode DB with `?mode=ro`
    raises SQLITE_CANTOPEN when `-wal`/`-shm` were cleaned up on exit or live in a
    read-only dir, so we fall back to `?mode=ro&immutable=1`. Never creates or
    modifies files on disk.
    """
    if db_path is None:
        return {}, {}
    try:
        if not db_path.is_file() or db_path.stat().st_size < 16:
            return {}, {}
        with open(db_path, "rb") as f:
            if f.read(16) != b"SQLite format 3\x00":
                return {}, {}
    except OSError:
        return {}, {}

    quoted = urllib.parse.quote(str(db_path.resolve()), safe="/:")
    uris = (
        f"file:{quoted}?mode=ro",
        f"file:{quoted}?mode=ro&immutable=1",
    )
    rows: Optional[List[Tuple[Any, Any]]] = None
    for uri in uris:
        conn: Optional[sqlite3.Connection] = None
        try:
            conn = sqlite3.connect(uri, uri=True, timeout=0.5)
            cur = conn.execute("SELECT idx, data FROM gen_metadata")
            rows = cur.fetchall()
            conn.close()
            conn = None
            break
        except sqlite3.Error:
            if conn is not None:
                try:
                    conn.close()
                except Exception:
                    pass
            rows = None

    if not rows:
        return {}, {}

    cw_map: Dict[int, int] = {}
    model_map: Dict[int, str] = {}
    for idx, data in rows:
        if isinstance(idx, int) and not isinstance(idx, bool) and data:
            try:
                raw_bytes = bytes(data)
            except Exception:
                continue
            f2_steps, cw, model_str = decode_gen_metadata_row(raw_bytes)
            targets = [s for s in f2_steps if isinstance(s, int) and s >= 0]
            if not targets and idx >= 0:
                targets = [idx]
            for s in targets:
                if cw > cw_map.get(s, 0):
                    cw_map[s] = cw
                if model_str and s not in model_map:
                    model_map[s] = model_str
    return cw_map, model_map


def read_sqlite_cache_writes(db_path: Optional[Path]) -> Dict[int, int]:
    """Read step_index -> cache_write_tokens from sibling conversations/<conv-id>.db."""
    cw_map, _ = read_sqlite_step_metadata(db_path)
    return cw_map


# ---------------------------------------------------------------------------
# Diagnostics & range parsing
# ---------------------------------------------------------------------------
def scan_diagnostics() -> Dict[str, Any]:
    raw = _SCAN_STATS["raw_usage_lines"]
    uniq = _SCAN_STATS["unique_messages"]
    return {
        "raw_usage_lines": raw,
        "unique_messages": uniq,
        "null_msg_id_lines": _SCAN_STATS["null_msg_id_lines"],
        "usage_upgraded_lines": _SCAN_STATS["usage_upgraded_lines"],
        "skipped_lines": _SCAN_STATS["skipped_lines"],
        "sentinel_ts_lines": _SCAN_STATS["sentinel_ts_lines"],
        "skipped_encrypted_pb": _SCAN_STATS["skipped_encrypted_pb"],
        "sqlite_supplemented_steps": _SCAN_STATS["sqlite_supplemented_steps"],
        "files_failed": _SCAN_STATS["files_failed"],
        "null_ts_lines": _SCAN_STATS["null_ts_lines"],
        "prefiltered_lines": _SCAN_STATS["prefiltered_lines"],
        "cache_hit_files": _SCAN_STATS["cache_hit_files"],
        "cache_miss_files": _SCAN_STATS["cache_miss_files"],
        "cache_pruned_files": _SCAN_STATS["cache_pruned_files"],
        "time_event_lines": _SCAN_STATS["time_event_lines"],
        "inflation_factor": round(raw / uniq, 3) if uniq else None,
    }


def pricing_source_line() -> str:
    if _PRICING_SOURCE == "litellm":
        cache_age = ""
        if PRICING_CACHE_PATH.exists():
            try:
                age_s = time.time() - PRICING_CACHE_PATH.stat().st_mtime
                if age_s < 60:
                    cache_age = "just now"
                elif age_s < 3600:
                    cache_age = f"{int(age_s / 60)}m ago"
                else:
                    cache_age = f"{int(age_s / 3600)}h ago"
            except OSError:
                cache_age = "cached"
        return f"💲 Pricing source: LiteLLM + AGY codename table ({cache_age})"
    return "💲 Pricing source: Built-in AGY API-equivalent fallback table"


def diagnostics_line() -> str:
    d = scan_diagnostics()
    if not d["unique_messages"]:
        return ""
    f = d["inflation_factor"] or 0
    cache_seg = (
        f"  cache=hit:{d['cache_hit_files']}/miss:{d['cache_miss_files']}"
        f"/pruned:{d['cache_pruned_files']}"
    ) if _CACHE_ACTIVE else ""
    extra = ""
    if d["sentinel_ts_lines"]:
        extra += f"  sentinel_ts={d['sentinel_ts_lines']}"
    if d["sqlite_supplemented_steps"]:
        extra += f"  sqlite_cw={d['sqlite_supplemented_steps']}"
    if d["skipped_lines"]:
        extra += f"  skipped_lines={d['skipped_lines']}"
    return (
        f"🔬 Scan diagnostics: raw={d['raw_usage_lines']}  unique={d['unique_messages']}"
        f"  inflation={f}x{extra}{cache_seg}"
    )


def _parse_range_date(s: str) -> datetime:
    try:
        d = datetime.fromisoformat(s)
    except ValueError:
        print(
            f"Error: invalid --range date '{s}' (expected today, week, month, "
            f"YYYY-MM-DD, or YYYY-MM-DD:YYYY-MM-DD)",
            file=sys.stderr,
        )
        sys.exit(2)
    if d.tzinfo is not None or d.time() != datetime.min.time():
        print(
            f"Error: --range date '{s}' must be a plain date (YYYY-MM-DD), "
            f"without a time component or UTC offset",
            file=sys.stderr,
        )
        sys.exit(2)
    return d


def resolve_range(spec: str) -> Tuple[datetime, datetime]:
    """Return (start_date, end_date_exclusive) as naive local midnight datetimes."""
    today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    if spec == "today":
        return today, today + timedelta(days=1)
    if spec == "week":
        monday = today - timedelta(days=today.weekday())
        return monday, today + timedelta(days=1)
    if spec == "month":
        first = today.replace(day=1)
        return first, today + timedelta(days=1)
    if ":" in spec:
        parts = spec.split(":")
        if len(parts) != 2:
            print(f"Error: invalid --range '{spec}' (expected YYYY-MM-DD:YYYY-MM-DD)", file=sys.stderr)
            sys.exit(2)
        start = _parse_range_date(parts[0])
        end = _parse_range_date(parts[1])
        if start > end:
            print(f"Error: --range start '{parts[0]}' is after end '{parts[1]}'", file=sys.stderr)
            sys.exit(2)
        return start, end + timedelta(days=1)
    d = _parse_range_date(spec)
    return d, d + timedelta(days=1)


# ---------------------------------------------------------------------------
# Surface discovery & metadata helpers
# ---------------------------------------------------------------------------
def resolve_surface_roots(data_dirs: Optional[List[Path]] = None) -> List[Tuple[str, Path, Optional[Path]]]:
    """Resolve `(surface_name, brain_dir, conversations_dir_or_None)` tuples to scan.

    When `data_dirs` is None/empty, checks `~/.gemini/{antigravity-cli,antigravity,antigravity-ide}`.
    When `data_dirs` is provided (`--data-dir`), accepts:
      - a `.gemini`-style root containing `<surface>/brain`,
      - a surface root containing `brain/` (and optional `conversations/`), or
      - a `brain` directory directly containing `<conv-id>/.system_generated/logs/transcript.jsonl`.
    """
    roots: List[Tuple[str, Path, Optional[Path]]] = []
    seen_brains: Set[str] = set()

    def _add_brain(surface_label: str, brain_dir: Path, conv_dir: Optional[Path]) -> None:
        try:
            if not brain_dir.is_dir():
                return
            real = str(brain_dir.resolve())
        except OSError:
            return
        if real in seen_brains:
            return
        seen_brains.add(real)
        valid_conv = conv_dir if (conv_dir is not None and conv_dir.is_dir()) else None
        roots.append((surface_label, brain_dir, valid_conv))

    env_override = os.environ.get("AGY_DATA_DIR")
    effective_dirs: Optional[List[Path]] = data_dirs
    if not effective_dirs and env_override:
        effective_dirs = [Path(p).expanduser() for p in env_override.split(os.pathsep) if p.strip()]

    if not effective_dirs:
        for sname in SURFACE_NAMES:
            sroot = DEFAULT_GEMINI_ROOT / sname
            _add_brain(sname, sroot / "brain", sroot / "conversations")
        return roots

    for raw_dir in effective_dirs:
        d = raw_dir.expanduser()
        if not d.exists() or not d.is_dir():
            continue
        matched_subsurface = False
        # Case 1: `.gemini`-style parent containing `<surface>/brain`
        for sname in SURFACE_NAMES:
            sub = d / sname
            if (sub / "brain").is_dir() or (sub / "conversations").is_dir():
                matched_subsurface = True
                _add_brain(sname, sub / "brain", sub / "conversations")
        if matched_subsurface:
            continue
        # Case 2: surface root containing `brain/`
        if (d / "brain").is_dir():
            _add_brain(d.name or "custom", d / "brain", d / "conversations")
            continue
        # Case 3: `brain` directory itself
        sibling_conv = d.parent / "conversations" if d.name == "brain" else None
        label = d.parent.name if d.name == "brain" and d.parent.name else (d.name or "custom")
        _add_brain(label, d, sibling_conv)

    return roots


def _load_workspace_map(data_dirs: Optional[List[Path]] = None) -> Dict[str, str]:
    """Best-effort map of conversation_id -> readable workspace name from metadata JSON."""
    candidates: List[Path] = []
    if data_dirs:
        for d in data_dirs:
            d_exp = d.expanduser()
            candidates.append(d_exp / "antigravity-cli" / "cache" / "conversation_metadata.json")
            candidates.append(d_exp / "cache" / "conversation_metadata.json")
            if d_exp.name == "brain":
                candidates.append(d_exp.parent / "cache" / "conversation_metadata.json")
    else:
        candidates.append(
            DEFAULT_GEMINI_ROOT / "antigravity-cli" / "cache" / "conversation_metadata.json"
        )

    home_str = str(Path.home())
    out: Dict[str, str] = {}
    for cpath in candidates:
        try:
            if not cpath.is_file():
                continue
            with open(cpath, "r", encoding="utf-8", errors="replace") as f:
                meta = json.load(f)
            if not isinstance(meta, dict):
                continue
            convs = meta.get("conversations") if isinstance(meta.get("conversations"), dict) else meta
            for cid, rec in convs.items():
                if not isinstance(cid, str) or not isinstance(rec, dict):
                    continue
                summary = rec.get("summary") if isinstance(rec.get("summary"), dict) else rec
                uris = summary.get("WorkspaceURIs") or summary.get("workspace_uris") or []
                if isinstance(uris, list) and uris and isinstance(uris[0], str):
                    u = uris[0]
                    if u.startswith("file://"):
                        u = urllib.parse.unquote(u[7:])
                    if u.startswith(home_str):
                        u = "~" + u[len(home_str):]
                    out[cid] = u
        except Exception:
            continue
    return out


_USER_REQ_TAG_RE = re.compile(r"</?USER_REQUEST>", re.IGNORECASE)


def _clean_user_snippet(raw: Any) -> str:
    if not isinstance(raw, str) or not raw:
        return ""
    cleaned = _USER_REQ_TAG_RE.sub("", raw).strip()
    cleaned = " ".join(cleaned.split())
    return cleaned[:60]


def _nonneg_int(val: Any) -> int:
    if isinstance(val, bool) or val is None:
        return 0
    if isinstance(val, int):
        return val if val > 0 else 0
    if isinstance(val, float):
        if not math.isfinite(val):
            return 0
        iv = int(val)
        return iv if iv > 0 else 0
    if isinstance(val, str):
        try:
            iv = int(val)
            return iv if iv > 0 else 0
        except ValueError:
            return 0
    return 0


# ---------------------------------------------------------------------------
# Core JSONL + SQLite per-file parser
# ---------------------------------------------------------------------------
def parse_file(path: Path, conv_id: str, db_path: Optional[Path] = None) -> Tuple[Dict[str, Any], bool]:
    """Parse one `<conv-id>/.system_generated/logs/transcript.jsonl` into a cache entry.

    Deduplicates `PLANNER_RESPONSE` steps by `step_index` within the conversation
    (taking per-field max across streaming/status rewrites), skips `0001-01-01`
    sentinel timestamps, optionally supplements `cache_write_tokens` from sibling
    `conversations/<conv-id>.db` `gen_metadata`, and gap-merges active-time events
    across all valid step timestamps in the conversation.
    """
    entry: Dict[str, Any] = {
        "conv_id": conv_id,
        "peek_ts": None,
        "first_msg": "",
        "first_ts": None,
        "agg": {},
        "agg_no_ts": {},
        "steps": {},
        "unindexed": [],
        "counters_by_day": {},
        "counters_no_ts": [0, 0, 0, 0],
        "skipped_lines": 0,
        "sentinel_ts_lines": 0,
        "sqlite_supplemented_steps": 0,
        "prefiltered_lines": 0,
        "null_ts_lines": 0,
        "time": [],
        "time_event_lines": 0,
    }

    db_step_cw, db_step_model = read_sqlite_step_metadata(db_path)

    events: List[int] = []
    model_events: List[Tuple[int, str]] = []
    # step_index -> [day_key, model_str, inp, out, cw, cr, no_ts_flag, sqlite_supp_flag]
    seen_steps: Dict[int, List[Any]] = {}
    first_ts_dt: Optional[datetime] = None
    last_known_model = ""
    line_no = 0
    ok = True

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line_no += 1
                if not line.strip():
                    continue
                try:
                    data = json.loads(line)
                except Exception:
                    entry["skipped_lines"] += 1
                    continue
                if not isinstance(data, dict):
                    entry["skipped_lines"] += 1
                    continue

                raw_ts = data.get("created_at")
                if raw_ts is None:
                    raw_ts = data.get("timestamp")

                if is_sentinel_timestamp(raw_ts):
                    entry["sentinel_ts_lines"] += 1
                    # Sentinel timestamps ("0001-01-01T00:00:00Z") mark uninitialized
                    # placeholder steps; skip both time-event and billing extraction.
                    continue

                ts = parse_iso_ts(raw_ts)
                ts_ev = _ts_to_epoch(ts)
                if ts_ev is not None:
                    events.append(ts_ev)
                    entry["time_event_lines"] += 1

                if line_no == 1 and ts is not None:
                    entry["peek_ts"] = ts.isoformat()

                if ts is not None and (first_ts_dt is None or ts < first_ts_dt):
                    first_ts_dt = ts
                    if entry["peek_ts"] is None:
                        entry["peek_ts"] = ts.isoformat()

                step_type = data.get("type")

                if not entry["first_msg"] and step_type == "USER_INPUT":
                    snippet = _clean_user_snippet(data.get("content"))
                    if snippet:
                        entry["first_msg"] = snippet

                if step_type != "PLANNER_RESPONSE":
                    continue

                raw_idx = data.get("step_index")
                has_idx = isinstance(raw_idx, int) and not isinstance(raw_idx, bool) and raw_idx >= 0

                model_str = str(data.get("model") or "").strip()
                if model_str and not model_str.startswith("<"):
                    last_known_model = model_str
                elif has_idx and int(raw_idx) in db_step_model:
                    model_str = db_step_model[int(raw_idx)]
                    last_known_model = model_str
                elif last_known_model:
                    model_str = last_known_model

                if ts_ev is not None and model_str and not model_str.startswith("<"):
                    model_events.append((ts_ev, classify_model(model_str)))

                inp = _nonneg_int(data.get("input_tokens"))
                out = _nonneg_int(data.get("output_tokens"))
                cr = _nonneg_int(
                    data.get("cache_read_tokens")
                    if "cache_read_tokens" in data
                    else data.get("cache_read")
                )
                cw_jsonl = _nonneg_int(
                    data.get("cache_write_tokens")
                    if "cache_write_tokens" in data
                    else data.get("cache_write")
                )

                cw = cw_jsonl
                sqlite_supp = 0
                if has_idx and raw_idx in db_step_cw:
                    db_cw = db_step_cw[raw_idx]
                    if db_cw > cw:
                        cw = db_cw
                        sqlite_supp = 1

                # Skip empty in-flight/error steps that consumed zero tokens.
                if not inp and not out and not cr and not cw:
                    continue

                if ts is not None:
                    no_ts = 0
                    day_key = ts.astimezone().strftime("%Y-%m-%d")
                    counters = entry["counters_by_day"].setdefault(day_key, [0, 0, 0, 0])
                else:
                    no_ts = 1
                    entry["null_ts_lines"] += 1
                    day_key = first_ts_dt.astimezone().strftime("%Y-%m-%d") if first_ts_dt else "unknown"
                    counters = entry["counters_no_ts"]

                counters[0] += 1  # raw_usage_lines

                if has_idx:
                    idx_int = int(raw_idx)
                    if idx_int in seen_steps:
                        prev = seen_steps[idx_int]
                        new_inp = max(prev[2], inp)
                        new_out = max(prev[3], out)
                        new_cw = max(prev[4], cw)
                        new_cr = max(prev[5], cr)
                        if (new_inp, new_out, new_cw, new_cr) != (prev[2], prev[3], prev[4], prev[5]):
                            prev[2] = new_inp
                            prev[3] = new_out
                            prev[4] = new_cw
                            prev[5] = new_cr
                            counters[3] += 1  # usage_upgraded_lines
                        if not prev[1] and model_str:
                            prev[1] = model_str
                        if sqlite_supp and not prev[7]:
                            prev[7] = 1
                        continue
                    counters[1] += 1  # unique_messages
                    seen_steps[idx_int] = [
                        day_key, model_str, inp, out, cw, cr, no_ts, sqlite_supp,
                    ]
                else:
                    counters[1] += 1  # unique_messages
                    counters[2] += 1  # null_msg_id_lines
                    entry["unindexed"].append(
                        [day_key, model_str, inp, out, cw, cr, no_ts]
                    )
                    if sqlite_supp:
                        entry["sqlite_supplemented_steps"] += 1
    except OSError:
        ok = False

    # Finalize aggregated per-day/per-model buckets and per-step map for cross-surface dedup.
    for idx_int, rec in seen_steps.items():
        day_key, model_str, inp, out, cw, cr, no_ts, sqlite_supp = rec
        if sqlite_supp:
            entry["sqlite_supplemented_steps"] += 1
        entry["steps"][str(idx_int)] = [day_key, model_str, inp, out, cw, cr, no_ts]
        target_agg = entry["agg_no_ts"] if no_ts else entry["agg"]
        bucket = target_agg.setdefault(day_key, {})
        sums = bucket.setdefault(model_str, [0, 0, 0, 0, 0])
        sums[0] += inp
        sums[1] += out
        sums[2] += cw
        sums[3] += cr
        sums[4] += 1

    for urec in entry["unindexed"]:
        day_key, model_str, inp, out, cw, cr, no_ts = urec
        target_agg = entry["agg_no_ts"] if no_ts else entry["agg"]
        bucket = target_agg.setdefault(day_key, {})
        sums = bucket.setdefault(model_str, [0, 0, 0, 0, 0])
        sums[0] += inp
        sums[1] += out
        sums[2] += cw
        sums[3] += cr
        sums[4] += 1

    entry["first_ts"] = first_ts_dt.isoformat() if first_ts_dt else None

    if events:
        events.sort()
        merged = _gap_merge([(t, t) for t in events], _GAP_MINUTES * 60)
        counts: List[Dict[str, int]] = [{} for _ in merged]
        model_events.sort()
        mi = 0
        for ep, cls in model_events:
            while merged[mi][1] < ep:
                mi += 1
            counts[mi][cls] = counts[mi].get(cls, 0) + 1
        entry["time"] = [[a, b, counts[i]] for i, (a, b) in enumerate(merged)]

    return entry, ok


def _merge_single_entry(
    sessions: Dict[str, Dict[str, Any]],
    finfo: Dict[str, Any],
    entry: Dict[str, Any],
    start_str: str,
    end_str: str,
) -> None:
    """Fast-path merge when `conv_id` appears in only one surface."""
    sid = finfo["conv_id"]
    if sid not in sessions:
        sessions[sid] = {
            "surface": finfo["surface"],
            "project": finfo["project"],
            "first_msg": "",
            "first_ts": None,
            "models": defaultdict(empty_usage),
            "daily_models": defaultdict(lambda: defaultdict(empty_usage)),
        }
    sdata = sessions[sid]

    if not sdata["first_msg"] and entry["first_msg"]:
        sdata["first_msg"] = entry["first_msg"]

    if entry["first_ts"]:
        try:
            etd = datetime.fromisoformat(entry["first_ts"])
            if sdata["first_ts"] is None or etd < sdata["first_ts"]:
                sdata["first_ts"] = etd
        except Exception:
            pass

    def _add_day(day_key: str, models: Dict[str, List[int]]) -> None:
        daily = sdata["daily_models"][day_key]
        for model_str, s in models.items():
            cls = classify_model(model_str)
            cost = cost_for_message(
                {
                    "input_tokens": s[0],
                    "output_tokens": s[1],
                    "cache_write": s[2],
                    "cache_read": s[3],
                },
                model_str,
            )
            for tgt in (sdata["models"][cls], daily[cls]):
                tgt["input_tokens"] += s[0]
                tgt["output_tokens"] += s[1]
                tgt["cache_write"] += s[2]
                tgt["cache_read"] += s[3]
                tgt["messages"] += s[4]
                tgt["cost"] += cost

    for day_key, models in entry["agg"].items():
        if start_str <= day_key < end_str:
            _add_day(day_key, models)
    for day_key, models in entry["agg_no_ts"].items():
        if day_key != "unknown" and start_str <= day_key < end_str:
            _add_day(day_key, models)
        elif day_key == "unknown":
            _add_day(day_key, models)

    for day_key, c in entry["counters_by_day"].items():
        if start_str <= day_key < end_str:
            _SCAN_STATS["raw_usage_lines"] += c[0]
            _SCAN_STATS["unique_messages"] += c[1]
            _SCAN_STATS["null_msg_id_lines"] += c[2]
            _SCAN_STATS["usage_upgraded_lines"] += c[3]
    c_no = entry["counters_no_ts"]
    _SCAN_STATS["raw_usage_lines"] += c_no[0]
    _SCAN_STATS["unique_messages"] += c_no[1]
    _SCAN_STATS["null_msg_id_lines"] += c_no[2]
    _SCAN_STATS["usage_upgraded_lines"] += c_no[3]

    _SCAN_STATS["skipped_lines"] += entry["skipped_lines"]
    _SCAN_STATS["sentinel_ts_lines"] += entry["sentinel_ts_lines"]
    _SCAN_STATS["sqlite_supplemented_steps"] += entry["sqlite_supplemented_steps"]
    _SCAN_STATS["prefiltered_lines"] += entry["prefiltered_lines"]
    _SCAN_STATS["null_ts_lines"] += entry["null_ts_lines"]
    _SCAN_STATS["time_event_lines"] += entry["time_event_lines"]


def _merge_multi_surface_conv(
    sessions: Dict[str, Dict[str, Any]],
    items: List[Tuple[Dict[str, Any], Dict[str, Any]]],
    start_str: str,
    end_str: str,
) -> None:
    """Deduplicate `(conversation_id, step_index)` across multiple surface files."""
    first_finfo = items[0][0]
    sid = first_finfo["conv_id"]
    sessions[sid] = {
        "surface": first_finfo["surface"],
        "project": first_finfo["project"],
        "first_msg": "",
        "first_ts": None,
        "models": defaultdict(empty_usage),
        "daily_models": defaultdict(lambda: defaultdict(empty_usage)),
    }
    sdata = sessions[sid]

    merged_steps: Dict[str, List[Any]] = {}
    unindexed_all: List[List[Any]] = []
    raw_in_range = 0
    upgraded_in_range = 0
    null_id_in_range = 0

    for _finfo, entry in items:
        if not sdata["first_msg"] and entry["first_msg"]:
            sdata["first_msg"] = entry["first_msg"]
        if entry["first_ts"]:
            try:
                etd = datetime.fromisoformat(entry["first_ts"])
                if sdata["first_ts"] is None or etd < sdata["first_ts"]:
                    sdata["first_ts"] = etd
            except Exception:
                pass

        for day_key, c in entry["counters_by_day"].items():
            if start_str <= day_key < end_str:
                raw_in_range += c[0]
                null_id_in_range += c[2]
                upgraded_in_range += c[3]
        c_no = entry["counters_no_ts"]
        raw_in_range += c_no[0]
        null_id_in_range += c_no[2]
        upgraded_in_range += c_no[3]

        _SCAN_STATS["skipped_lines"] += entry["skipped_lines"]
        _SCAN_STATS["sentinel_ts_lines"] += entry["sentinel_ts_lines"]
        _SCAN_STATS["sqlite_supplemented_steps"] += entry["sqlite_supplemented_steps"]
        _SCAN_STATS["prefiltered_lines"] += entry["prefiltered_lines"]
        _SCAN_STATS["null_ts_lines"] += entry["null_ts_lines"]
        _SCAN_STATS["time_event_lines"] += entry["time_event_lines"]

        for sidx, srec in entry["steps"].items():
            if sidx not in merged_steps:
                merged_steps[sidx] = list(srec)
            else:
                prev = merged_steps[sidx]
                new_vals = [
                    max(prev[2], srec[2]),
                    max(prev[3], srec[3]),
                    max(prev[4], srec[4]),
                    max(prev[5], srec[5]),
                ]
                if new_vals != prev[2:6]:
                    prev[2:6] = new_vals
                    if start_str <= prev[0] < end_str or prev[6]:
                        upgraded_in_range += 1
                if not prev[1] and srec[1]:
                    prev[1] = srec[1]
        unindexed_all.extend(entry["unindexed"])

    agg_merged: Dict[str, Dict[str, List[int]]] = {}
    uniq_in_range = 0
    for srec in list(merged_steps.values()) + unindexed_all:
        day_key, model_str, inp, out, cw, cr, no_ts = srec
        in_range = (start_str <= day_key < end_str) or (no_ts and day_key == "unknown")
        if not in_range:
            continue
        uniq_in_range += 1
        bucket = agg_merged.setdefault(day_key, {})
        sums = bucket.setdefault(model_str, [0, 0, 0, 0, 0])
        sums[0] += inp
        sums[1] += out
        sums[2] += cw
        sums[3] += cr
        sums[4] += 1

    for day_key, models in agg_merged.items():
        daily = sdata["daily_models"][day_key]
        for model_str, s in models.items():
            cls = classify_model(model_str)
            cost = cost_for_message(
                {
                    "input_tokens": s[0],
                    "output_tokens": s[1],
                    "cache_write": s[2],
                    "cache_read": s[3],
                },
                model_str,
            )
            for tgt in (sdata["models"][cls], daily[cls]):
                tgt["input_tokens"] += s[0]
                tgt["output_tokens"] += s[1]
                tgt["cache_write"] += s[2]
                tgt["cache_read"] += s[3]
                tgt["messages"] += s[4]
                tgt["cost"] += cost

    _SCAN_STATS["raw_usage_lines"] += raw_in_range
    _SCAN_STATS["unique_messages"] += uniq_in_range
    _SCAN_STATS["null_msg_id_lines"] += null_id_in_range
    _SCAN_STATS["usage_upgraded_lines"] += upgraded_in_range


def _build_time_days(
    time_triples: List[Tuple[int, int, Dict[str, int]]],
    start_str: str,
    end_str: str,
) -> Dict[str, Dict[str, Any]]:
    """Cross-conversation union merge of active-time intervals in UTC epoch domain."""
    days: Dict[str, Dict[str, Any]] = {}
    cur = datetime.strptime(start_str, "%Y-%m-%d")
    end = datetime.strptime(end_str, "%Y-%m-%d")
    while cur < end:
        days[cur.strftime("%Y-%m-%d")] = {"intervals": [], "total_seconds": 0}
        cur += timedelta(days=1)

    if time_triples:
        gap = _GAP_MINUTES * 60
        merged: List[List[Any]] = []
        for a, b, c in sorted(time_triples, key=lambda t: (t[0], t[1])):
            if merged and a - merged[-1][1] <= gap:
                if b > merged[-1][1]:
                    merged[-1][1] = b
                for cls, n in c.items():
                    merged[-1][2][cls] = merged[-1][2].get(cls, 0) + n
            else:
                merged.append([a, b, dict(c)])

        day_pieces: Dict[str, List[List[Any]]] = {}
        for s_ep, e_ep, cnt in merged:
            model = _dominant_model(cnt)
            a_dt = datetime.fromtimestamp(s_ep, timezone.utc)
            b_dt = datetime.fromtimestamp(e_ep, timezone.utc)
            for day_key, s, e in _split_interval_by_local_day(a_dt, b_dt):
                if day_key in days:
                    day_pieces.setdefault(day_key, []).append([s, e, model])

        for day_key, pieces in day_pieces.items():
            pieces.sort(key=lambda p: (p[0], p[1]))
            union: List[List[Any]] = []
            for s, e, mdl in pieces:
                if union and s <= union[-1][1]:
                    if e > union[-1][1]:
                        union[-1][1] = e
                    if union[-1][2] is None:
                        union[-1][2] = mdl
                else:
                    union.append([s, e, mdl])
            rec = days[day_key]
            rec["intervals"] = union
            rec["total_seconds"] = sum(e - s for s, e, _ in union)

    return days


def scan_sessions(
    start_dt: datetime,
    end_dt: datetime,
    project_filter: Optional[str] = None,
    use_cache: bool = True,
    data_dirs: Optional[List[Path]] = None,
    load_workspaces: bool = False,
) -> Tuple[Dict[str, Dict[str, Any]], Dict[str, Dict[str, Any]]]:
    """Scan all Antigravity surfaces; return `(sessions, time_days)`."""
    global _CACHE_ACTIVE

    start_epoch = start_dt.timestamp()
    end_epoch = end_dt.timestamp()

    for k in _SCAN_STATS:
        _SCAN_STATS[k] = 0

    midnight = datetime.min.time()
    use_cache = (
        use_cache
        and start_dt.tzinfo is None
        and end_dt.tzinfo is None
        and start_dt.time() == midnight
        and end_dt.time() == midnight
    )
    _CACHE_ACTIVE = use_cache

    start_str = start_dt.strftime("%Y-%m-%d")
    end_str = end_dt.strftime("%Y-%m-%d")
    end_utc = end_dt.astimezone(timezone.utc)

    cache_files = _load_scan_cache() if use_cache else {}
    cache_dirty = False

    surfaces = resolve_surface_roots(data_dirs)
    workspace_map = _load_workspace_map(data_dirs) if (load_workspaces or project_filter) else {}

    all_files: List[Dict[str, Any]] = []
    seen_paths: Set[str] = set()

    for surface_name, brain_dir, conv_root in surfaces:
        transcript_convs_in_surface: Set[str] = set()
        try:
            conv_dirs = sorted(brain_dir.iterdir(), key=lambda p: p.name)
        except OSError:
            continue

        for conv_dir in conv_dirs:
            try:
                if not conv_dir.is_dir():
                    continue
            except OSError:
                continue
            conv_id = conv_dir.name
            # Exact transcript path — intentionally skips `.system_generated/logs/chunks/`
            # and `transcript_full.jsonl` so chunks/mirrors are never double-counted.
            tpath = conv_dir / ".system_generated" / "logs" / "transcript.jsonl"
            try:
                if not tpath.is_file():
                    continue
                st = tpath.stat()
            except OSError:
                continue
            if st.st_size == 0:
                continue

            transcript_convs_in_surface.add(conv_id)
            path_str = str(tpath)
            seen_paths.add(path_str)

            project_label = workspace_map.get(conv_id, surface_name)
            if project_filter and (
                project_filter.lower() not in project_label.lower()
                and project_filter.lower() not in surface_name.lower()
                and project_filter.lower() not in conv_id.lower()
            ):
                continue

            if st.st_mtime < start_epoch:
                continue

            db_path: Optional[Path] = None
            if conv_root is not None:
                cand_db = conv_root / f"{conv_id}.db"
                if cand_db.is_file():
                    db_path = cand_db
            db_sig = _db_signature(db_path)

            cache_entry = None
            if use_cache:
                ce = cache_files.get(path_str)
                if (
                    ce is not None
                    and ce["mtime_ns"] == st.st_mtime_ns
                    and ce["size"] == st.st_size
                    and ce["db_sig"] == db_sig
                ):
                    cache_entry = ce

            birthtime = getattr(st, "st_birthtime", None)
            if birthtime is None or birthtime > end_epoch:
                if cache_entry is not None:
                    try:
                        ref_iso = cache_entry.get("first_ts") or cache_entry.get("peek_ts")
                        if ref_iso:
                            first_ts = datetime.fromisoformat(ref_iso)
                            if first_ts >= end_utc:
                                continue
                    except Exception:
                        pass
                else:
                    try:
                        with open(tpath, "r", encoding="utf-8", errors="replace") as pf:
                            first_obj = json.loads(pf.readline())
                        if isinstance(first_obj, dict):
                            raw_peek = first_obj.get("created_at") or first_obj.get("timestamp")
                            first_ts = parse_iso_ts(raw_peek)
                            if first_ts is not None and first_ts >= end_utc:
                                continue
                    except Exception:
                        pass

            all_files.append({
                "path": tpath,
                "conv_id": conv_id,
                "surface": surface_name,
                "project": project_label,
                "db_path": db_path,
                "db_sig": db_sig,
                "mtime_ns": st.st_mtime_ns,
                "size": st.st_size,
                "cache_entry": cache_entry,
            })

        # Count legacy encrypted `.pb` conversation blobs that have no transcript.jsonl
        # without ever trying to parse them as protobuf.
        if conv_root is not None:
            try:
                for pb in conv_root.glob("*.pb"):
                    if pb.stem not in transcript_convs_in_surface:
                        _SCAN_STATS["skipped_encrypted_pb"] += 1
            except OSError:
                pass

    parsed_by_conv: Dict[str, List[Tuple[Dict[str, Any], Dict[str, Any]]]] = defaultdict(list)
    time_triples: List[Tuple[int, int, Dict[str, int]]] = []

    for finfo in all_files:
        entry = finfo["cache_entry"]
        if entry is not None:
            _SCAN_STATS["cache_hit_files"] += 1
        else:
            entry, parse_ok = parse_file(finfo["path"], finfo["conv_id"], finfo["db_path"])
            if use_cache:
                _SCAN_STATS["cache_miss_files"] += 1
            if not parse_ok:
                _SCAN_STATS["files_failed"] += 1
            elif use_cache:
                entry["mtime_ns"] = finfo["mtime_ns"]
                entry["size"] = finfo["size"]
                entry["db_sig"] = finfo["db_sig"]
                cache_files[str(finfo["path"])] = entry
                cache_dirty = True

        parsed_by_conv[finfo["conv_id"]].append((finfo, entry))

    if use_cache:
        # Prune only entries under the scanned root prefixes (or all entries on default
        # scan) so `--data-dir /tmp/...` never wipes production `~/.gemini` cache entries.
        if data_dirs is not None:
            scoped_prefixes = tuple(
                str(r).rstrip(os.sep) + os.sep
                for _name, brain_dir, conv_root in surfaces
                for r in (brain_dir, conv_root)
                if r is not None
            )
            stale = [
                k for k in cache_files
                if k not in seen_paths and (not scoped_prefixes or k.startswith(scoped_prefixes))
            ]
        else:
            stale = [k for k in cache_files if k not in seen_paths]
        for k in stale:
            del cache_files[k]
        if stale:
            _SCAN_STATS["cache_pruned_files"] = len(stale)
            cache_dirty = True
        if cache_dirty:
            _write_scan_cache(cache_files)

    sessions: Dict[str, Dict[str, Any]] = {}
    for _conv_id, items in parsed_by_conv.items():
        if len(items) == 1:
            _merge_single_entry(sessions, items[0][0], items[0][1], start_str, end_str)
            for s, e, c in items[0][1]["time"]:
                time_triples.append((s, e, c))
        else:
            _merge_multi_surface_conv(sessions, items, start_str, end_str)
            # Deduplicate mirrored conversation intervals so a mirrored surface copy
            # does not double-weight model counts during dominant-model selection.
            conv_raw_ivs: List[Tuple[int, int, Dict[str, int]]] = []
            for _finfo, ent in items:
                for s, e, c in ent["time"]:
                    conv_raw_ivs.append((s, e, c))
            if conv_raw_ivs:
                gap = _GAP_MINUTES * 60
                c_merged: List[List[Any]] = []
                for a, b, c in sorted(conv_raw_ivs, key=lambda t: (t[0], t[1])):
                    if c_merged and a - c_merged[-1][1] <= gap:
                        if b > c_merged[-1][1]:
                            c_merged[-1][1] = b
                        for cls, n in c.items():
                            if n > c_merged[-1][2].get(cls, 0):
                                c_merged[-1][2][cls] = n
                    else:
                        c_merged.append([a, b, dict(c)])
                for a, b, c in c_merged:
                    time_triples.append((a, b, c))

    time_days = _build_time_days(time_triples, start_str, end_str)

    filtered_sessions = {
        sid: s
        for sid, s in sessions.items()
        if any(u["messages"] > 0 for u in s["models"].values())
    }
    return filtered_sessions, time_days


# ---------------------------------------------------------------------------
# Output formatters
# ---------------------------------------------------------------------------
def build_json_payload(
    sessions: Dict[str, Dict[str, Any]],
    include_sessions: bool = True,
    time_days: Optional[Dict[str, Dict[str, Any]]] = None,
) -> Dict[str, Any]:
    """Build the structured `--json` response dictionary."""
    result: Dict[str, Any] = {
        "script_version": __version__,
        "pricing_source": _PRICING_SOURCE,
        "model_pricing": {mc: dict(p) for mc, p in MODEL_PRICING.items()},
        "sessions": [],
        "totals_by_model": {},
        "grand_total_cost": 0.0,
    }
    grand_by_model: Dict[str, Dict[str, Any]] = defaultdict(empty_usage)

    for sid, sdata in sessions.items():
        if not include_sessions:
            for mc, mu in sdata["models"].items():
                add_usage(grand_by_model[mc], mu)
            continue
        s_entry: Dict[str, Any] = {
            "session_id": sid,
            "surface": sdata.get("surface", ""),
            "project": sdata["project"],
            "first_message": sdata["first_msg"],
            "timestamp": sdata["first_ts"].isoformat() if sdata["first_ts"] else None,
            "models": {},
            "total_cost": 0.0,
        }
        for mc in MODEL_CLASSES:
            if mc not in sdata["models"]:
                continue
            mu = sdata["models"][mc]
            c = mu["cost"]
            s_entry["models"][mc] = {**mu, "cost": round(c, 4)}
            s_entry["total_cost"] += c
            add_usage(grand_by_model[mc], mu)
        s_entry["total_cost"] = round(s_entry["total_cost"], 4)
        result["sessions"].append(s_entry)

    total_cost = 0.0
    for mc in MODEL_CLASSES:
        if mc not in grand_by_model:
            continue
        mu = grand_by_model[mc]
        c = mu["cost"]
        total_cost += c
        result["totals_by_model"][mc] = {**mu, "cost": round(c, 4)}
    result["grand_total_cost"] = round(total_cost, 4)

    days: Dict[str, Dict[str, Dict[str, Any]]] = defaultdict(lambda: defaultdict(empty_usage))
    for _sid, sdata in sessions.items():
        for day_key, day_models in sdata.get("daily_models", {}).items():
            for mc, mu in day_models.items():
                add_usage(days[day_key][mc], mu)

    result["daily_breakdown"] = {}
    for day_key in sorted(days.keys()):
        day_entry: Dict[str, Any] = {"models": {}, "total_cost": 0.0}
        for mc in MODEL_CLASSES:
            if mc not in days[day_key]:
                continue
            mu = days[day_key][mc]
            c = mu["cost"]
            day_entry["models"][mc] = {**mu, "cost": round(c, 4)}
            day_entry["total_cost"] += c
        day_entry["total_cost"] = round(day_entry["total_cost"], 4)
        result["daily_breakdown"][day_key] = day_entry

    if time_days is not None:
        result["time"] = {"gap_minutes": _GAP_MINUTES, "days": time_days}

    result["diagnostics"] = scan_diagnostics()

    if not include_sessions:
        del result["sessions"]

    return _sanitize_json_value(result)


def print_json(
    sessions: Dict[str, Dict[str, Any]],
    include_sessions: bool = True,
    time_days: Optional[Dict[str, Dict[str, Any]]] = None,
) -> None:
    payload = _sanitize_json_value(
        build_json_payload(
            sessions,
            include_sessions=include_sessions,
            time_days=time_days,
        )
    )
    print(json.dumps(payload, indent=2, ensure_ascii=False, default=str, allow_nan=False))


def print_detail(sessions: Dict[str, Dict[str, Any]], range_label: str) -> None:
    sorted_sessions = sorted(sessions.items(), key=lambda x: str(x[1].get("first_ts") or ""))
    print("=" * 115)
    print(f"📊 Google Antigravity Token Usage — {range_label}")
    print("=" * 115)

    grand_by_model: Dict[str, Dict[str, Any]] = defaultdict(empty_usage)
    for sid, sdata in sorted_sessions:
        session_cost = sum(u["cost"] for u in sdata["models"].values())
        date_str = sdata["first_ts"].strftime("%m/%d %H:%M") if sdata["first_ts"] else "N/A"
        first_msg = sdata["first_msg"] or "-"
        print(f"\n🔹 {date_str}  {sdata['project']}/{sid[:8]}  💰${session_cost:.2f}")
        print(f"   「{first_msg}」")
        for mc in MODEL_CLASSES:
            if mc not in sdata["models"]:
                continue
            mu = sdata["models"][mc]
            c = mu["cost"]
            add_usage(grand_by_model[mc], mu)
            print(
                f"   {EMOJI[mc]} {mc:<9} steps:{mu['messages']:>4}  "
                f"in:{fmt(mu['input_tokens']):>8}  out:{fmt(mu['output_tokens']):>8}  "
                f"cache_r:{fmt(mu['cache_read']):>8}  cache_w:{fmt(mu['cache_write']):>8}  "
                f"${c:.2f}"
            )

    print("\n" + "=" * 115)
    print("📋 Totals by Model Class")
    print("=" * 115)

    total_tokens = 0
    total_cost = 0.0
    for mc in MODEL_CLASSES:
        if mc not in grand_by_model:
            continue
        mu = grand_by_model[mc]
        c = mu["cost"]
        total_cost += c
        p = MODEL_PRICING.get(mc)
        price_note = (
            f"(Input ${p['input']}/M, Output ${p['output']}/M, CacheR ${p['cache_read']}/M)"
            if p else "(Per-model API-equivalent rate)"
        )
        total_tokens += (
            mu["input_tokens"] + mu["output_tokens"] + mu["cache_write"] + mu["cache_read"]
        )
        print(
            f"\n{EMOJI[mc]} {mc.upper()}  {price_note}\n"
            f"   Steps:          {fmt_full(mu['messages'])}\n"
            f"   Input:          {fmt_full(mu['input_tokens'])}\n"
            f"   Output:         {fmt_full(mu['output_tokens'])}\n"
            f"   Cache Write:    {fmt_full(mu['cache_write'])}\n"
            f"   Cache Read:     {fmt_full(mu['cache_read'])}\n"
            f"   Est. Cost:      ${c:.2f}"
        )

    print(
        f"\n{'=' * 115}\n"
        f"🔢 Total Tokens (incl. cache): {fmt_full(total_tokens)}\n"
        f"💰 API-Equivalent Cost Est.:   ${total_cost:.2f}\n"
        f"{'=' * 115}"
    )
    print(pricing_source_line())
    dline = diagnostics_line()
    if dline:
        print(dline)
    print("⚠️  Costs are API-equivalent estimates; Antigravity plans bill via quota windows & AI Credits.")


def print_by_project(sessions: Dict[str, Dict[str, Any]], range_label: str) -> None:
    projects: Dict[str, Dict[str, Dict[str, Any]]] = defaultdict(lambda: defaultdict(empty_usage))
    for _sid, sdata in sessions.items():
        proj = sdata["project"]
        for mc, mu in sdata["models"].items():
            add_usage(projects[proj][mc], mu)

    print("=" * 100)
    print(f"📊 Antigravity Usage by Workspace/Surface — {range_label}")
    print("=" * 100)

    grand_cost = 0.0
    grand_agg = {
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_write": 0,
        "cache_read": 0,
        "messages": 0,
        "total": 0,
    }
    for proj in sorted(projects.keys()):
        proj_cost = sum(u["cost"] for u in projects[proj].values())
        agg = aggregate_group(projects[proj])
        grand_cost += proj_cost
        for k in grand_agg:
            grand_agg[k] += agg[k]
        print(f"\n📁 {proj}  💰${proj_cost:.2f}")
        print(
            f"   steps:{agg['messages']}  in:{fmt(agg['input_tokens'])}  "
            f"out:{fmt(agg['output_tokens'])}  cache_r:{fmt(agg['cache_read'])}  "
            f"cache_w:{fmt(agg['cache_write'])}  total:{fmt(agg['total'])}"
        )
        for mc in MODEL_CLASSES:
            if mc not in projects[proj]:
                continue
            mu = projects[proj][mc]
            print(
                f"   {EMOJI[mc]} {mc:<9} steps:{mu['messages']:>4}  "
                f"in:{fmt(mu['input_tokens']):>8}  out:{fmt(mu['output_tokens']):>8}  "
                f"cache_r:{fmt(mu['cache_read']):>8}  cache_w:{fmt(mu['cache_write']):>8}  "
                f"${mu['cost']:.2f}"
            )
    print(f"\n{'=' * 100}")
    print(
        f"📋 Total: steps:{fmt_full(grand_agg['messages'])}  "
        f"in:{fmt(grand_agg['input_tokens'])}  out:{fmt(grand_agg['output_tokens'])}  "
        f"cache_r:{fmt(grand_agg['cache_read'])}  cache_w:{fmt(grand_agg['cache_write'])}  "
        f"total:{fmt(grand_agg['total'])}"
    )
    print(f"💰 API-Equivalent Total: ${grand_cost:.2f}")
    print(pricing_source_line())
    dline = diagnostics_line()
    if dline:
        print(dline)


def print_by_day(sessions: Dict[str, Dict[str, Any]], range_label: str) -> None:
    days: Dict[str, Dict[str, Dict[str, Any]]] = defaultdict(lambda: defaultdict(empty_usage))
    for _sid, sdata in sessions.items():
        for day_key, day_models in sdata.get("daily_models", {}).items():
            for mc, mu in day_models.items():
                add_usage(days[day_key][mc], mu)

    print("=" * 100)
    print(f"📊 Antigravity Daily Usage — {range_label}")
    print("=" * 100)

    grand_cost = 0.0
    grand_agg = {
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_write": 0,
        "cache_read": 0,
        "messages": 0,
        "total": 0,
    }
    for day in sorted(days.keys()):
        day_cost = sum(u["cost"] for u in days[day].values())
        agg = aggregate_group(days[day])
        grand_cost += day_cost
        for k in grand_agg:
            grand_agg[k] += agg[k]
        print(f"\n📅 {day}  💰${day_cost:.2f}")
        print(
            f"   steps:{agg['messages']}  in:{fmt(agg['input_tokens'])}  "
            f"out:{fmt(agg['output_tokens'])}  cache_r:{fmt(agg['cache_read'])}  "
            f"cache_w:{fmt(agg['cache_write'])}  total:{fmt(agg['total'])}"
        )
        for mc in MODEL_CLASSES:
            if mc not in days[day]:
                continue
            mu = days[day][mc]
            print(
                f"   {EMOJI[mc]} {mc:<9} steps:{mu['messages']:>4}  "
                f"in:{fmt(mu['input_tokens']):>8}  out:{fmt(mu['output_tokens']):>8}  "
                f"cache_r:{fmt(mu['cache_read']):>8}  cache_w:{fmt(mu['cache_write']):>8}  "
                f"${mu['cost']:.2f}"
            )
    print(f"\n{'=' * 100}")
    print(
        f"📋 Total: steps:{fmt_full(grand_agg['messages'])}  "
        f"in:{fmt(grand_agg['input_tokens'])}  out:{fmt(grand_agg['output_tokens'])}  "
        f"cache_r:{fmt(grand_agg['cache_read'])}  cache_w:{fmt(grand_agg['cache_write'])}  "
        f"total:{fmt(grand_agg['total'])}"
    )
    print(f"💰 API-Equivalent Total: ${grand_cost:.2f}")
    print(pricing_source_line())
    dline = diagnostics_line()
    if dline:
        print(dline)


# ---------------------------------------------------------------------------
# CLI entrypoint
# ---------------------------------------------------------------------------
def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Analyze Google Antigravity token usage")
    parser.add_argument(
        "--range",
        default="week",
        help="Time range: today, week, month, YYYY-MM-DD, or YYYY-MM-DD:YYYY-MM-DD",
    )
    parser.add_argument(
        "--data-dir",
        action="append",
        default=None,
        help="Override ~/.gemini root or brain directory (repeatable, for testing)",
    )
    parser.add_argument(
        "--cache-dir",
        default=None,
        help="Override ~/Library/Caches/AGYMonitor cache directory",
    )
    parser.add_argument("--project", default=None, help="Filter by workspace/surface keyword")
    parser.add_argument("--by-project", action="store_true", help="Group text results by project")
    parser.add_argument("--by-day", action="store_true", help="Group text results by day")
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument(
        "--no-sessions",
        action="store_true",
        help="With --json: omit the per-session array from the output",
    )
    parser.add_argument(
        "--no-cache",
        action="store_true",
        help="Bypass the incremental scan cache entirely (no read, no write)",
    )
    parser.add_argument(
        "--offline",
        action="store_true",
        help="Skip remote LiteLLM fetch and use cached or offline fallback pricing",
    )
    parser.add_argument(
        "--gap-minutes",
        type=int,
        default=DEFAULT_GAP_MINUTES,
        help=f"Active-time sessionization gap in minutes (default {DEFAULT_GAP_MINUTES})",
    )
    parser.add_argument(
        "--time-year",
        type=int,
        default=None,
        metavar="YYYY",
        help="Emit per-day active-time totals for the whole year as JSON and exit",
    )
    args = parser.parse_args(argv)

    if args.gap_minutes < 1:
        print(f"Error: --gap-minutes must be >= 1 (got {args.gap_minutes})", file=sys.stderr)
        sys.exit(2)

    global _GAP_MINUTES
    _GAP_MINUTES = args.gap_minutes

    _init_cache_dir_from_env_or_arg(args.cache_dir)
    data_dirs = [Path(p) for p in args.data_dir] if args.data_dir else None

    if args.time_year is not None:
        if not (1970 <= args.time_year <= 9998):
            print(
                f"Error: --time-year must be within 1970-9998 (got {args.time_year})",
                file=sys.stderr,
            )
            sys.exit(2)
        y = args.time_year
        _sessions, time_days = scan_sessions(
            datetime(y, 1, 1),
            datetime(y + 1, 1, 1),
            project_filter=args.project,
            use_cache=not args.no_cache,
            data_dirs=data_dirs,
            load_workspaces=False,
        )
        out = _sanitize_json_value({
            "script_version": __version__,
            "year": y,
            "gap_minutes": _GAP_MINUTES,
            "days": {day: rec["total_seconds"] for day, rec in time_days.items()},
        })
        print(json.dumps(out, indent=2, ensure_ascii=False, allow_nan=False))
        return 0

    load_pricing(offline=args.offline)

    start_dt, end_dt = resolve_range(args.range)
    range_label = (
        f"{start_dt.strftime('%Y/%m/%d')} ~ "
        f"{(end_dt - timedelta(days=1)).strftime('%Y/%m/%d')}"
    )

    need_workspaces = (not args.json) or (not args.no_sessions) or bool(args.project)
    sessions, time_days = scan_sessions(
        start_dt,
        end_dt,
        project_filter=args.project,
        use_cache=not args.no_cache,
        data_dirs=data_dirs,
        load_workspaces=need_workspaces,
    )

    if not sessions:
        if args.json:
            print_json({}, include_sessions=not args.no_sessions, time_days=time_days)
            return 0
        print(f"No Antigravity sessions found for range: {range_label}")
        if args.project:
            print(f"  (with project filter: {args.project})")
        return 0

    if args.json:
        print_json(
            sessions,
            include_sessions=not args.no_sessions,
            time_days=time_days,
        )
    elif args.by_project:
        print_by_project(sessions, range_label)
    elif args.by_day:
        print_by_day(sessions, range_label)
    else:
        print_detail(sessions, range_label)

    return 0


if __name__ == "__main__":
    sys.exit(main())
