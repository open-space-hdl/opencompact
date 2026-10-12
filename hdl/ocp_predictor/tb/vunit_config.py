# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""VUnit configurations of ocp_predictor_tb: one per configuration of tools/ocp_configs.py (ALL: the configurations
and the random configurations), plus back pressure.

When the environment variable OCP_TESTVECTORS names a directory prepared by tools/ocp_testvectors.py, one
configuration per test vector of the CCSDS test data set is added (tv_<number>), with the throughput check; every
fourth also with back pressure.
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


def configure(lib):
    tb = lib.test_bench("ocp_predictor_tb")
    for name, cfg in ocp_configs.ALL.items():
        add(tb, name, cfg, ROOT / "tb" / "golden" / name)

    # Test vectors of the CCSDS test data set
    tv_dir = os.environ.get("OCP_TESTVECTORS")
    if tv_dir:
        tv_dir = Path(tv_dir)
        for n, name in enumerate(json.loads((tv_dir / "index.json").read_text())):
            add(tb, name, json.loads((tv_dir / name / "config.json").read_text()), tv_dir / name, n % 4 == 3)
