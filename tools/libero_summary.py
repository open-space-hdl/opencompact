# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Summary of the Libero results of tools/synth_libero.py as a Markdown table.

Usage: python tools/libero_summary.py [device] [--json FILE]
Reads libero_out/<device>/<configuration>/: the Synplify report (resources, estimated frequency) and, after place
and route, the SmartTime report (frequency of the register-to-register paths).
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def field(text, pattern, default="-"):
    m = re.search(pattern, text, re.MULTILINE)
    return m.group(1) if m else default


def results(device):
    """The results of every configuration in libero_out/<device>/ with a Synplify report: name, LUT, flip-flops,
    LSRAM, uSRAM, math blocks, synthesis estimate and place and route frequency (MHz, None without), the Synplify
    build and the date of the run."""
    rows = []
    for cfg in sorted((ROOT / "libero_out" / device).iterdir()):
        srr = cfg / "prj" / "synthesis" / "ocp_synth_top.srr"
        if not srr.exists():
            continue
        t = srr.read_text(errors="replace")
        rpt = cfg / "max_timing.rpt"
        pr = field(rpt.read_text(errors="replace"), r"Frequency \(MHz\):\s+([\d.]+)") if rpt.exists() else "-"
        rows.append({
            "name": cfg.name,
            "lut": int(field(t, r"^Total LUTs:\s+(\d+)", "0")),
            "ff": int(field(t, r"^SLE\s+(\d+) uses", "0")),
            "lsram": int(field(t, r"Total Block RAMs \(RAM1K20\) : (\d+)", "0")),
            "usram": int(field(t, r"Total Block RAMs \(RAM64x12\) : (\d+)", "0")),
            "math": int(field(t, r"^DSP Blocks:\s+(\d+)", "0")),
            "fmax_synth": float(field(t, r"^Clk\s+[\d.]+ MHz\s+([\d.]+) MHz", "0")) or None,
            "fmax_pr": float(pr) if pr != "-" else None,
            "tool": field(t, r"^#Build: (.+?),", ""),
            "date": field(t, r"^# (\w{3} \w{3} +\d+ [\d:]+ \d{4})", ""),
        })
    return rows


def main():
    args = sys.argv[1:]
    out_json = None
    if "--json" in args:
        i = args.index("--json")
        out_json = args[i + 1]
        del args[i:i + 2]
    device = args[0] if args else "polarfire"
    rows = results(device)
    if out_json:
        Path(out_json).write_text(json.dumps(rows, indent=1) + "\n", encoding="utf-8", newline="\n")
        return
    print("| Configuration | LUT | Flip-flops | LSRAM | uSRAM | Math blocks | Synthesis estimate (MHz) | Place and route (MHz) |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- |")
    for r in rows:
        cells = [r["name"]] + [str(r[k]) for k in ("lut", "ff", "lsram", "usram", "math")]
        cells += [str(r[k]) if r[k] else "-" for k in ("fmax_synth", "fmax_pr")]
        print("| " + " | ".join(cells) + " |")


if __name__ == "__main__":
    main()
