#!/usr/bin/env python3
"""Cross-language parity, Package.swift manifest, and version-lockstep tests."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import plistlib
import re
import unittest
from typing import Dict, List, Set

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = REPO_ROOT / "Resources" / "analyze_usage.py"
MODEL_CLASS_SWIFT = REPO_ROOT / "Sources" / "Core_ModelClass.swift"
PACKAGE_SWIFT = REPO_ROOT / "Package.swift"
INFO_PLIST = REPO_ROOT / "Info.plist"
QUOTA_SERVICE_SWIFT = REPO_ROOT / "Sources" / "QuotaService.swift"
LOCALIZATION_SWIFT = REPO_ROOT / "Sources" / "Localization.swift"


def _load_analyze_usage():
    spec = importlib.util.spec_from_file_location("analyze_usage_parity", str(SCRIPT_PATH))
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


au = _load_analyze_usage()


def _parse_swift_array(text: str, label: str) -> List[str]:
    m = re.search(rf"{label}:\s*\[(.*?)\]", text, re.DOTALL)
    assert m is not None, f"Could not find `{label}: [...]` in Package.swift"
    return re.findall(r'"([^"]+\.swift)"', m.group(1))


class TestCrossLanguageParity(unittest.TestCase):
    def test_model_class_order_and_cases_match_swift(self) -> None:
        swift_src = MODEL_CLASS_SWIFT.read_text(encoding="utf-8")
        # Extract `case <ident> = "<raw>"` declarations inside ModelClass in source order
        enum_body = swift_src.split("public enum ModelClass:", 1)[1].split("public var displayName", 1)[0]
        swift_cases = tuple(re.findall(r'case\s+\w+\s*=\s*"([a-z]+)"', enum_body))
        self.assertEqual(swift_cases, au.MODEL_CLASSES)

    def test_classification_parity_fixtures(self) -> None:
        fixtures = [
            ("gemini-4-carbon-high", "carbon"),
            ("gemini-pro-orchestrator", "carbon"),
            ("Orchestrator (Carbon)", "carbon"),
            ("gemini-4-argon-medium", "argon"),
            ("gemini-pro-orchestrator-argon", "argon"),
            ("Orchestrator (Argon)", "argon"),
            ("gemini-4-neon-xhigh", "neon"),
            ("gemini-pro-orchestrator-neon", "neon"),
            ("Orchestrator (Neon)", "neon"),
            ("gemini-4-hydrogen-high", "hydrogen"),
            ("gemini-flash-worker-agy", "hydrogen"),
            ("gemini-3.8-flash-high", "flash"),
            ("gemini-2.5-flash-lite", "flash"),
            ("claude-opus-5-5-high", "claude"),
            ("claude-sonnet-4-6", "claude"),
            ("gpt-oss-120b-medium", "other"),
        ]
        for raw, expected in fixtures:
            self.assertEqual(au.classify_model(raw), expected, msg=f"classify_model({raw!r})")

    def test_version_lockstep(self) -> None:
        with open(INFO_PLIST, "rb") as f:
            plist = plistlib.load(f)
        short_version = str(plist["CFBundleShortVersionString"])
        bundle_version = str(plist["CFBundleVersion"])
        self.assertEqual(short_version, bundle_version)
        self.assertEqual(au.__version__, short_version)

        quota_src = QUOTA_SERVICE_SWIFT.read_text(encoding="utf-8")
        m = re.search(r'CFBundleShortVersionString[^\n]*\?\?\s*"([^"]+)"', quota_src)
        self.assertIsNotNone(m, "Fallback appVersion not found in Sources/QuotaService.swift")
        self.assertEqual(m.group(1), short_version)

    def test_package_swift_covers_all_sources(self) -> None:
        pkg_text = PACKAGE_SWIFT.read_text(encoding="utf-8")
        pkg_sources: Set[str] = set(_parse_swift_array(pkg_text, "sources"))
        pkg_exclude: Set[str] = set(_parse_swift_array(pkg_text, "exclude"))

        actual_files: Set[str] = {p.name for p in (REPO_ROOT / "Sources").glob("*.swift")}
        expected_core: Set[str] = {name for name in actual_files if name.startswith("Core_")}
        expected_app: Set[str] = actual_files - expected_core

        self.assertEqual(pkg_sources, expected_core)
        self.assertEqual(pkg_exclude, expected_app)
        self.assertTrue(pkg_sources.isdisjoint(pkg_exclude))

    def test_core_files_are_foundation_only(self) -> None:
        forbidden_import = re.compile(
            r"^\s*import\s+(AppKit|Cocoa|SwiftUI|CoreGraphics|Combine|SQLite3)\b",
            re.MULTILINE,
        )
        cgfloat_tok = re.compile(r"\bCGFloat\b")
        for p in sorted((REPO_ROOT / "Sources").glob("Core_*.swift")):
            lines = p.read_text(encoding="utf-8").splitlines()
            code_only = "\n".join(line.split("//", 1)[0] for line in lines)
            self.assertIsNone(
                forbidden_import.search(code_only),
                msg=f"{p.name} imports forbidden UI/App framework",
            )
            self.assertIsNone(
                cgfloat_tok.search(code_only),
                msg=f"{p.name} must use Double, not CGFloat",
            )

    def test_localization_key_and_format_parity(self) -> None:
        src = LOCALIZATION_SWIFT.read_text(encoding="utf-8")
        marker = "let i18n: [AppLanguage: [String: String]] = ["
        self.assertIn(marker, src)
        body = src.split(marker, 1)[1]

        locale_names = ("en", "zhHans", "zhHant", "ja")
        locales: Dict[str, Dict[str, str]] = {}
        current_locale = None
        locale_start_re = re.compile(r"^\s*\.(en|zhHans|zhHant|ja):\s*\[\s*$")
        locale_end_re = re.compile(r"^\s*\],\s*$")
        entry_re = re.compile(r'^\s*"((?:\\.|[^"\\])*)"\s*:\s*"((?:\\.|[^"\\])*)",?\s*$')

        for raw_line in body.splitlines():
            if current_locale is None:
                m_start = locale_start_re.match(raw_line)
                if m_start:
                    current_locale = m_start.group(1)
                    self.assertNotIn(current_locale, locales, msg=f"Duplicate locale .{current_locale}")
                    locales[current_locale] = {}
                continue

            if locale_end_re.match(raw_line):
                current_locale = None
                continue

            stripped = raw_line.strip()
            if not stripped or stripped.startswith("//"):
                continue

            m_entry = entry_re.match(raw_line)
            self.assertIsNotNone(
                m_entry,
                msg=f"Unparseable Localization.swift line in .{current_locale}: {raw_line!r}",
            )
            assert m_entry is not None
            key, val = m_entry.group(1), m_entry.group(2)
            self.assertNotIn(key, locales[current_locale], msg=f"Duplicate key {key!r} in .{current_locale}")
            locales[current_locale][key] = val

        self.assertEqual(set(locales.keys()), set(locale_names))
        en_map = locales["en"]
        self.assertGreater(len(en_map), 100)

        spec_re = re.compile(r"%%|%(?:\d+\$)?[-+ #0]*(?:\d+)?(?:\.\d+)?(?:ll|l|h|hh|z|t|j)?[@dDuUxXoOfeEgGcCsSp]")
        for loc in ("zhHans", "zhHant", "ja"):
            loc_map = locales[loc]
            self.assertEqual(
                set(loc_map.keys()),
                set(en_map.keys()),
                msg=(
                    f"Key mismatch in .{loc}: "
                    f"missing={sorted(set(en_map.keys()) - set(loc_map.keys()))}, "
                    f"extra={sorted(set(loc_map.keys()) - set(en_map.keys()))}"
                ),
            )
            for key, en_val in en_map.items():
                en_specs = spec_re.findall(en_val)
                loc_specs = spec_re.findall(loc_map[key])
                self.assertEqual(
                    loc_specs,
                    en_specs,
                    msg=f"Format specifier mismatch for key {key!r} in .{loc}: {loc_specs!r} != {en_specs!r}",
                )

    def test_app_layer_uses_core_sources_no_split_brain(self) -> None:
        app_sources = "\n".join(
            p.read_text(encoding="utf-8")
            for p in sorted((REPO_ROOT / "Sources").glob("*.swift"))
            if not p.name.startswith("Core_")
        )
        required_core_calls = [
            "AGYLocator",
            "SessionLogic.parseLsofPresence",
            "SessionLogic.parseConversationMetadataJSON",
            "SessionLogic.parseSwarmMembersJSON",
            "SessionLogic.resolveLiveSessionStatus",
            "SessionLogic.extractPresenceLockId",
            "SessionLogic.mergeConversationSummaryRows",
            "SessionLogic.parseSubagentRecordJSON",
            "TranscriptParse.parseAnnotationTitle",
            "NotchMachine.reduce",
            "NotchLiveWingMachine",
            "QuotaStateReducer.reduce",
            "QuotaPaceLogic",
            "RefreshQueueState",
            "MenuBarAnchorState",
            "MenuBarPanelMachine",
            "InstrumentMath",
            "TelemetryVisualMode",
            "UpdateCheckerMachine",
            "LiveTPSTracker",
            "ReplayStoreMachine",
            "ReplayPlaybackMachine",
            "HapticCadenceMachine",
            "AcousticEngineLifecycleMachine",
            "BlueprintWallpaperMachine",
            "SpecimenExporterMachine",
        ]
        for sym in required_core_calls:
            self.assertIn(sym, app_sources, msg=f"Split-brain check failed: {sym} not wired into app layer")


if __name__ == "__main__":
    unittest.main()
