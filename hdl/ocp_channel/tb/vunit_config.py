# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""VUnit configurations of ocp_channel_tb.

Configurations with D = 8, 12, 14, 16, 18, 20 and 32 (containers of 1 to 4 bytes) and the three coders; SDU streams of 8 to
128 bits, with the input converter at integer and non-integer ratios and without converter (one container per beat);
the output converter up to 128 bits, down to 8 bits and without converter (OutWidth_g = OutStreamWidth_g). Every configuration runs
test_golden and, without periodic error limit updating, test_errors; some with input gaps and output stalls.
test_ecc and test_reset run one configuration.
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools"))
import golden as golden_tool  # noqa: E402
import ocp_configs  # noqa: E402
import ocp_generics  # noqa: E402
import ocp_model  # noqa: E402
import ocp_throughput  # noqa: E402

# name: (InStreamWidth_g, OutWidth_g, OutStreamWidth_g, back pressure)
CONFIGS = {
    "r08_random": (8, 8, 128, False),                  # D 8: one container per beat
    "c36_block_j64_spikes": (128, 64, 128, False),     # D 12: 128 to 16 bits
    "r09_random": (16, 32, 32, True),                  # D 16: one container per beat, no output converter
    "r17_random": (64, 16, 64, False),                 # D 20: 64 to 24 bits (non-integer ratio)
    "c37_block_d32_custom": (32, 64, 64, True),        # D 32: one container per beat, no output converter
    "c33_small_bip_stride_block": (128, 8, 16, True),  # D 16, stride order
    "c32_small_bip_periodic_rel": (32, 16, 128, True),  # D 14, periodic error limits (test_golden only)
    "r24_random": (128, 32, 8, True),                  # D 18: 128 to 24 bits; output 32 to 8 bits (downsizing)
}
ECC = "c37_block_d32_custom"
RESET = "r09_random"
# Runtime configuration (TC-CH-07): BI with sub-frames, absolute and relative error limits
RUNTIME = ["rc04_bi_m4_sample_both"]


def configure(lib):
    tb = lib.test_bench("ocp_channel_tb")
    for name, (in_w, out_w, stream_w, bp) in CONFIGS.items():
        cfg = ocp_configs.ALL[name]
        gen = ocp_generics.generics(cfg)
        gen.update({"GoldenDir_g": (ROOT / "tb" / "golden" / name).as_posix(),
                    "HeaderBytes_g": len(ocp_model.header(cfg)),
                    "AbortPos_g": ",".join(str(p) for p in golden_tool.abort_positions(name, cfg)),
                    "InStreamWidth_g": in_w, "OutWidth_g": out_w, "OutStreamWidth_g": stream_w})
        if bp:
            gen.update({"InGapPct_g": 30, "OutStallPct_g": 50})
        tb.test("test_golden").add_config(name=name, generics=gen)
        if not gen["PeriodicUpdate_g"]:
            tb.test("test_errors").add_config(name=name, generics=gen)
        if name == ECC:
            channels = ocp_throughput.ecc_channels(gen)[:2]
            tb.test("test_ecc").add_config(name=name, generics=dict(gen, EccChannels_g=",".join(map(str, channels))))
        if name == RESET:
            tb.test("test_reset").add_config(name=name, generics=gen)

    # Runtime configuration through the AXI4-Lite port (TC-CH-07)
    for name in RUNTIME:
        cfg = ocp_configs.RUNTIME[name]
        gen = ocp_generics.generics(cfg)
        gen.update({"GoldenDir_g": (ROOT / "tb" / "golden" / name).as_posix(), "RuntimeConfig_g": True,
                    "HeaderBytes_g": len(ocp_model.header(cfg)), "InStreamWidth_g": 64, "OutWidth_g": 32,
                    "OutStreamWidth_g": 64})
        tb.test("test_runtime").add_config(name=name, generics=gen)
