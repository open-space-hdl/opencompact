# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""VUnit configurations of ocp_predictor_tb: one per configuration of tools/ocp_configs.py, plus back pressure."""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools"))
import ocp_configs  # noqa: E402
import ocp_generics  # noqa: E402
import ocp_throughput  # noqa: E402

# Configurations that also run with random gaps at the input and stalls at the output
BACK_PRESSURE = ["c01_lossless_bip", "c05_near_rel_bi4_signed", "c10_periodic_limits"]


def configure(lib):
    tb = lib.test_bench("ocp_predictor_tb")
    for name, cfg in ocp_configs.CONFIGS.items():
        all_generics = ocp_generics.generics(cfg)
        gen = {k: all_generics[k] for k in ocp_generics.PREDICTOR}
        gen["GoldenDir_g"] = (ROOT / "tb" / "golden" / name).as_posix()
        # Without back pressure the samples are accepted in the cycles of the throughput model
        tb.add_config(name=name, generics=dict(gen, ExpCycles_g=ocp_throughput.issue_span(all_generics),
                                               ExpOutCycles_g=ocp_throughput.output_span(all_generics)))
        if name in BACK_PRESSURE:
            tb.add_config(name=name + "_bp", generics=dict(gen, InGapPct_g=30, OutStallPct_g=40))
