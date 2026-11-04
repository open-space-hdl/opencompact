# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Out-of-context implementation of OpenCompact in Vivado: resources and timing at a target clock frequency.

For every selected configuration the script writes a top level (the synthesis top level of tools/ocp_wrapper.py with
its clock through a global clock buffer) and runs lint/vivado_ooc.tcl in Vivado: out-of-context synthesis, placement
and routing with a clock of the target frequency on the core clock, then the timing summary, the utilization, the 20
worst setup paths and the logic level distribution. Only register-to-register paths are timed; the ports of the core
have no input or output delays.

Configurations (short names, also the names of the result files):
  rs_sce  ocp_channel of the reference system spfi_compress_encrypt: 64 x 64 x 48 samples, D = 16, BI with M = 48,
          P = 3, full prediction, wide neighbor-oriented local sums, R = 32, sample-adaptive coder, 32-bit words,
          128-bit streams
  c01     ocp_core, c01_lossless_bip of tools/ocp_configs.py
  c11     ocp_core, c11_wide_d32 of tools/ocp_configs.py (D = 32, the longest arithmetic)
  rc04    ocp_core, rc04_bi_m4_sample_both of tools/ocp_configs.py with the runtime configuration

Usage: python lint/vivado_ooc.py [--out DIR] [--temp DIR] [--mhz MHZ] [--part PART] [--elaborate] [name ...]
  --out        project and result directory (default: the environment variable OCP_OOC_OUT; one of the two is
               required). On Windows give a short path such as C:/ooc: Vivado projects need short paths
  --temp       directory of the temporary files of Vivado: TEMP, TMP and TMPDIR of the Vivado process (default
               <out>/tmp)
  --mhz        target clock frequency (default 200)
  --part       device (default xcvc1902-vsva2197-2MP-e-S, the Versal AI Core device of the VCK190)
  --elaborate  RTL elaboration only: sources, generics, top level and clock constraint; no synthesis or
               implementation
Without names all configurations run. The Vivado tools come from VIVADO_PATH (the Vivado installation) or from the
PATH. Results: <out>/results/<name>_timing.rpt, _util.rpt, _paths.rpt, _levels.rpt and <out>/results/summary.md.
Exit code 0 when every run completed; the timing result itself is in the summary.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import ocp_configs  # noqa: E402
import ocp_wrapper  # noqa: E402
from ocp_configs import cfg  # noqa: E402

PART = "xcvc1902-vsva2197-2MP-e-S"

# The ocp_channel instance i_ocp0 of systems/spfi_compress_encrypt/hdl/spfi_compress_encrypt.vhd of reference-systems
# (Speculation_g and RamStyle_g at their defaults, as there)
RS_SCE = cfg(large_n_x=64, large_n_y=64, large_n_z=48, large_d=16, sample_encoding_order=0, large_m=48, large_b=4,
             large_p=3, prediction_mode=0, local_sum_type=0, large_omega=13, large_r=32, log_two_t_inc=6, v_min=-1,
             v_max=3, entropy_coder_type=0, large_u_max=18, gamma_star=6, gamma_0=1, k_prime_prime_vector=[4])

CONFIGS = {
    "rs_sce": lambda: ocp_wrapper.channel_wrapper(RS_SCE, 128, 32, 128),
    "c01": lambda: ocp_wrapper.wrapper(ocp_configs.ALL["c01_lossless_bip"], out_width=32, use_in_last=True),
    "c11": lambda: ocp_wrapper.wrapper(ocp_configs.ALL["c11_wide_d32"], out_width=32, use_in_last=True),
    # Runtime configuration: range limitation, image-start sequencer, configuration queue, header fields
    "rc04": lambda: ocp_wrapper.wrapper(ocp_configs.RUNTIME["rc04_bi_m4_sample_both"], out_width=32,
                                        use_in_last=True, extra={"RuntimeConfig_g": True}),
}


