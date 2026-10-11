# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""VUnit configurations of ocp_core_tb: one per configuration of tools/ocp_configs.py, plus back pressure."""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools"))
import ocp_configs  # noqa: E402
import ocp_generics  # noqa: E402
import ocp_throughput  # noqa: E402

# Configurations that also run with random gaps at the input and stalls at the output
BACK_PRESSURE = ["c01_lossless_bip", "c04_near_abs_hybrid", "c06_near_both_block", "c10_periodic_limits"]

# Interface widths: in turn over the configurations, 32 bits for the throughput configurations
WIDTHS = [8, 16, 32, 64]

# Throughput configurations: the core accepts the samples of both images in the cycles of the predictor model
THROUGHPUT = ["c25_hp_bsq_lossless", "c26_hp_bil_near_abs", "c27_hp_bip_full", "c28_hp_bsq_near_abs"]

IMAGES = 2


def configure(lib):
    tb = lib.test_bench("ocp_core_tb")
    for n, (name, cfg) in enumerate(ocp_configs.CONFIGS.items()):
        gen = ocp_generics.generics(cfg)
        gen["GoldenDir_g"] = (ROOT / "tb" / "golden" / name).as_posix()
        gen["Images_g"] = IMAGES
        gen["OutWidth_g"] = 32 if name in THROUGHPUT else WIDTHS[n % len(WIDTHS)]
        exp = ocp_throughput.issue_span(gen, images=IMAGES) if name in THROUGHPUT else 0
        tb.add_config(name=name, generics=dict(gen, ExpCycles_g=exp))
        if name in BACK_PRESSURE:
            tb.add_config(name=name + "_bp", generics=dict(gen, InGapPct_g=30, OutStallPct_g=60))
