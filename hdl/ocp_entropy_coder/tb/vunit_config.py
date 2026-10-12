# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""VUnit configurations of ocp_entropy_coder_tb: one per configuration of tools/ocp_configs.py (ALL), every second
with random source gaps and sink stalls; hybrid configurations also with strong sink stalls.

When the environment variable OCP_TESTVECTORS names a directory prepared by tools/ocp_testvectors.py, one
configuration per test vector of the CCSDS test data set is added (tv_<number>).
"""

import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools"))
import ocp_configs  # noqa: E402
import ocp_generics  # noqa: E402
import ocp_model  # noqa: E402

# Generics of the entropy coder testbench (subset of the core generics)
CODER = [
    "XSize_g", "YSize_g", "ZSize_g", "DynamicRange_g", "OutputWordSize_g", "EntropyCoder_g", "AbsBitDepth_g",
    "RelBitDepth_g", "UnaryLimit_g", "RescaleCounterSize_g", "InitialCountExp_g", "AccuInitBandVarying_g",
    "AccuInit_g", "HybridAccuInit_g", "HybridAccuInitHigh_g", "BlockSize_g", "RestrictedCodes_g", "RefInterval_g",
]

# Strong sink stalls: the codeword FIFO of the hybrid coder fills during the samples (high-entropy codes, D = 28) and
# during the tail (48 bands)
STALL = ["c20_hybrid_d28", "c30_tp_bip_both_stride"]


def add(tb, n, name, cfg, golden_dir):
    all_generics = ocp_generics.generics(cfg)
    gen = {k: all_generics[k] for k in CODER}
    gen["GoldenDir_g"] = golden_dir.as_posix()
    gen["HeaderBytes_g"] = len(ocp_model.header(cfg))
    if name in STALL:
        tb.add_config(name=name + "_stall", generics=dict(gen, OutStallPct_g=90))
    if n % 2:
        gen.update(InGapPct_g=20, OutStallPct_g=50)
    tb.add_config(name=name, generics=gen)


def configure(lib):
    tb = lib.test_bench("ocp_entropy_coder_tb")
    for n, (name, cfg) in enumerate(ocp_configs.ALL.items()):
        add(tb, n, name, cfg, ROOT / "tb" / "golden" / name)

    # Test vectors of the CCSDS test data set
    tv_dir = os.environ.get("OCP_TESTVECTORS")
    if tv_dir:
        tv_dir = Path(tv_dir)
        for n, name in enumerate(json.loads((tv_dir / "index.json").read_text())):
            add(tb, n, name, json.loads((tv_dir / name / "config.json").read_text()), tv_dir / name)
