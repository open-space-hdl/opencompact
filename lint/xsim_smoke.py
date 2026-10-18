# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Smoke test of OpenCompact in the AMD Vivado simulator (xsim).

Compiles Open Logic and OpenCompact with xvhdl (VHDL-2008) and elaborates the top levels of the synthesis check
(lint/synth_check.py): ocp_core in every configuration of tools/ocp_configs.py, without and with the image framing
(UseInLast_g), ocp_input_adapter and ocp_channel in the configurations of their testbenches, and one channel with the
dimensions of a reference system. Every top level is simulated for 1 us: clock period 10 ns, reset for the first
100 ns, every other input '0' and every ready input '1'. A top level passes when it elaborates and the simulation
reaches 1 us without an error.

Usage: python lint/xsim_smoke.py [name ...]
Without names all top levels are run; names select some of them (a core configuration with the image framing is named
<configuration>_in_last). The Vivado tools come from VIVADO_PATH (the Vivado installation) or from the PATH. Output
in vivado_out/xsim_smoke.
Exit code 0 when every top level passes.
"""

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "vivado_out" / "xsim_smoke"
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "lint"))
import ocp_configs  # noqa: E402
import ocp_wrapper  # noqa: E402
import synth_check  # noqa: E402

# Open Logic areas of the library olo (as in run.py)
OLO_AREAS = ("base", "axi", "intf", "ft")

# Simulated time and reset
RUN_NS = 1000
RESET_NS = 100
END_MARK = "XSIM_SMOKE_END"


def tool(name):
    """Path of a Vivado tool (the batch wrapper on Windows)."""
    exe = name + (".bat" if os.name == "nt" else "")
    if "VIVADO_PATH" in os.environ:
        return str(Path(os.environ["VIVADO_PATH"]) / "bin" / exe)
    found = shutil.which(exe)
    if not found:
        raise SystemExit("Vivado not found: set VIVADO_PATH to the Vivado installation or put its bin on the PATH")
    return found


def run(cmd, log):
    with open(OUT / log, "w") as out:
        return subprocess.run(cmd, cwd=OUT, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT).returncode


def compile_libraries():
    """Compiles Open Logic into olo and the OpenCompact sources into opencompact."""
    lines = []
    for rel in (ROOT / "open-logic" / "compile_order.txt").read_text().splitlines():
        rel = rel.strip()
        if rel and rel.split("/")[1] in OLO_AREAS:
            lines.append('vhdl2008 olo "{}"'.format((ROOT / "open-logic" / rel).as_posix()))
    for rel in (ROOT / "compile_order.txt").read_text().splitlines():
        if rel.strip():
            lines.append('vhdl2008 opencompact "{}"'.format((ROOT / rel.strip()).as_posix()))
    (OUT / "libraries.prj").write_text("\n".join(lines) + "\n", encoding="utf-8")
    if run([tool("xvhdl"), "-prj", "libraries.prj"], "compile_libraries.log") != 0:
        raise SystemExit("compilation of the libraries failed, see " + str(OUT / "compile_libraries.log"))


def forces(text):
    """Tcl forces of the inputs of a top level: clock, reset, ready inputs '1', all other inputs '0'."""
    cmds = []
    for name, vector in re.findall(r"^\s*(\w+)\s*:\s*in\s+std_logic(_vector)?", text, re.MULTILINE):
        path = "/ocp_synth_top/" + name
        if name == "Clk":
            cmds.append("add_force {%s} {0 0ns} {1 5ns} -repeat_every 10ns" % path)
        elif name == "Rst":
            continue
        elif vector:
            cmds.append("add_force {%s} -radix hex 0" % path)
        else:
            cmds.append("add_force {%s} %d" % (path, 1 if name.endswith("Ready") else 0))
    return cmds


def smoke(name, text):
    """Elaborates and simulates one top level."""
    (OUT / f"{name}.vhd").write_text(text, encoding="utf-8")
    ok = run([tool("xvhdl"), "--2008", "-L", "olo", "-L", "opencompact", f"{name}.vhd"], f"{name}_compile.log") == 0
    if ok:
        ok = run([tool("xelab"), "--debug", "off", "-L", "olo", "-L", "opencompact", "--snapshot", name,
                  "xil_defaultlib.ocp_synth_top"], f"{name}_elaborate.log") == 0
    log = OUT / f"{name}_simulate.log"
    if ok:
        tcl = forces(text) + ["add_force {/ocp_synth_top/Rst} 1", f"run {RESET_NS} ns",
                              "add_force {/ocp_synth_top/Rst} 0", f"run {RUN_NS - RESET_NS} ns",
                              f"puts \"{END_MARK} [current_time]\"", "quit"]
        (OUT / f"{name}.tcl").write_text("\n".join(tcl) + "\n", encoding="utf-8")
        run([tool("xsim"), name, "-tclbatch", f"{name}.tcl", "-log", log.name], f"{name}_xsim.log")
        sim = log.read_text(errors="replace") if log.exists() else ""
        errors = [line for line in sim.splitlines() if re.search(r"\b(ERROR|FATAL|Failure)\b", line)]
        ok = END_MARK in sim and not errors
    else:
        errors = []
    print(f"{name}: {'OK' if ok else 'FAILED'}", flush=True)
    for line in errors[:5]:
        print("  " + line)
    return ok


def top_levels():
    """Name and VHDL text of every top level."""
    tops = {}
    for n, config in ocp_configs.ALL.items():
        width = synth_check.out_width(n)
        tops[n] = lambda c=config, w=width: ocp_wrapper.wrapper(c, out_width=w)
        tops[n + "_in_last"] = lambda c=config, w=width: ocp_wrapper.wrapper(c, out_width=w, use_in_last=True)
    for n, (w, d, u) in synth_check.ADAPTER.items():
        masks = {"last_mask": 0x3FC000, "last_value": 0x004000, "error_mask": 0x003000} if u == 22 else {}
        tops[n] = lambda w=w, d=d, u=u, m=masks: ocp_wrapper.adapter_wrapper(w, d, u, **m)
    for n, (config, in_w, out_w, stream_w) in synth_check.CHANNEL.items():
        tops[n] = lambda c=config, i=in_w, o=out_w, s=stream_w: ocp_wrapper.channel_wrapper(c, i, o, s)
    # Channel of a reference system: c26 with an image of 64 x 64 x 48 samples, 32-bit words, 128-bit streams
    system = dict(ocp_configs.ALL["c26_tp_bil_near_abs"], large_n_x=64, large_n_y=64, large_n_z=48)
    tops["ch_c26_64x64x48"] = lambda: ocp_wrapper.channel_wrapper(system, 128, 32, 128)
    return tops


def main():
    tops = top_levels()
    names = sys.argv[1:] or list(tops)
    unknown = [n for n in names if n not in tops]
    if unknown:
        raise SystemExit("unknown top levels: " + ", ".join(unknown))
    OUT.mkdir(parents=True, exist_ok=True)
    compile_libraries()
    results = [smoke(n, tops[n]()) for n in names]
    print(f"{sum(results)} of {len(results)} top levels passed", flush=True)
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
