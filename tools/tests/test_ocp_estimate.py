# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Tests of the resource estimate (tools/ocp_estimate.py and its JavaScript twin tools/estimate/ocp_resources.mjs).

- The memories of every configuration of tools/ocp_configs.py (also with the runtime configuration and the runtime
  parameters, and variants without speculation) equal those of the GHDL netlist of ocp_core
  (tools/tests/golden_memories.json, written by lint/memory_check.py).
- The JavaScript module gives the same memories and bits as the Python functions for every such configuration (with
  node on the PATH; skipped otherwise).

Run: python -m pytest tools/tests
"""

import json
import shutil
import subprocess
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


@pytest.mark.skipif(shutil.which("node") is None, reason="node not on the PATH")
def test_javascript_equals_python(tmp_path):
    names = sorted(CASES)
    (tmp_path / "generics.json").write_text(json.dumps([CASES[n] for n in names]), encoding="utf-8")
    res = subprocess.run(["node", str(TOOLS / "tests" / "estimate_runner.mjs"), str(tmp_path / "generics.json")],
                         capture_output=True, text=True, check=True, stdin=subprocess.DEVNULL)
    js = json.loads(res.stdout)
    for name, out in zip(names, js):
        g = CASES[name]
        assert out["memories"] == ocp_estimate.memories(g), name
        data, stored = ocp_estimate.ram_bits(g)
        assert out["ramBits"] == {"data": data, "stored": stored}, name