def ooc_top(text):
    """The synthesis top level with its clock input ClkIn through a global clock buffer (the clock net is routed
    on global clock routing, as in a system)."""
    port = re.compile(r"^(\s+)Clk(\s+):(\s+in\s+std_logic;)$", re.MULTILINE)
    if len(port.findall(text)) != 1:
        raise SystemExit("top level without exactly one clock port Clk")
    text = port.sub(lambda m: m.group(1) + "ClkIn" + m.group(2)[2:] + ":" + m.group(3), text)
    arch = re.search(r"^architecture rtl of ocp_synth_top is\nbegin\n", text, re.MULTILINE)
    if not arch:
        raise SystemExit("top level without the expected architecture")
    # BUFG: Vivado maps it to the global clock buffer of the device (it has no device generic to set)
    buf = ("architecture rtl of ocp_synth_top is\n"
           "    signal Clk : std_logic;\n"
           "begin\n\n"
           "    i_clk_buf : BUFG\n"
           "        port map (\n"
           "            I => ClkIn,\n"
           "            O => Clk\n"
           "        );\n\n")
    text = text[:arch.start()] + buf + text[arch.end():]
    return text.replace("library opencompact;", "library unisim;\n    use unisim.vcomponents.all;\n\nlibrary opencompact;",
                        1)


def vivado():
    exe = "vivado" + (".bat" if os.name == "nt" else "")
    if "VIVADO_PATH" in os.environ:
        return str(Path(os.environ["VIVADO_PATH"]) / "bin" / exe)
    found = shutil.which(exe)
    if not found:
        raise SystemExit("Vivado not found: set VIVADO_PATH to the Vivado installation or put its bin on the PATH")
    return found


def run(name, out, temp, mhz, part, elaborate):
    work = out / name
    work.mkdir(parents=True, exist_ok=True)
    top = work / "ocp_ooc_top.vhd"
    top.write_text(ooc_top(CONFIGS[name]()), encoding="utf-8")
    period = "{:.3f}".format(1000.0 / mhz)
    # Positional arguments: the batch wrapper of vivado splits arguments at "="
    args = [vivado(), "-mode", "batch", "-nojournal", "-log", str(work / "vivado.log"),
            "-source", str(ROOT / "lint" / "vivado_ooc.tcl"), "-tclargs",
            name, top.as_posix(), work.as_posix(), (out / "results").as_posix(), period, part,
            "elaborate" if elaborate else "implement", ROOT.as_posix()]
    print(f"{name}: {'elaboration' if elaborate else 'implementation'} at {mhz} MHz in {work}", flush=True)
    env = dict(os.environ, TEMP=str(temp), TMP=str(temp), TMPDIR=str(temp))
    rc = subprocess.run(args, cwd=work, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL).returncode
    print(f"{name}: {'completed' if rc == 0 else 'FAILED (see ' + str(work / 'vivado.log') + ')'}", flush=True)
    return rc == 0


def summary(out, names, mhz):
    """Collects the result lines of the runs into results/summary.md."""
    res = out / "results"
    lines = [f"# OpenCompact out-of-context implementation at {mhz} MHz", "",
             "| Configuration | WNS (ns) | TNS (ns) | Failing endpoints | WHS (ns) | LUT | FF | RAMB36 | RAMB18 | URAM | DSP |",
             "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for n in names:
        f = res / f"{n}_summary.txt"
        lines.append(f.read_text(encoding="utf-8").strip() if f.exists() else f"| {n} | no result | | | | | | | | | |")
    (res / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--out", default=os.environ.get("OCP_OOC_OUT"))
    p.add_argument("--temp")
    p.add_argument("--mhz", type=float, default=200.0)
    p.add_argument("--part", default=PART)
    p.add_argument("--elaborate", action="store_true")
    p.add_argument("names", nargs="*")
    a = p.parse_args()
    if not a.out:
        p.error("no output directory: give --out DIR or set OCP_OOC_OUT (on Windows a short path such as C:/ooc)")
    names = a.names or list(CONFIGS)
    unknown = [n for n in names if n not in CONFIGS]
    if unknown:
        raise SystemExit("unknown configurations: " + ", ".join(unknown) + " (known: " + ", ".join(CONFIGS) + ")")
    out = Path(a.out)
    (out / "results").mkdir(parents=True, exist_ok=True)
    temp = Path(a.temp) if a.temp else out / "tmp"
    temp.mkdir(parents=True, exist_ok=True)
    results = [run(n, out, temp, a.mhz, a.part, a.elaborate) for n in names]
    if not a.elaborate:
        summary(out, names, a.mhz)
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
