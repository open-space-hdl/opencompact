# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""VUnit configurations of the testbenches of ocp_core.

ocp_core_tb:

- test_golden: one configuration per configuration of tools/ocp_configs.py (the configurations of CONFIGS and the
  random configurations of RANDOM), some also with back pressure, and long sequences of small images with input
  gaps and output stalls
- test_ecc: error injection into every memory of the configurations of ECC (together all memories of the core)
- test_reset: resets at random times for the configurations of RESET

When the environment variable OCP_TESTVECTORS names a directory prepared by tools/ocp_testvectors.py, test_golden
also runs one configuration per test vector of the CCSDS test data set (tv_<number>).

ocp_bit_packer_tb:

- test_random: interface widths and output word sizes with random codewords
- test_byte_order: the position of every byte in the interface word and the valid bytes of the last word
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

# Configurations that also run with random gaps at the input and stalls at the output
BACK_PRESSURE = ["c01_lossless_bip", "c04_near_abs_hybrid", "c06_near_both_block", "c10_periodic_limits"]

# Interface widths: in turn over the configurations, 32 bits for the throughput configurations
WIDTHS = [8, 16, 32, 64]

# Throughput configurations: the core accepts the samples of both images in the cycles of the predictor model
THROUGHPUT = ["c25_tp_bsq_lossless", "c26_tp_bil_near_abs", "c27_tp_bip_full", "c28_tp_bsq_near_abs"]

# Error injection and resets at random times: small images; together the configurations have every memory of the
# core, every coder, BSQ and BI order, periodic error limits and the stride order (and the tail of the hybrid coder
# of a single-pixel image)
ECC = ["c31_small_bi_periodic_abs", "c32_small_bip_periodic_rel", "c33_small_bip_stride_block",
       "c34_small_bsq_lossless"]
RESET = ECC + ["c22_single_pixel_hybrid"]

# Sequences of small images (number of images) with input gaps and output stalls: several images wait for their
# header while the bit packer still takes the body of an earlier image, and an image starts in the cycle in which the
# header of a waiting image starts
SEQUENCE = {"c22_single_pixel_hybrid": 100, "c31_small_bi_periodic_abs": 10, "c34_small_bsq_lossless": 20}

IMAGES = 2


def configure(lib):
    tb = lib.test_bench("ocp_core_tb")
    golden = tb.test("test_golden")
    ecc = tb.test("test_ecc")
    reset = tb.test("test_reset")
    channels = set()
    for n, (name, cfg) in enumerate(ocp_configs.ALL.items()):
        gen = ocp_generics.generics(cfg)
        gen["GoldenDir_g"] = (ROOT / "tb" / "golden" / name).as_posix()
        gen["Images_g"] = IMAGES
        gen["OutWidth_g"] = 32 if name in THROUGHPUT else WIDTHS[n % len(WIDTHS)]
        exp = ocp_throughput.issue_span(gen, images=IMAGES) if name in THROUGHPUT else 0
        if name in ocp_configs.RANDOM and n % 3 == 0:
            # Every third random configuration runs with back pressure only
            golden.add_config(name=name, generics=dict(gen, InGapPct_g=30, OutStallPct_g=60))
        else:
            golden.add_config(name=name, generics=dict(gen, ExpCycles_g=exp))
        if name in BACK_PRESSURE:
            golden.add_config(name=name + "_bp", generics=dict(gen, InGapPct_g=30, OutStallPct_g=60))
        if name in SEQUENCE:
            golden.add_config(name=name + "_seq", generics=dict(gen, Images_g=SEQUENCE[name], InGapPct_g=20,
                                                                 OutStallPct_g=70))
        if name in ECC:
            ch = ocp_throughput.ecc_channels(gen)
            channels |= set(ch)
            ecc.add_config(name=name, generics=dict(gen, EccChannels_g=",".join(str(c) for c in ch)))
        if name in RESET:
            reset.add_config(name=name, generics=dict(gen, InGapPct_g=10, OutStallPct_g=20))
    missing = set(ocp_throughput.ECC_CHANNELS) - channels
    assert not missing, "error injection: no configuration with the memories {}".format(sorted(missing))

    # Bit packer: interface widths and output word sizes; without back pressure, with back pressure and with small
    # images under sink stalls (several image ends queued in the packer)
    pk = lib.test_bench("ocp_bit_packer_tb")
    rnd = pk.test("test_random")
    for n, (width, size) in enumerate([(8, 1), (8, 3), (16, 2), (16, 5), (32, 1), (32, 4), (32, 7), (64, 1),
                                       (64, 3), (64, 8)]):
        base = dict(OutWidth_g=width, OutputWordSize_g=size, Seed_g=n + 1)
        rnd.add_config(name="w{}_b{}".format(width, size), generics=base)
        rnd.add_config(name="w{}_b{}_bp".format(width, size), generics=dict(base, InGapPct_g=20, OutStallPct_g=50))
        rnd.add_config(name="w{}_b{}_small".format(width, size),
                       generics=dict(base, Images_g=200, MaxCodewords_g=3, OutStallPct_g=80))

    # Byte order: every interface width with a partial last word, and one with fill bytes in it
    order = pk.test("test_byte_order")
    for width, size in [(8, 1), (16, 1), (32, 1), (64, 1), (32, 3)]:
        order.add_config(name="w{}_b{}".format(width, size), generics=dict(OutWidth_g=width, OutputWordSize_g=size))

    # Test vectors of the CCSDS test data set (every fourth with back pressure)
    tv_dir = os.environ.get("OCP_TESTVECTORS")
    if tv_dir:
        tv_dir = Path(tv_dir)
        for n, name in enumerate(json.loads((tv_dir / "index.json").read_text())):
            cfg = json.loads((tv_dir / name / "config.json").read_text())
            gen = ocp_generics.generics(cfg)
            gen["GoldenDir_g"] = (tv_dir / name).as_posix()
            gen["Images_g"] = IMAGES
            gen["OutWidth_g"] = WIDTHS[n % len(WIDTHS)]
            if n % 4 == 3:
                gen.update(InGapPct_g=30, OutStallPct_g=60)
            golden.add_config(name=name, generics=gen)
