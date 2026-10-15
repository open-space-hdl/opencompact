# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Synthesis check of OpenCompact with GHDL (TC-CO-48).

Synthesises ocp_core with the generics of every configuration of tools/ocp_configs.py, each with the interface width
of the core testbench; synthesises the bounds of the generic ranges that no configuration of the regression reaches
(BOUNDS); and checks that every configuration outside the ranges of the standard stops the elaboration with its
message (NEGATIVE).

Usage: python lint/synth_check.py [--in-last] [name ...]
Without names all configurations of ALL, BOUNDS and NEGATIVE are checked; names select some of them. With --in-last
the configurations of ALL and BOUNDS are elaborated with the image framing (UseInLast_g).
Uses the libraries compiled by the regression runner (run `python run.py --compile` first).
Exit code 0 when every configuration synthesizes without error and without inferred latch, and every configuration of
NEGATIVE stops with its message.
This is a technology-independent check of synthesizability; resources and timing need the FPGA tools.
"""

import importlib.util
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
from ocp_configs import cfg  # noqa: E402

# Interface widths of the core testbench (in turn over the configurations, 32 bits for the throughput configurations)
_spec = importlib.util.spec_from_file_location("ocp_core_vunit_config", ROOT / "hdl/ocp_core/tb/vunit_config.py")
_core_tb = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_core_tb)

# Bounds of the generic ranges that no configuration of the regression reaches: configuration, interface width and
# further generics of ocp_core. Image dimensions of 65536 with the other dimensions at 1 keep the memories small.
BOUNDS = {
    "b01_x_65536": (cfg(large_n_x=65536, large_n_y=2, large_n_z=1, large_m=1, large_d=8, large_p=0), 8, {}),
    "b02_y_65536": (cfg(large_n_x=1, large_n_y=65536, large_n_z=1, large_m=1, large_d=8, large_p=0,
                        prediction_mode=1, local_sum_type=2), 16, {}),
    "b03_z_m_65536": (cfg(large_n_x=1, large_n_y=1, large_n_z=65536, large_m=65536, large_d=8, large_p=3,
                          prediction_mode=1, local_sum_type=2), 64, {}),
    "b04_bsq_z_65536": (cfg(large_n_x=1, large_n_y=2, large_n_z=65536, sample_encoding_order=1, large_m=0,
                            large_d=8, large_p=3, prediction_mode=1, local_sum_type=2), 8, {}),
    "b05_no_speculation": (ocp_configs.ALL["c25_tp_bsq_lossless"], 32, {"Speculation_g": False}),
    "b06_ram_style_block": (ocp_configs.ALL["c01_lossless_bip"], 16, {"RamStyle_g": "block"}),
}

# Configurations outside the ranges of the standard: configuration, interface width, further generics and the message
# that stops the elaboration
_BLOCK = ocp_configs.ALL["c36_block_j64_spikes"]
_SAMPLE = ocp_configs.ALL["c01_lossless_bip"]
NEGATIVE = {
    "n01_block_size_12": (dict(_BLOCK, large_j=12), 32, {}, "BlockSize_g must be 8, 16, 32 or 64"),
    "n02_sub_frame_depth": (dict(_SAMPLE, large_m=_SAMPLE["large_n_z"] + 1), 32, {},
                            "SubFrameDepth_g must be 1 to ZSize_g"),
    "n03_restricted_d5": (dict(_BLOCK, large_d=5, restricted_code_options_flag=1), 32, {},
                          "RestrictedCodes_g requires DynamicRange_g <= 4"),
    "n04_rescale_counter": (dict(_SAMPLE, gamma_0=4, gamma_star=4), 32, {},
                            "RescaleCounterSize_g must be max(4, InitialCountExp_g + 1) to 11"),
    "n05_accu_init": (dict(_SAMPLE, large_d=8, large_r=32, large_omega=16, k_prime_prime_vector=[7]), 32, {},
                      "AccuInit_g values must be 0 to min(DynamicRange_g - 2, 14)"),
    "n06_out_width_12": (_SAMPLE, 12, {}, "OutWidth_g must be 8, 16, 32 or 64"),
    "n07_width_1_full": (dict(_SAMPLE, large_n_x=1), 32, {}, "images of width 1 need reduced prediction"),
    "n08_register_size": (dict(_SAMPLE, large_omega=19, large_r=36), 32, {}, "RegisterSize_g must be at least"),
    "n09_vmin_vmax": (dict(_SAMPLE, v_min=4, v_max=3), 32, {}, "WeightUpdateVmin_g must not exceed"),
    "n10_periodic_bsq": (dict(ocp_configs.ALL["c28_tp_bsq_near_abs"], periodic_updating_flag=1), 32, {},
                         "periodic error limit updating is not allowed with BSQ order"),
}


def out_width(name):
    if name in _core_tb.THROUGHPUT:
        return 32
    return _core_tb.WIDTHS[list(ocp_configs.ALL).index(name) % len(_core_tb.WIDTHS)]


def synth(name, config, width, extra, out_dir, use_in_last=False, expect=None):
    """Synthesises one configuration; with expect, the elaboration must stop with that message."""
    work = out_dir / name
    work.mkdir()
    top = work / "ocp_synth_top.vhd"
    top.write_text(ocp_wrapper.wrapper(config, out_width=width, use_in_last=use_in_last, extra=extra),
                   encoding="utf-8")
    common = ["--std=08", "-frelaxed", f"-P{LIBS / 'olo'}", f"-P{LIBS / 'opencompact'}", f"--workdir={work}"]
    res = subprocess.run(["ghdl", "-a"] + common + [str(top)], capture_output=True, text=True)
    log = res.stdout + res.stderr
    if res.returncode == 0:
        with open(work / "netlist.vhd", "w") as netlist:
            res = subprocess.run(["ghdl", "--synth"] + common + ["ocp_synth_top"], stdout=netlist,
                                 stderr=subprocess.PIPE, text=True)
        log += res.stderr
    (work / "netlist.vhd").unlink(missing_ok=True)
    if expect:
        ok = res.returncode != 0 and expect in log
        print(f"{name}: {'stops as expected' if ok else 'FAILED (expected: ' + expect + ')'}", flush=True)
        return ok
    # Inferred latches are reported as "latch" warnings
    latches = [line for line in log.splitlines() if re.search(r"\blatch\b", line, re.IGNORECASE)]
    errors = [line for line in log.splitlines() if re.search(r":error:|GHDL Bug|[Ee]xception", line)]
    ok = res.returncode == 0 and not latches and not errors
    print(f"{name} ({width} bit): {'OK' if ok else 'FAILED'}", flush=True)
    for line in (errors + latches)[:20]:
        print("  " + line)
    return ok


def main():
    if not LIBS.exists():
        raise SystemExit("compiled libraries not found, run: python run.py --compile")
    args = sys.argv[1:]
    in_last = "--in-last" in args
    names = [a for a in args if a != "--in-last"] or list(ocp_configs.ALL) + list(BOUNDS) + list(NEGATIVE)
    results = []
    with tempfile.TemporaryDirectory(dir=LIBS.parent.parent) as tmp:
        for n in names:
            if n in ocp_configs.ALL:
                results.append(synth(n, ocp_configs.ALL[n], out_width(n), {}, Path(tmp), in_last))
            elif n in BOUNDS:
                config, width, extra = BOUNDS[n]
                results.append(synth(n, config, width, extra, Path(tmp), in_last))
            elif n in NEGATIVE and not in_last:
                config, width, extra, message = NEGATIVE[n]
                results.append(synth(n, config, width, extra, Path(tmp), expect=message))
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
