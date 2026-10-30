# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Memories of ocp_core in the GHDL netlist against the resource estimate (tools/ocp_estimate.py).

Synthesises ocp_core with GHDL for every case of ocp_estimate.check_cases() and collects the inferred memories of the
netlist: every variable mem_v_type (array (0 to N) of std_logic_vector (W downto 0)) of an entity of olo_base_ram_sdp,
the RAM of olo_ft_ram_sdp and olo_ft_fifo_sync, with its instances counted through the hierarchy from the top level.
The multiset of (depth, stored width) of every case must equal that of ocp_estimate.memories(). With --write the
script writes the memories of the netlists to tools/tests/golden_memories.json (with names: those cases, merged into
the file), which the tests of the estimate (tools/tests/test_ocp_estimate.py) compare with the estimate; run it again
after a change of the memories of the RTL.

Usage: python lint/memory_check.py [--write] [name ...]
Uses the libraries compiled by the regression runner (run `python run.py --compile` first).
Exit code 0 when the memories of every case equal the estimate.
"""

import collections
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIBS = ROOT / "vunit_out" / "ghdl" / "libraries"
GOLDEN = ROOT / "tools" / "tests" / "golden_memories.json"
sys.path.insert(0, str(ROOT / "tools"))
import ocp_configs  # noqa: E402
import ocp_estimate  # noqa: E402
import ocp_wrapper  # noqa: E402


def netlist(name, generics, tmp):
    """GHDL netlist of ocp_core with the generics of a case (wrapper of tools/ocp_wrapper.py)."""
    work = Path(tmp) / name
    work.mkdir()
    # The wrapper takes the generics of the case in place of those of the configuration; the interface width also
    # sets its ports
    top = work / "ocp_synth_top.vhd"
    top.write_text(ocp_wrapper.wrapper(ocp_configs.cfg(), out_width=generics.get("OutWidth_g", 32), extra=generics),
                   encoding="utf-8")
    common = ["--std=08", "-frelaxed", f"-P{LIBS / 'olo'}", f"-P{LIBS / 'opencompact'}", f"--workdir={work}"]
    subprocess.run(["ghdl", "-a"] + common + [str(top)], check=True, stdin=subprocess.DEVNULL)
    res = subprocess.run(["ghdl", "--synth"] + common + ["ocp_synth_top"], capture_output=True, text=True,
                         stdin=subprocess.DEVNULL)
    if res.returncode != 0:
        raise RuntimeError(f"{name}: synthesis failed: {res.stderr[-400:]}")
    return res.stdout


def netlist_memories(text):
    """Multiset of (depth, width) of the inferred memories, instances counted from ocp_synth_top."""
    ents = {}
    cur = None
    lines = text.splitlines()
    for i, line in enumerate(lines):
        m = re.match(r"\s*architecture \w+ of (\S+) is", line)
        if m:
            cur = m.group(1)
            ents[cur] = {"mems": [], "children": collections.Counter()}
            continue
        if cur is None:
            continue
        m = re.match(r"\s*type mem_v_type is array \(0 to (\d+)\)", line)
        if m:
            w = re.match(r"\s*of std_logic_vector \((\d+) downto 0\);", lines[i + 1])
            ents[cur]["mems"].append((int(m.group(1)) + 1, int(w.group(1)) + 1))
            continue
        m = re.search(r":\s*entity work\.([\w.]+)", line)
        if m:
            ents[cur]["children"][m.group(1)] += 1
    total = collections.Counter()

    def walk(ent, k):
        for mem in ents[ent]["mems"]:
            total[mem] += k
        for child, n in ents[ent]["children"].items():
            if child in ents:
                walk(child, k * n)

    walk("ocp_synth_top", 1)
    return total


def main():
    args = sys.argv[1:]
    write = "--write" in args
    names = [a for a in args if a != "--write"]
    cases = ocp_estimate.check_cases()
    unknown = [n for n in names if n not in cases]
    if unknown:
        raise SystemExit("unknown cases: " + ", ".join(unknown))
    golden = []
    fails = 0
    with tempfile.TemporaryDirectory(dir=LIBS.parent.parent) as tmp:
        for name in names or sorted(cases):
            g = cases[name]
            got = netlist_memories(netlist(name, g, tmp))
            est = collections.Counter((m["depth"], m["codeword"]) for m in ocp_estimate.memories(g))
            ok = got == est
            fails += not ok
            bits = sum(d * w * k for (d, w), k in got.items())
            print(f"{name:34s} {'ok  ' if ok else 'DIFF'} {bits:9d} bits stored" +
                  ("" if ok else f"  netlist only {dict(got - est)}, estimate only {dict(est - got)}"), flush=True)
            golden.append({"name": name, "memories": sorted([d, w, k] for (d, w), k in got.items())})
    if write:
        # With names the entries of these cases replace or join those of the file; the file keeps only cases that
        # exist
        merged = {e["name"]: e for e in json.loads(GOLDEN.read_text(encoding="utf-8"))} if names else {}
        merged.update({e["name"]: e for e in golden})
        out = [merged[n] for n in sorted(merged) if n in cases]
        GOLDEN.write_text(json.dumps(out, indent=1) + "\n", encoding="utf-8", newline="\n")
        print(f"wrote {GOLDEN.relative_to(ROOT)} ({len(out)} cases)")
    print(f"{len(golden)} cases, {fails} differ from the estimate")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
