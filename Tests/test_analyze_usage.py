#!/usr/bin/env python3
"""Comprehensive unit tests for Resources/analyze_usage.py (Python 3.9+ compatible)."""
from __future__ import annotations

import ast
from datetime import datetime, timedelta
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any, Dict, List
import unittest
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = REPO_ROOT / "Resources" / "analyze_usage.py"


def _load_module() -> Any:
    spec = importlib.util.spec_from_file_location("analyze_usage", str(SCRIPT_PATH))
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


au = _load_module()


def _encode_varint(val: int) -> bytes:
    out = bytearray()
    v = val
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            break
    return bytes(out)


def _encode_len_field(field_num: int, payload: bytes) -> bytes:
    tag = (field_num << 3) | 2
    return _encode_varint(tag) + _encode_varint(len(payload)) + payload


def _encode_varint_field(field_num: int, val: int) -> bytes:
    tag = (field_num << 3) | 0
    return _encode_varint(tag) + _encode_varint(val)


def _build_gen_metadata_blob(
    inp: int = 1000,
    out: int = 200,
    cache_write: int = 4000,
    cache_read: int = 500,
) -> bytes:
    """Build CortexStepGeneratorMetadata(f1=ChatModelMetadata(f4=ModelUsageStats(...)))."""
    usage_stats = (
        _encode_varint_field(2, inp)
        + _encode_varint_field(3, out)
        + _encode_varint_field(4, cache_write)
        + _encode_varint_field(5, cache_read)
    )
    chat_meta = _encode_len_field(4, usage_stats) + _encode_len_field(19, b"gemini-4-carbon")
    return _encode_len_field(1, chat_meta)


def _write_transcript(
    gemini_root: Path,
    surface: str,
    conv_id: str,
    lines: List[Any],
) -> Path:
    tpath = gemini_root / surface / "brain" / conv_id / ".system_generated" / "logs" / "transcript.jsonl"
    tpath.parent.mkdir(parents=True, exist_ok=True)
    with open(tpath, "w", encoding="utf-8") as f:
        for item in lines:
            if isinstance(item, str):
                f.write(item + "\n")
            else:
                f.write(json.dumps(item) + "\n")
    return tpath


class TestPython39CompatibilityAndMeta(unittest.TestCase):
    def test_python39_syntax_and_version(self) -> None:
        src = SCRIPT_PATH.read_text(encoding="utf-8")
        tree = ast.parse(src, filename=str(SCRIPT_PATH))
        self.assertEqual(au.__version__, "1.0.2")

        has_future_annotations = False
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom) and node.module == "__future__":
                if any(alias.name == "annotations" for alias in node.names):
                    has_future_annotations = True
            # Guard against Python 3.10+ match/case syntax even if run on newer Python
            self.assertNotEqual(type(node).__name__, "Match")
        self.assertTrue(has_future_annotations)


class TestModelClassification(unittest.TestCase):
    def test_exact_classify_rules_from_spec(self) -> None:
        cases = {
            # Hydrogen
            "gemini-4-hydrogen-low": "hydrogen",
            "gemini-4-hydrogen-medium": "hydrogen",
            "gemini-4-hydrogen-high": "hydrogen",
            "gemini-4-hydrogen-xhigh": "hydrogen",
            # Argon (including orchestrator-argon BEFORE orchestrator/carbon!)
            "gemini-4-argon-low": "argon",
            "gemini-4-argon-medium": "argon",
            "gemini-4-argon-high": "argon",
            "gemini-pro-orchestrator-argon": "argon",
            # Carbon & Pro/Ultra/Orchestrator
            "gemini-4-carbon-low": "carbon",
            "gemini-4-carbon-medium": "carbon",
            "gemini-4-carbon-high": "carbon",
            "gemini-pro-orchestrator": "carbon",
            "gemini-2.5-pro": "carbon",
            "vertex_ai/gemini-3-pro-preview": "carbon",
            "gemini-1.5-ultra": "carbon",
            # Flash & Lite
            "gemini-3.8-flash-low": "flash",
            "gemini-3.8-flash-medium": "flash",
            "gemini-3.8-flash-high": "flash",
            "gemini-2.5-flash": "flash",
            "gemini-2.5-flash-lite": "flash",
            # Claude
            "claude-opus-5-5-low": "claude",
            "claude-opus-5-5-medium": "claude",
            "claude-opus-5-5-high": "claude",
            "claude-sonnet-5-5-medium": "claude",
            "claude-haiku-4-5": "claude",
            # Other
            "gpt-oss-120b-medium": "other",
            "unknown-custom-model": "other",
            "": "other",
        }
        for raw, expected in cases.items():
            with self.subTest(model=raw):
                self.assertEqual(au.classify_model(raw), expected)


