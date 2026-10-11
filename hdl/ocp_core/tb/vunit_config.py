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

# Configurations that also run with random gaps at the input and stalls at the output
BACK_PRESSURE = ["c01_lossless_bip", "c04_near_abs_hybrid", "c06_near_both_block", "c10_periodic_limits"]


def configure(lib):
    tb = lib.test_bench("ocp_core_tb")
    for name, cfg in ocp_configs.CONFIGS.items():
        gen = ocp_generics.generics(cfg)
        gen["GoldenDir_g"] = (ROOT / "tb" / "golden" / name).as_posix()
        tb.add_config(name=name, generics=gen)
        if name in BACK_PRESSURE:
            tb.add_config(name=name + "_bp", generics=dict(gen, InGapPct_g=30, OutStallPct_g=60))
