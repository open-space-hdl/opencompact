# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Shards of the GHDL regression for the CI.

Usage: python tools/ci_shard.py <shard>    the names of the tests of the shard, one per line
       python tools/ci_shard.py --check    every test of the regression is in exactly one shard
The tests come from `python run.py --list`. Every test belongs to exactly one shard by its testbench and
configuration: core-runtime (ocp_core_tb with the runtime configurations rcNN and runtime parameters rpNN),
core-configs (ocp_core_tb with the configurations cNN) and rest (every other test, among them the random
configurations rNN of ocp_core_tb and all other testbenches). The shards take about the same simulation time; the CI
runs one job per shard: python run.py -p 4 $(python tools/ci_shard.py <shard>).
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHARDS = ("core-runtime", "core-configs", "rest")


def shard_of(test):
    """The shard of a test name (library.testbench.configuration.test)."""
    parts = test.split(".")
    if len(parts) >= 4 and parts[1] == "ocp_core_tb":
        if re.fullmatch(r"r[cp]\d\d\w*", parts[2]):
            return "core-runtime"
        if re.fullmatch(r"c\d\d\w*", parts[2]):
            return "core-configs"
    return "rest"


def all_tests():
    """Every test of the regression, from run.py --list (no compilation; own output directory)."""
    with tempfile.TemporaryDirectory() as out:
        res = subprocess.run([sys.executable, str(ROOT / "run.py"), "--list", "--output-path", out], cwd=ROOT,
                             capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if res.returncode != 0:
        sys.exit(f"run.py --list failed:\n{res.stdout}{res.stderr}")
    tests = [line.strip() for line in res.stdout.splitlines() if line.startswith("opencompact.")]
    listed = re.search(r"^Listed (\d+) tests", res.stdout, re.MULTILINE)
    if not listed or int(listed.group(1)) != len(tests):
        sys.exit("run.py --list: the number of test names does not match the listed count")
    return tests


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in SHARDS + ("--check",):
        sys.exit(f"usage: python tools/ci_shard.py <{'|'.join(SHARDS)}> | --check")
    tests = all_tests()
    if sys.argv[1] == "--check":
        shards = {s: [t for t in tests if shard_of(t) == s] for s in SHARDS}
        union = [t for s in SHARDS for t in shards[s]]
        for s in SHARDS:
            print(f"{s:14} {len(shards[s]):4d} tests")
        empty = [s for s in SHARDS if not shards[s]]
        if sorted(union) != sorted(tests) or len(set(union)) != len(union) or empty:
            sys.exit("the shards do not cover every test exactly once" + (f" (empty: {empty})" if empty else ""))
        print(f"{len(tests)} tests, every test in exactly one shard")
        return 0
    print("\n".join(t for t in tests if shard_of(t) == sys.argv[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
