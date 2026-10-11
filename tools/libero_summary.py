# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Summary of the Libero results of tools/synth_libero.py as a Markdown table.

Usage: python tools/libero_summary.py [device]
Reads libero_out/<device>/<configuration>/: the Synplify report (resources, estimated frequency) and, after place
and route, the SmartTime report (frequency of the register-to-register paths).
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def field(text, pattern, default="-"):
    m = re.search(pattern, text, re.MULTILINE)
    return m.group(1) if m else default


def main():
    device = sys.argv[1] if len(sys.argv) > 1 else "polarfire"
    rows = []
    for cfg in sorted((ROOT / "libero_out" / device).iterdir()):
        srr = cfg / "prj" / "synthesis" / "ocp_synth_top.srr"
        if not srr.exists():
            continue
        t = srr.read_text(errors="replace")
        luts = field(t, r"^Total LUTs:\s+(\d+)")
        sle = field(t, r"^SLE\s+(\d+) uses")
        lsram = field(t, r"Total Block RAMs \(RAM1K20\) : (\d+)")
        usram = field(t, r"Total Block RAMs \(RAM64x12\) : (\d+)")
        dsp = field(t, r"^DSP Blocks:\s+(\d+)", "0")
        est = field(t, r"^Clk\s+[\d.]+ MHz\s+([\d.]+) MHz")
        rpt = cfg / "max_timing.rpt"
        pr = field(rpt.read_text(errors="replace"), r"Frequency \(MHz\):\s+([\d.]+)") if rpt.exists() else "-"
        rows.append((cfg.name, luts, sle, lsram, usram, dsp, est, pr))
    print("| Configuration | LUT | Flip-flops | LSRAM | uSRAM | Math blocks | Synthesis estimate (MHz) | Place and route (MHz) |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- |")
    for r in rows:
        print("| " + " | ".join(r) + " |")


if __name__ == "__main__":
    main()
