# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""tools/compliance.py --check: an up-to-date compliance matrix passes, a stale or missing one fails."""

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import compliance  # noqa: E402


def run_check(monkeypatch, out):
    """compliance.main() with --check against the matrix file out: the exit code."""
    monkeypatch.setattr(compliance, "OUT", out)
    monkeypatch.setattr(sys, "argv", ["compliance.py", "--check"])
    with pytest.raises(SystemExit) as stop:
        compliance.main()
    return stop.value.code


def test_up_to_date(monkeypatch, tmp_path):
    out = tmp_path / "compliance.md"
    out.write_text(compliance.OUT.read_text(encoding="utf-8"), encoding="utf-8", newline="\n")
    assert run_check(monkeypatch, out) == 0


def test_stale(monkeypatch, tmp_path):
    out = tmp_path / "compliance.md"
    text = compliance.OUT.read_text(encoding="utf-8")
    out.write_text(text.replace("Requirements:", "Requirements (stale):", 1), encoding="utf-8", newline="\n")
    assert run_check(monkeypatch, out) == 1


def test_missing(monkeypatch, tmp_path):
    assert run_check(monkeypatch, tmp_path / "compliance.md") == 1
