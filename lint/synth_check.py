# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Synthesis check of OpenCompact with GHDL: elaborates ocp_core with the generics of every configuration of
tools/ocp_configs.py.

Usage: python lint/synth_check.py [configuration ...]
Without arguments the named configurations are checked; any configuration of ALL (also the random ones) can be named.
Uses the libraries compiled by the regression runner (run `python run.py --compile` first).
Exit code 0 when every configuration synthesizes without error and without inferred latch.
This is a technology-independent check of synthesizability; resources and timing need the FPGA tools.
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIBS = ROOT / "vunit_out" / "ghdl" / "libraries"
sys.path.insert(0, str(ROOT / "tools"))
import ocp_configs  # noqa: E402
import ocp_wrapper  # noqa: E402


def synth(name, cfg, out_dir):
    work = out_dir / name
    work.mkdir()
    top = work / "ocp_synth_top.vhd"
    top.write_text(ocp_wrapper.wrapper(cfg), encoding="utf-8")
    common = ["--std=08", "-frelaxed", f"-P{LIBS / 'olo'}", f"-P{LIBS / 'opencompact'}", f"--workdir={work}"]
    res = subprocess.run(["ghdl", "-a"] + common + [str(top)], capture_output=True, text=True)
    log = res.stdout + res.stderr
    if res.returncode == 0:
        with open(work / "netlist.vhd", "w") as netlist:
            res = subprocess.run(["ghdl", "--synth"] + common + ["ocp_synth_top"], stdout=netlist,
                                 stderr=subprocess.PIPE, text=True)
        log += res.stderr
    # Inferred latches are reported as "latch" warnings
    latches = [line for line in log.splitlines() if re.search(r"\blatch\b", line, re.IGNORECASE)]
    errors = [line for line in log.splitlines() if re.search(r":error:|GHDL Bug|[Ee]xception", line)]
    ok = res.returncode == 0 and not latches and not errors
    print(f"{name}: {'OK' if ok else 'FAILED'}", flush=True)
    for line in (errors + latches)[:20]:
        print("  " + line)
    return ok


def main():
    if not LIBS.exists():
        raise SystemExit("compiled libraries not found, run: python run.py --compile")
    names = sys.argv[1:] or list(ocp_configs.CONFIGS)
    with tempfile.TemporaryDirectory() as tmp:
        results = [synth(n, ocp_configs.ALL[n], Path(tmp)) for n in names]
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
