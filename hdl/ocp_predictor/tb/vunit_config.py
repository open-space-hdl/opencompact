# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""VUnit configurations of ocp_predictor_tb: one per configuration of tools/ocp_configs.py (ALL: the configurations
and the random configurations), plus back pressure.

When the environment variable OCP_TESTVECTORS names a directory prepared by tools/ocp_testvectors.py, one
configuration per test vector of the CCSDS test data set is added (tv_<number>), with the throughput check; every
fourth also with back pressure.

ocp_predictor_tb (test_runtime): the image sequences of the runtime configurations (RUNTIME of tools/ocp_configs.py)
and of the runtime parameter configurations (RUNTIME_PARAMS), also with back pressure.

ocp_image_start_tb (test_sweep): the latencies and flags of the runtime configurations (RUNTIME of
tools/ocp_configs.py) and of configurations that cover the remaining combinations of order, sample representatives
and local sums.
"""

import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools"))
import ocp_configs  # noqa: E402
import ocp_generics  # noqa: E402
import ocp_throughput  # noqa: E402

# Configurations that also run with random gaps at the input and stalls at the output (with the speculative weight
# loop: c25, c26)
BACK_PRESSURE = ["c01_lossless_bip", "c05_near_rel_bi4_signed", "c10_periodic_limits", "c25_tp_bsq_lossless",
                 "c26_tp_bil_near_abs"]

# Strong output stalls: the output buffer and the output FIFO of the stride order fill (c29, c30); the output FIFO
# is full when the error limit values of an update period are due (c35)
STALL = ["c29_tp_bip_near_stride", "c30_tp_bip_both_stride", "c35_small_bil_periodic_spec"]

# Configurations of the speculative weight loop that also run without it (Speculation_g = false): one band, BSQ and
# BIL, lossless and near-lossless, periodic error limit updating
NO_SPECULATION = ["c13_single_band_hybrid", "c25_tp_bsq_lossless", "c26_tp_bil_near_abs", "c28_tp_bsq_near_abs",
                  "c35_small_bil_periodic_spec"]

# Image-start sequencer: further configurations (BI with sub-frames and near-lossless compression, BSQ near-lossless,
# narrow local sums with damping)
START = ["c04_near_abs_hybrid", "c05_near_rel_bi4_signed", "c28_tp_bsq_near_abs", "c03_lossless_bsq_narrow",
         "c30_tp_bip_both_stride"]

# Points beyond the sweep: the maxima of the dimensions, factors at and around the saturation, a single pixel
START_EXTRA = [(65536, 65536, 65536), (65536, 1, 1), (1, 65536, 1), (1, 1, 65536), (1, 1, 1), (4097, 2, 3),
               (2, 4097, 65535), (129, 129, 2), (300, 1, 100)]


def add(tb, name, cfg, golden_dir, back_pressure=False):
    all_generics = ocp_generics.generics(cfg)
    gen = {k: all_generics[k] for k in ocp_generics.PREDICTOR}
    gen["GoldenDir_g"] = golden_dir.as_posix()
    # Without back pressure the samples are accepted in the cycles of the throughput model
    tb.add_config(name=name, generics=dict(gen, ExpCycles_g=ocp_throughput.issue_span(all_generics),
                                           ExpOutCycles_g=ocp_throughput.output_span(all_generics)))
    if back_pressure or name in BACK_PRESSURE:
        tb.add_config(name=name + "_bp", generics=dict(gen, InGapPct_g=30, OutStallPct_g=40))
    if name in STALL:
        tb.add_config(name=name + "_stall", generics=dict(gen, OutStallPct_g=80))
    if name in NO_SPECULATION:
        tb.add_config(name=name + "_nospec", generics=dict(
            gen, Speculation_g=False, ExpCycles_g=ocp_throughput.issue_span(all_generics, speculation=False),
            ExpOutCycles_g=ocp_throughput.output_span(all_generics, speculation=False)))


def add_start(test, name, cfg, runtime_m=False):
    """A configuration of the image-start sequencer test: the flags and latencies of the predictor of cfg; with
    runtime_m every M of an image from In_M (runtime parameters)."""
    g = ocp_generics.generics(cfg)
    s = ocp_throughput.start_params(g)
    test.add_config(name=name, generics=dict(
        Bsq_g=s["bsq"], SubFrameDepth_g=s["sfd"], PredBands_g=s["p"], RepIsSample_g=s["rep_is_sample"],
        WUsed_g=s["w_used"], CrossRep_g=s["cross_rep"], LWin_g=s["l_win"], LRep_g=s["l_rep"], LDw_g=s["l_dw"],
        XMax_g=64, ZMax_g=max(2 * s["sfd"], 8) if not s["bsq"] else 8,
        Extra_g=",".join("{},{},{}".format(*p) for p in START_EXTRA), RuntimeM_g=runtime_m))


def add_runtime(test, name, cfg, params=False):
    """A runtime configuration (TC-PR-41; with params a runtime parameter configuration, TC-PR-42): the image
    sequence of tb/golden/<name>; without back pressure the first sample of every image and the last sample are
    accepted in the cycles of the throughput model (with the M of every image), with back pressure only the results
    are checked."""
    all_generics = ocp_generics.generics(cfg)
    gen = {k: all_generics[k] for k in ocp_generics.PREDICTOR}
    seq = [line.split() for line in (ROOT / "tb" / "golden" / name / "runtime.txt").read_text().splitlines()]
    # With the runtime parameters in BI order the M taken (column 21) is the M of the image
    with_m = params and all_generics["EncodingOrder_g"] == "BI"
    dims = [tuple(int(v) for v in values[5:8]) + ((int(values[21]),) if with_m else ()) for values in seq]
    # The testbench takes one item per cycle at the output of the predictor (no entropy coder, no coder tail)
    cycles = ocp_throughput.runtime_accept_cycles(all_generics, dims, tail=False)
    starts, k = [], 0
    for dim in dims:
        starts.append(cycles[k] - cycles[0])
        k += dim[0] * dim[1] * dim[2]
    gen.update(GoldenDir_g=(ROOT / "tb" / "golden" / name).as_posix(), RuntimeConfig_g=True, RtImages_g=len(seq))
    if params:
        gen["RuntimeParams_g"] = True
    test.add_config(name=name, generics=dict(gen, ExpCycles_g=cycles[-1] - cycles[0],
                                             ExpStarts_g=",".join(str(v) for v in starts)))
    test.add_config(name=name + "_bp", generics=dict(gen, InGapPct_g=30, OutStallPct_g=60))


def configure(lib):
    tb = lib.test_bench("ocp_predictor_tb")
    golden = tb.test("test_golden")
    for name, cfg in ocp_configs.ALL.items():
        add(golden, name, cfg, ROOT / "tb" / "golden" / name)

    runtime = tb.test("test_runtime")
    for name, cfg in ocp_configs.RUNTIME.items():
        add_runtime(runtime, name, cfg)
    for name, cfg in ocp_configs.RUNTIME_PARAMS.items():
        add_runtime(runtime, name, cfg, params=True)

    sweep = lib.test_bench("ocp_image_start_tb").test("test_sweep")
    for name, cfg in ocp_configs.RUNTIME.items():
        add_start(sweep, name, cfg)
    # Runtime parameters: every M of an image (BI order)
    for name, cfg in ocp_configs.RUNTIME_PARAMS.items():
        if cfg["sample_encoding_order"] == 0:
            add_start(sweep, name, cfg, runtime_m=True)
    # Every M of an image in lossless BI order with prediction bands (no dependency on the sample representatives of
    # the previous band): the distance of the local differences of the previous sub-frame decides with M < NZ
    add_start(sweep, "c01_lossless_bip_runtime_m", ocp_configs.ALL["c01_lossless_bip"], runtime_m=True)
    for name in START:
        add_start(sweep, name, ocp_configs.ALL[name])
    # No prediction bands (P = 0): the distance of the local differences of the band before does not apply
    add_start(sweep, "c03_lossless_bsq_narrow_p0", dict(ocp_configs.ALL["c03_lossless_bsq_narrow"], large_p=0))

    # Test vectors of the CCSDS test data set
    tv_dir = os.environ.get("OCP_TESTVECTORS")
    if tv_dir:
        tv_dir = Path(tv_dir)
        for n, name in enumerate(json.loads((tv_dir / "index.json").read_text())):
            add(golden, name, json.loads((tv_dir / name / "config.json").read_text()), tv_dir / name, n % 4 == 3)
