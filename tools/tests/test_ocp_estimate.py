# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Tests of the resource estimate (tools/ocp_estimate.py and its JavaScript twin tools/estimate/ocp_resources.mjs).

- The memories of every configuration of tools/ocp_configs.py (also with the runtime configuration and the runtime
  parameters, and variants without speculation) equal those of the GHDL netlist of ocp_core
  (tools/tests/golden_memories.json, written by lint/memory_check.py).
- The JavaScript module is compared with the Python functions by tools/tests/ocp_resources.test.mjs (node --test).

Run: python -m pytest tools/tests
"""

import json
import sys
from collections import Counter
from pathlib import Path

import pytest

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
import ocp_estimate  # noqa: E402

GOLDEN = json.loads((TOOLS / "tests" / "golden_memories.json").read_text(encoding="utf-8"))
CASES = ocp_estimate.check_cases()


@pytest.mark.parametrize("entry", GOLDEN, ids=[e["name"] for e in GOLDEN])
def test_memories_equal_netlist(entry):
    g = CASES[entry["name"]]
    est = Counter((m["depth"], m["codeword"]) for m in ocp_estimate.memories(g))
    netlist = Counter({(d, w): k for d, w, k in entry["memories"]})
    assert est == netlist


def test_every_case_has_golden_data():
    assert sorted(CASES) == sorted(e["name"] for e in GOLDEN)