class TestPricingAndFallback(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.cache_dir = Path(self.tmp.name) / "cache"
        au.set_cache_dir(self.cache_dir)
        au.load_pricing(offline=True)

    def tearDown(self) -> None:
        au.set_cache_dir(au.DEFAULT_CACHE_DIR)
        self.tmp.cleanup()

    def test_offline_codename_family_fallback_pricing(self) -> None:
        self.assertEqual(au._PRICING_SOURCE, "fallback")

        # Verify every required AGY codename family resolves cleanly
        h = au.lookup_fallback_pricing("gemini-4-hydrogen-xhigh")
        self.assertAlmostEqual(h["input"], 2.50)
        self.assertAlmostEqual(h["output"], 15.00)
        self.assertAlmostEqual(h["cache_read"], 0.625)

        c = au.lookup_fallback_pricing("gemini-4-carbon-medium")
        self.assertAlmostEqual(c["input"], 1.25)
        self.assertAlmostEqual(c["output"], 10.00)
        self.assertAlmostEqual(c["cache_read"], 0.3125)

        a = au.lookup_fallback_pricing("gemini-4-argon-high")
        self.assertAlmostEqual(a["input"], 1.25)
        self.assertAlmostEqual(a["output"], 10.00)

        orch = au.lookup_fallback_pricing("gemini-pro-orchestrator")
        self.assertAlmostEqual(orch["input"], 1.25)

        orch_a = au.lookup_fallback_pricing("gemini-pro-orchestrator-argon")
        self.assertAlmostEqual(orch_a["input"], 1.25)

        fl = au.lookup_fallback_pricing("gemini-3.8-flash-medium")
        self.assertAlmostEqual(fl["input"], 0.30)
        self.assertAlmostEqual(fl["output"], 2.50)
        self.assertAlmostEqual(fl["cache_read"], 0.075)

        opus = au.lookup_fallback_pricing("claude-opus-5-5-high")
        sonnet = au.lookup_fallback_pricing("claude-sonnet-5-5-high")
        self.assertGreater(opus["input"], sonnet["input"])
        self.assertAlmostEqual(opus["input"], 5.00)
        self.assertAlmostEqual(sonnet["input"], 3.00)

        gpt_oss = au.lookup_fallback_pricing("gpt-oss-120b-medium")
        self.assertAlmostEqual(gpt_oss["input"], 0.15)
        self.assertAlmostEqual(gpt_oss["output"], 0.60)

    def test_litellm_cache_and_effort_suffix_matching(self) -> None:
        fake_litellm = {
            "gemini/gemini-2.5-flash": {
                "input_cost_per_token": 0.00000035,
                "output_cost_per_token": 0.00000280,
                "cache_read_input_token_cost": 0.0000000875,
                "litellm_provider": "gemini",
            },
            "claude-sonnet-4-6": {
                "input_cost_per_token": 0.000003,
                "output_cost_per_token": 0.000015,
                "cache_creation_input_token_cost": 0.00000375,
                "cache_read_input_token_cost": 0.0000003,
            },
            "broken-model": {
                "input_cost_per_token": None,
                "output_cost_per_token": "not-a-number",
            },
        }
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        (self.cache_dir / "litellm_pricing.json").write_text(
            json.dumps(fake_litellm), encoding="utf-8"
        )

        au.load_pricing(offline=False)
        self.assertEqual(au._PRICING_SOURCE, "litellm")

        # Effort-suffixed public model matches gemini/gemini-2.5-flash in LiteLLM
        p_flash = au.lookup_model_pricing("gemini-2.5-flash-high")
        self.assertIsNotNone(p_flash)
        assert p_flash is not None
        self.assertAlmostEqual(p_flash["input"], 0.35)
        self.assertAlmostEqual(p_flash["output"], 2.80)

        # Malformed LiteLLM entry safely returns None and falls back
        self.assertIsNone(au.lookup_model_pricing("broken-model"))

        # Internal AGY codename absent from LiteLLM falls back cleanly to AGY family pricing
        self.assertIsNone(au.lookup_model_pricing("gemini-4-carbon-medium"))
        cost = au.cost_for_message(
            {
                "input_tokens": 1_000_000,
                "output_tokens": 100_000,
                "cache_write": 0,
                "cache_read": 2_000_000,
            },
            "gemini-4-carbon-medium",
        )
        # 1M * $1.25 + 0.1M * $10.00 + 2M * $0.3125 = 1.25 + 1.00 + 0.625 = 2.875
        self.assertAlmostEqual(cost, 2.875, places=6)


class TestScannerTokenMathDedupSentinelAndSQLite(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.gemini_dir = self.root / "gemini"
        self.cache_dir = self.root / "cache"
        au.set_cache_dir(self.cache_dir)
        au.load_pricing(offline=True)
        au._GAP_MINUTES = 10

    def tearDown(self) -> None:
        au.set_cache_dir(au.DEFAULT_CACHE_DIR)
        au._GAP_MINUTES = au.DEFAULT_GAP_MINUTES
        self.tmp.cleanup()

    def test_token_math_chunks_skip_and_swarm_workers_included(self) -> None:
        # Coordinator conversation on antigravity-cli
        _write_transcript(
            self.gemini_dir,
            "antigravity-cli",
            "coord-111",
            [
                {
                    "step_index": 0,
                    "source": "USER_EXPLICIT",
                    "type": "USER_INPUT",
                    "status": "DONE",
                    "created_at": "2026-11-16T04:00:00Z",
                    "content": "<USER_REQUEST>Build AGYMonitor</USER_REQUEST>",
                },
                {
                    "step_index": 2,
                    "source": "MODEL",
                    "type": "PLANNER_RESPONSE",
                    "status": "DONE",
                    "created_at": "2026-11-16T04:00:10.123456789Z",
                    "model": "gemini-4-carbon-medium",
                    "input_tokens": 10000,
                    "cache_read_tokens": 20000,
                    "output_tokens": 500,
                },
            ],
        )

        # Write a chunk file & transcript_full.jsonl that MUST NOT be double-counted
        chunks_dir = (
            self.gemini_dir
            / "antigravity-cli"
            / "brain"
            / "coord-111"
            / ".system_generated"
            / "logs"
            / "chunks"
        )
        chunks_dir.mkdir(parents=True, exist_ok=True)
        (chunks_dir / "chunk_000.jsonl").write_text(
            json.dumps({
                "step_index": 99,
                "type": "PLANNER_RESPONSE",
                "created_at": "2026-11-16T04:00:15Z",
                "model": "gemini-4-carbon-medium",
                "input_tokens": 999999,
                "cache_read_tokens": 999999,
                "output_tokens": 999999,
            }) + "\n",
            encoding="utf-8",
        )
        full_path = chunks_dir.parent / "transcript_full.jsonl"
        full_path.write_text(
            json.dumps({
                "step_index": 98,
                "type": "PLANNER_RESPONSE",
                "created_at": "2026-11-16T04:00:15Z",
                "model": "gemini-4-carbon-medium",
                "input_tokens": 888888,
                "output_tokens": 888888,
            }) + "\n",
            encoding="utf-8",
        )

        # Swarm worker brain dir on antigravity-cli + desktop conversation on antigravity
        # + IDE conversation on antigravity-ide
        _write_transcript(
            self.gemini_dir,
            "antigravity-cli",
            "worker-222",
            [
                {
                    "step_index": 1,
                    "type": "PLANNER_RESPONSE",
                    "status": "DONE",
                    "created_at": "2026-11-16T04:02:00Z",
                    "model": "gemini-4-hydrogen-high",
                    "input_tokens": 4000,
                    "cache_read_tokens": 8000,
                    "output_tokens": 1000,
                },
            ],
        )
        _write_transcript(
            self.gemini_dir,
            "antigravity",
            "desktop-333",
            [
                {
                    "step_index": 3,
                    "type": "PLANNER_RESPONSE",
                    "status": "DONE",
                    "created_at": "2026-11-16T04:04:00Z",
                    "model": "claude-opus-5-5-medium",
                    "input_tokens": 2000,
                    "cache_read_tokens": 6000,
                    "output_tokens": 400,
                },
            ],
        )
        _write_transcript(
            self.gemini_dir,
            "antigravity-ide",
            "ide-444",
            [
                {
                    "step_index": 1,
                    "type": "PLANNER_RESPONSE",
                    "status": "DONE",
                    "created_at": "2026-11-16T04:05:00Z",
                    "model": "gemini-pro-orchestrator-argon",
                    "input_tokens": 3000,
                    "cache_read_tokens": 1000,
                    "output_tokens": 300,
                },
            ],
        )

        # Empty transcript & encrypted legacy .pb without transcript
        empty_t = (
            self.gemini_dir
            / "antigravity"
            / "brain"
            / "empty-555"
            / ".system_generated"
            / "logs"
            / "transcript.jsonl"
        )
        empty_t.parent.mkdir(parents=True, exist_ok=True)
        empty_t.write_text("", encoding="utf-8")

        enc_pb = self.gemini_dir / "antigravity" / "conversations" / "legacy-enc.pb"
        enc_pb.parent.mkdir(parents=True, exist_ok=True)
        enc_pb.write_bytes(os.urandom(128))

        local_day = datetime.fromisoformat("2026-11-16T04:00:00+00:00").astimezone().strftime("%Y-%m-%d")
        start_dt, end_dt = au.resolve_range(f"{local_day}:{local_day}")
        sessions, time_days = au.scan_sessions(
            start_dt, end_dt, use_cache=False, data_dirs=[self.gemini_dir], load_workspaces=True
        )
        payload = au.build_json_payload(sessions, include_sessions=True, time_days=time_days)

        # AGY input_tokens is ALREADY uncached new input tokens (never subtracted!)
        carbon = payload["totals_by_model"]["carbon"]
        self.assertEqual(carbon["input_tokens"], 10000)
        self.assertEqual(carbon["cache_read"], 20000)
        self.assertEqual(carbon["output_tokens"], 500)
        self.assertEqual(carbon["cache_write"], 0)
        self.assertEqual(carbon["messages"], 1)

        hydrogen = payload["totals_by_model"]["hydrogen"]
        self.assertEqual(hydrogen["input_tokens"], 4000)
        self.assertEqual(hydrogen["cache_read"], 8000)
        self.assertEqual(hydrogen["output_tokens"], 1000)

        argon = payload["totals_by_model"]["argon"]
        self.assertEqual(argon["input_tokens"], 3000)
        self.assertEqual(argon["cache_read"], 1000)
        self.assertEqual(argon["output_tokens"], 300)

        claude = payload["totals_by_model"]["claude"]
        self.assertEqual(claude["input_tokens"], 2000)
        self.assertEqual(claude["cache_read"], 6000)
        self.assertEqual(claude["output_tokens"], 400)
        # Opus fallback rate: (2000*5 + 400*25 + 6000*0.50) / 1e6 = (10000+10000+3000)/1e6 = 0.023
        self.assertAlmostEqual(claude["cost"], 0.023, places=4)

        self.assertEqual(payload["diagnostics"]["skipped_encrypted_pb"], 1)
        self.assertEqual(len(payload["sessions"]), 4)

    def test_workspace_map_unwraps_conversations_envelope(self) -> None:
        _write_transcript(
            self.gemini_dir,
            "antigravity-cli",
            "ws-conv-1",
            [
                {
                    "step_index": 1,
                    "type": "PLANNER_RESPONSE",
                    "status": "DONE",
                    "created_at": "2026-11-16T05:00:00Z",
                    "model": "gemini-4-carbon-medium",
                    "input_tokens": 1200,
                    "cache_read_tokens": 400,
                    "output_tokens": 150,
                },
            ],
        )
        _write_transcript(
            self.gemini_dir,
            "antigravity-cli",
            "ws-conv-2",
            [
                {
                    "step_index": 1,
                    "type": "PLANNER_RESPONSE",
                    "status": "DONE",
                    "created_at": "2026-11-16T05:01:00Z",
                    "model": "gemini-3.8-flash-medium",
                    "input_tokens": 800,
                    "output_tokens": 100,
                },
            ],
        )

        meta_path = self.gemini_dir / "antigravity-cli" / "cache" / "conversation_metadata.json"
        meta_path.parent.mkdir(parents=True, exist_ok=True)
        home_proj_uri = "file://" + str(Path.home() / "Developer" / "AGYMonitor")
        meta_doc = {
            "conversations": {
                "ws-conv-1": {
                    "summary": {
                        "ID": "ws-conv-1",
                        "WorkspaceURIs": [home_proj_uri],
                    },
                    "is_internal": False,
                },
                "ws-conv-2": {
                    "summary": {
                        "ID": "ws-conv-2",
                        "WorkspaceURIs": ["file:///opt/my%20workspace"],
                    },
                    "is_internal": False,
                },
            }
        }
        meta_path.write_text(json.dumps(meta_doc), encoding="utf-8")

        ws_map = au._load_workspace_map([self.gemini_dir])
        self.assertEqual(ws_map["ws-conv-1"], "~/Developer/AGYMonitor")
        self.assertEqual(ws_map["ws-conv-2"], "/opt/my workspace")

        local_day = datetime.fromisoformat("2026-11-16T05:00:00+00:00").astimezone().strftime("%Y-%m-%d")
        start_dt, end_dt = au.resolve_range(f"{local_day}:{local_day}")
        sessions, _ = au.scan_sessions(
            start_dt,
            end_dt,
            project_filter="AGYMonitor",
            use_cache=False,
            data_dirs=[self.gemini_dir],
            load_workspaces=True,
        )
        self.assertEqual(list(sessions.keys()), ["ws-conv-1"])
        self.assertEqual(sessions["ws-conv-1"]["project"], "~/Developer/AGYMonitor")

    def test_dedup_within_file_and_across_surfaces(self) -> None:
        # Same conversation has streaming/status rewrite in CLI surface AND a mirror in desktop surface
        _write_transcript(
            self.gemini_dir,
            "antigravity-cli",
            "dup-conv",
            [
                # Partial RUNNING line for step_index=5
                {
                    "step_index": 5,
                    "type": "PLANNER_RESPONSE",
                    "status": "RUNNING",
                    "created_at": "2026-11-16T06:00:00Z",
                    "model": "gemini-4-carbon-medium",
                    "input_tokens": 5000,
                    "cache_read_tokens": 10000,
                    "output_tokens": 50,
                },
                # Final DONE line for step_index=5 (upgraded output_tokens)
                {
                    "step_index": 5,
                    "type": "PLANNER_RESPONSE",
                    "status": "DONE",
                    "created_at": "2026-11-16T06:00:05Z",
                    "model": "gemini-4-carbon-medium",
                    "input_tokens": 5000,
                    "cache_read_tokens": 10000,
                    "output_tokens": 600,
                },
                # Exact duplicate line for step_index=5
                {
                    "step_index": 5,
                    "type": "PLANNER_RESPONSE",
                    "status": "DONE",
                    "created_at": "2026-11-16T06:00:05Z",
                    "model": "gemini-4-carbon-medium",
                    "input_tokens": 5000,
                    "cache_read_tokens": 10000,
                    "output_tokens": 600,
                },
            ],
        )
        # Mirror of dup-conv in `antigravity` surface with step_index=5 and step_index=8
        _write_transcript(
            self.gemini_dir,
            "antigravity",
            "dup-conv",
            [
                {
                    "step_index": 5,
                    "type": "PLANNER_RESPONSE",
                    "status": "DONE",
                    "created_at": "2026-11-16T06:00:05Z",
                    "model": "gemini-4-carbon-medium",
                    "input_tokens": 5000,
                    "cache_read_tokens": 10000,
                    "output_tokens": 600,
                },
                {
                    "step_index": 8,
                    "type": "PLANNER_RESPONSE",
                    "status": "DONE",
                    "created_at": "2026-11-16T06:01:00Z",
                    "model": "gemini-4-carbon-medium",
                    "input_tokens": 2000,
                    "cache_read_tokens": 15000,
                    "output_tokens": 300,
                },
            ],
        )

        local_day = datetime.fromisoformat("2026-11-16T06:00:00+00:00").astimezone().strftime("%Y-%m-%d")
        start_dt, end_dt = au.resolve_range(f"{local_day}:{local_day}")
        sessions, _ = au.scan_sessions(start_dt, end_dt, use_cache=False, data_dirs=[self.gemini_dir])
        payload = au.build_json_payload(sessions, include_sessions=False)

        carbon = payload["totals_by_model"]["carbon"]
        # Step 5 (5000, 10000, 600) + Step 8 (2000, 15000, 300) = 2 unique steps!
        self.assertEqual(carbon["messages"], 2)
        self.assertEqual(carbon["input_tokens"], 7000)
        self.assertEqual(carbon["cache_read"], 25000)
        self.assertEqual(carbon["output_tokens"], 900)
        self.assertEqual(payload["diagnostics"]["unique_messages"], 2)
        self.assertGreaterEqual(payload["diagnostics"]["usage_upgraded_lines"], 1)

    def test_sentinel_dates_skipped_cleanly(self) -> None:
        _write_transcript(
            self.gemini_dir,
            "antigravity-cli",
            "sentinel-conv",
            [
                {
                    "step_index": 0,
                    "type": "USER_INPUT",
                    "created_at": "0001-01-01T00:00:00Z",
                    "content": "Uninitialized step",
                },
                {
                    "step_index": 1,
                    "type": "PLANNER_RESPONSE",
                    "status": "RUNNING",
                    "created_at": "0001-01-01T00:00:00Z",
                    "model": "gemini-4-carbon-medium",
                    "input_tokens": 99999,
                    "output_tokens": 99999,
                },
                {
                    "step_index": 2,
                    "type": "PLANNER_RESPONSE",
                    "status": "DONE",
                    "created_at": "2026-11-16T08:00:00Z",
                    "model": "gemini-3.8-flash-medium",
                    "input_tokens": 1500,
                    "cache_read_tokens": 500,
                    "output_tokens": 250,
                },
                "not valid json {{{",
            ],
        )
        local_day = datetime.fromisoformat("2026-11-16T08:00:00+00:00").astimezone().strftime("%Y-%m-%d")
        start_dt, end_dt = au.resolve_range(f"{local_day}:{local_day}")
        sessions, time_days = au.scan_sessions(start_dt, end_dt, use_cache=False, data_dirs=[self.gemini_dir])
        payload = au.build_json_payload(sessions, include_sessions=True, time_days=time_days)

        self.assertNotIn("carbon", payload["totals_by_model"])
        self.assertEqual(payload["totals_by_model"]["flash"]["input_tokens"], 1500)
        self.assertEqual(payload["diagnostics"]["sentinel_ts_lines"], 2)
        self.assertEqual(payload["diagnostics"]["skipped_lines"], 1)
        self.assertEqual(payload["diagnostics"]["time_event_lines"], 1)
        # Session start timestamp came from the real step, never 0001-01-01
        self.assertTrue(payload["sessions"][0]["timestamp"].startswith("2026-11-16"))

    def test_sqlite_gen_metadata_cache_write_and_immutable_wal_fallback(self) -> None:
        conv_id = "wal-conv-777"
        _write_transcript(
            self.gemini_dir,
            "antigravity-cli",
            conv_id,
            [
                {
                    "step_index": 4,
                    "type": "PLANNER_RESPONSE",
                    "status": "DONE",
                    "created_at": "2026-11-16T09:00:00Z",
                    "model": "claude-sonnet-5-5-medium",
                    "input_tokens": 1000,
                    "cache_read_tokens": 2000,
                    "output_tokens": 100,
                },
            ],
        )

        conv_dir = self.gemini_dir / "antigravity-cli" / "conversations"
        conv_dir.mkdir(parents=True, exist_ok=True)
        db_path = conv_dir / f"{conv_id}.db"

        # Create a WAL-mode SQLite database with gen_metadata, checkpoint & close all
        # cursors/connections, and ensure -wal/-shm are absent (matching an exited
        # writer that checkpointed and removed sidecars while DB header stays WAL).
        conn = sqlite3.connect(str(db_path))
        cur = conn.cursor()
        cur.execute("PRAGMA journal_mode=WAL")
        cur.execute("CREATE TABLE gen_metadata (idx INT PRIMARY KEY, data BLOB, size INT)")
        blob = _build_gen_metadata_blob(inp=1000, out=100, cache_write=8000, cache_read=2000)
        cur.execute("INSERT INTO gen_metadata (idx, data, size) VALUES (?, ?, ?)", (4, blob, len(blob)))
        conn.commit()
        cur.execute("PRAGMA wal_checkpoint(FULL)")
        cur.close()
        conn.close()
        shm_path = conv_dir / f"{conv_id}.db-shm"
        wal_path = conv_dir / f"{conv_id}.db-wal"
        shm_path.unlink(missing_ok=True)
        wal_path.unlink(missing_ok=True)
        self.assertFalse(shm_path.exists())
        self.assertFalse(wal_path.exists())

        # 1. Make conversations/ and the .db read-only (0o555 / 0o444) and verify
        #    our reader succeeds cleanly without creating -wal/-shm sidecars.
        os.chmod(db_path, 0o444)
        os.chmod(conv_dir, 0o555)
        try:
            cw_map = au.read_sqlite_cache_writes(db_path)
            self.assertEqual(cw_map, {4: 8000})
            self.assertFalse(shm_path.exists())
            self.assertFalse(wal_path.exists())

            # 2. Explicitly verify the `?mode=ro` -> `?mode=ro&immutable=1` fallback
            #    when `?mode=ro` raises SQLITE_CANTOPEN / OperationalError (e.g. inside
            #    a strict read-only sandbox where shm creation is denied with EPERM).
            real_connect = sqlite3.connect
            attempted_uris: List[str] = []

            def connect_simulating_ro_cantopen(database: str, *args: Any, **kwargs: Any) -> sqlite3.Connection:
                attempted_uris.append(database)
                if "immutable=1" not in database:
                    raise sqlite3.OperationalError("unable to open database file")
                return real_connect(database, *args, **kwargs)

            with mock.patch.object(au.sqlite3, "connect", side_effect=connect_simulating_ro_cantopen):
                cw_fallback = au.read_sqlite_cache_writes(db_path)
            self.assertEqual(cw_fallback, {4: 8000})
            self.assertEqual(len(attempted_uris), 2)
            self.assertTrue(attempted_uris[0].endswith("?mode=ro"))
            self.assertIn("mode=ro&immutable=1", attempted_uris[1])

            local_day = datetime.fromisoformat("2026-11-16T09:00:00+00:00").astimezone().strftime("%Y-%m-%d")
            start_dt, end_dt = au.resolve_range(f"{local_day}:{local_day}")
            sessions, _ = au.scan_sessions(start_dt, end_dt, use_cache=False, data_dirs=[self.gemini_dir])
            payload = au.build_json_payload(sessions, include_sessions=False)

            claude = payload["totals_by_model"]["claude"]
            self.assertEqual(claude["cache_write"], 8000)
            self.assertEqual(payload["diagnostics"]["sqlite_supplemented_steps"], 1)
        finally:
            os.chmod(conv_dir, 0o755)
            os.chmod(db_path, 0o644)


class TestActiveTimeIntervalsAndCache(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.gemini_dir = self.root / "gemini"
        self.cache_dir = self.root / "cache"
        au.set_cache_dir(self.cache_dir)
        au.load_pricing(offline=True)
        au._GAP_MINUTES = 10

    def tearDown(self) -> None:
        au.set_cache_dir(au.DEFAULT_CACHE_DIR)
        au._GAP_MINUTES = au.DEFAULT_GAP_MINUTES
        self.tmp.cleanup()

    def test_cross_midnight_and_10min_gap_merging(self) -> None:
        # Build timestamps anchored in the system local timezone so the test is
        # deterministic regardless of which timezone the runner machine uses!
        day1 = datetime(2026, 6, 15, 0, 0, 0).astimezone()
        day2 = (datetime(2026, 6, 15, 0, 0, 0) + timedelta(days=1)).astimezone()

        # Interval 1 on day 1: 10:00:00 -> 10:10:00 (exact 10-min gap merges!) -> 10:15:00 (900s)
        t1 = (day1.replace(hour=10, minute=0, second=0)).isoformat()
        t2 = (day1.replace(hour=10, minute=10, second=0)).isoformat()
        t3 = (day1.replace(hour=10, minute=15, second=0)).isoformat()
        # Separate interval (> 10 min later: 10:25:01 -> 10:30:01 = 300s)
        t4 = (day1.replace(hour=10, minute=25, second=1)).isoformat()
        t5 = (day1.replace(hour=10, minute=30, second=1)).isoformat()

        # Cross-midnight bridge across TWO separate conversations!
        # Conv A at 23:55:00 on day 1 (300s before midnight)
        t_mid_a = (day1.replace(hour=23, minute=55, second=0)).isoformat()
        # Conv B at 00:04:00 on day 2 (240s after midnight; 9 min after Conv A -> merges!)
        t_mid_b = (day2.replace(hour=0, minute=4, second=0)).isoformat()

        _write_transcript(
            self.gemini_dir,
            "antigravity-cli",
            "conv-a",
            [
                {"step_index": 0, "type": "USER_INPUT", "created_at": t1, "content": "hi"},
                {
                    "step_index": 1,
                    "type": "PLANNER_RESPONSE",
                    "created_at": t2,
                    "model": "gemini-4-carbon-medium",
                    "input_tokens": 100,
                    "output_tokens": 50,
                },
                {"step_index": 2, "type": "GENERIC", "created_at": t3},
                {"step_index": 3, "type": "USER_INPUT", "created_at": t4, "content": "more"},
                {
                    "step_index": 4,
                    "type": "PLANNER_RESPONSE",
                    "created_at": t5,
                    "model": "gemini-3.8-flash-medium",
                    "input_tokens": 100,
                    "output_tokens": 50,
                },
                {
                    "step_index": 5,
                    "type": "PLANNER_RESPONSE",
                    "created_at": t_mid_a,
                    "model": "gemini-4-hydrogen-high",
                    "input_tokens": 200,
                    "output_tokens": 100,
                },
            ],
        )
        _write_transcript(
            self.gemini_dir,
            "antigravity-cli",
            "conv-b",
            [
                {
                    "step_index": 0,
                    "type": "PLANNER_RESPONSE",
                    "created_at": t_mid_b,
                    "model": "gemini-4-hydrogen-high",
                    "input_tokens": 300,
                    "output_tokens": 100,
                },
            ],
        )

        start_dt, end_dt = au.resolve_range("2026-06-15:2026-06-16")
        _sessions, time_days = au.scan_sessions(
            start_dt, end_dt, use_cache=False, data_dirs=[self.gemini_dir]
        )

        d1 = time_days["2026-06-15"]
        d2 = time_days["2026-06-16"]

        # Day 1 has:
        # [36000, 36900, "carbon"] (900s)
        # [37501, 37801, "flash"]  (300s)
        # [86100, 86400, "hydrogen"] (300s)
        self.assertEqual(
            d1["intervals"],
            [
                [36000, 36900, "carbon"],
                [37501, 37801, "flash"],
                [86100, 86400, "hydrogen"],
            ],
        )
        self.assertEqual(d1["total_seconds"], 1500)

        # Day 2 has the post-midnight half of the bridged interval:
        # [0, 240, "hydrogen"] (240s)
        self.assertEqual(d2["intervals"], [[0, 240, "hydrogen"]])
        self.assertEqual(d2["total_seconds"], 240)

    def test_incremental_scan_cache_hit_miss_prune_and_equivalence(self) -> None:
        t_a = _write_transcript(
            self.gemini_dir,
            "antigravity-cli",
            "cache-conv-1",
            [
                {
                    "step_index": 1,
                    "type": "PLANNER_RESPONSE",
                    "created_at": "2026-11-10T10:00:00Z",
                    "model": "gemini-4-carbon-medium",
                    "input_tokens": 5000,
                    "cache_read_tokens": 12000,
                    "output_tokens": 800,
                },
            ],
        )
        t_b = _write_transcript(
            self.gemini_dir,
            "antigravity",
            "cache-conv-2",
            [
                {
                    "step_index": 1,
                    "type": "PLANNER_RESPONSE",
                    "created_at": "2026-11-11T10:00:00Z",
                    "model": "gemini-3.8-flash-low",
                    "input_tokens": 2000,
                    "cache_read_tokens": 4000,
                    "output_tokens": 300,
                },
            ],
        )

        start_dt, end_dt = au.resolve_range("2026-11-01:2026-11-30")

        # 1. Cold scan populates scan-cache.json
        s_cold, td_cold = au.scan_sessions(start_dt, end_dt, use_cache=True, data_dirs=[self.gemini_dir])
        p_cold = au.build_json_payload(s_cold, include_sessions=False, time_days=td_cold)
        self.assertEqual(p_cold["diagnostics"]["cache_miss_files"], 2)
        self.assertEqual(p_cold["diagnostics"]["cache_hit_files"], 0)
        self.assertTrue((self.cache_dir / "scan-cache.json").is_file())

        # 2. Warm scan hits cache for both files and matches --no-cache ground truth
        s_warm, td_warm = au.scan_sessions(start_dt, end_dt, use_cache=True, data_dirs=[self.gemini_dir])
        p_warm = au.build_json_payload(s_warm, include_sessions=False, time_days=td_warm)
        self.assertEqual(p_warm["diagnostics"]["cache_hit_files"], 2)
        self.assertEqual(p_warm["diagnostics"]["cache_miss_files"], 0)

        s_nocache, td_nocache = au.scan_sessions(start_dt, end_dt, use_cache=False, data_dirs=[self.gemini_dir])
        p_nocache = au.build_json_payload(s_nocache, include_sessions=False, time_days=td_nocache)

        for key in ("grand_total_cost", "totals_by_model", "daily_breakdown", "time"):
            self.assertEqual(p_warm[key], p_nocache[key])

        # 3. Append a step to t_a and remove t_b -> 1 miss, 1 pruned
        with open(t_a, "a", encoding="utf-8") as f:
            f.write(
                json.dumps({
                    "step_index": 2,
                    "type": "PLANNER_RESPONSE",
                    "created_at": "2026-11-10T10:05:00Z",
                    "model": "gemini-4-carbon-medium",
                    "input_tokens": 1000,
                    "cache_read_tokens": 17000,
                    "output_tokens": 200,
                }) + "\n"
            )
        t_b.unlink()

        s_upd, td_upd = au.scan_sessions(start_dt, end_dt, use_cache=True, data_dirs=[self.gemini_dir])
        p_upd = au.build_json_payload(s_upd, include_sessions=False, time_days=td_upd)
        self.assertEqual(p_upd["diagnostics"]["cache_miss_files"], 1)
        self.assertEqual(p_upd["diagnostics"]["cache_pruned_files"], 1)
        self.assertEqual(p_upd["totals_by_model"]["carbon"]["input_tokens"], 6000)
        self.assertNotIn("flash", p_upd["totals_by_model"])

    def test_cli_json_no_sessions_and_time_year(self) -> None:
        _write_transcript(
            self.gemini_dir,
            "antigravity-cli",
            "cli-conv",
            [
                {"step_index": 0, "type": "USER_INPUT", "created_at": "2026-11-16T02:00:00Z", "content": "hello"},
                {
                    "step_index": 1,
                    "type": "PLANNER_RESPONSE",
                    "created_at": "2026-11-16T02:03:00Z",
                    "model": "gemini-4-carbon-high",
                    "input_tokens": 8000,
                    "cache_read_tokens": 4000,
                    "output_tokens": 1000,
                },
            ],
        )

        # Standard UsageStore invocation: --json --no-sessions --range YYYY-MM-DD:YYYY-MM-DD
        proc = subprocess.run(
            [
                sys.executable,
                str(SCRIPT_PATH),
                "--json",
                "--no-sessions",
                "--offline",
                "--data-dir",
                str(self.gemini_dir),
                "--cache-dir",
                str(self.cache_dir),
                "--range",
                "2026-11-01:2026-11-30",
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        out = json.loads(proc.stdout)
        self.assertEqual(out["script_version"], au.__version__)
        self.assertNotIn("sessions", out)
        self.assertIn("totals_by_model", out)
        self.assertIn("daily_breakdown", out)
        self.assertIn("time", out)
        self.assertEqual(out["time"]["gap_minutes"], 10)
        self.assertEqual(out["totals_by_model"]["carbon"]["input_tokens"], 8000)
        self.assertGreater(out["grand_total_cost"], 0.0)

        # --time-year 2026 invocation
        proc_yr = subprocess.run(
            [
                sys.executable,
                str(SCRIPT_PATH),
                "--time-year",
                "2026",
                "--data-dir",
                str(self.gemini_dir),
                "--cache-dir",
                str(self.cache_dir),
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        yr = json.loads(proc_yr.stdout)
        self.assertEqual(yr["script_version"], au.__version__)
        self.assertEqual(yr["year"], 2026)
        self.assertEqual(yr["gap_minutes"], 10)
        self.assertEqual(len(yr["days"]), 365)
        local_day = datetime.fromisoformat("2026-11-16T02:00:00+00:00").astimezone().strftime("%Y-%m-%d")
        self.assertEqual(yr["days"][local_day], 180)


if __name__ == "__main__":
    unittest.main()
