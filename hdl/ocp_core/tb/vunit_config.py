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
- test_framing: images with an early or a missing In_Last between correct images, then resets at random times, for
  the configurations of FRAMING (every encoding order and coder, the stride order, periodic error limits, all
  interface widths, some with back pressure)
- test_runtime, test_runtime_timing, test_runtime_range, test_runtime_queue: the runtime configurations (RUNTIME,
  RuntimeConfig_g) and the runtime parameter configurations (RUNTIME_PARAMS, RuntimeParams_g)

Every configuration of test_golden, test_ecc and test_reset also runs with the image framing (UseInLast_g, suffix
_last): In_Last on the last sample of every image; without it In_Last is random and ignored.

When the environment variable OCP_TESTVECTORS names a directory prepared by tools/ocp_testvectors.py, test_golden
also runs one configuration per test vector of the CCSDS test data set (tv_<number>, also with the suffix _last).

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
import golden as golden_tool  # noqa: E402
import ocp_configs  # noqa: E402
import ocp_generics  # noqa: E402
import ocp_model  # noqa: E402
import ocp_throughput  # noqa: E402

# Configurations that also run with random gaps at the input and stalls at the output
BACK_PRESSURE = ["c01_lossless_bip", "c04_near_abs_hybrid", "c06_near_both_block", "c10_periodic_limits"]

# Interface widths: in turn over the configurations, 32 bits for the throughput configurations
WIDTHS = [8, 16, 32, 64]

# Throughput configurations: the core accepts the samples of both images in the cycles of the predictor model
THROUGHPUT = ["c25_tp_bsq_lossless", "c26_tp_bil_near_abs", "c27_tp_bip_full", "c28_tp_bsq_near_abs"]

# Image period: the first sample of the second image is accepted exactly image_period cycles after the first sample
# of the first image. Every coder without and with the stride order, at one sample per cycle and at lower rates, and
# with periodic error limit updating
PERIOD = ["c03_lossless_bsq_narrow", "c25_tp_bsq_lossless", "c29_tp_bip_near_stride", "c05_near_rel_bi4_signed",
          "c26_tp_bil_near_abs", "c04_near_abs_hybrid", "c30_tp_bip_both_stride", "c07_lossless_block_bsq",
          "c27_tp_bip_full", "c06_near_both_block", "c33_small_bip_stride_block", "c35_small_bil_periodic_spec"]

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

# Image framing (small images): configuration, interface width, back pressure (input gaps in percent, twice as many
# output stalls). Together: BSQ, BIL, BIP and BI order with sub-frames, the stride order, the speculative weight loop,
# periodic error limits, the three coders (the tail of the hybrid coder), output word sizes from 1 to 8
FRAMING = [("c22_single_pixel_hybrid", 8, 30), ("c31_small_bi_periodic_abs", 8, 0), ("r01_random", 8, 0),
           ("c32_small_bip_periodic_rel", 16, 0), ("c37_block_d32_custom", 16, 0), ("r04_random", 16, 30),
           ("c33_small_bip_stride_block", 32, 0), ("c35_small_bil_periodic_spec", 32, 0), ("r13_random", 32, 30),
           ("c34_small_bsq_lossless", 64, 0), ("r22_random", 64, 0), ("r08_random", 64, 30),
           ("c29_tp_bip_near_stride", 16, 0), ("c30_tp_bip_both_stride", 64, 30),
           ("r21_random", 8, 0), ("c26_tp_bil_near_abs", 32, 0)]

IMAGES = 2

# Sequences of images of the hybrid coder without back pressure (number of images): the tail of every image can hold
# back the next image through the output FIFO of the predictor; the first sample of every image is accepted in the
# cycle of the throughput model (TC-CO-50, CO-TP-01). Single-pixel images, small images at 1.33 cycles per sample and
# images at one sample per cycle
RATE = {"c22_single_pixel_hybrid": 20, "c20_hybrid_d28": 6, "c26_tp_bil_near_abs": 8}

# Runtime configurations of the timing test (TC-CO-53)
RUNTIME_TIMING = ["rc01_bi_m1_sample", "rc04_bi_m4_sample_both"]


def runtime_generics(name, cfg, rt_list="runtime"):
    """Generics of a runtime configuration: the maxima, the image list <rt_list>.txt, 64-bit words (the output does
    not limit the input)."""
    gen = ocp_generics.generics(cfg)
    golden = ROOT / "tb" / "golden" / name
    gen.update(GoldenDir_g=golden.as_posix(), RuntimeConfig_g=True, OutWidth_g=64,
               RtImages_g=len((golden / (rt_list + ".txt")).read_text().splitlines()),
               MaxBytes_g=ocp_model.max_image_bytes(cfg), HeaderBytes_g=len(ocp_model.header(cfg)))
    if rt_list != "runtime":
        gen["RtList_g"] = rt_list
    return gen


def runtime_dims(name, gen):
    """Dimensions (nx, ny, nz) taken for every image of runtime.txt; with the runtime parameters in BI order also
    the M taken (column 21: after the driven and taken configuration and the driven parameters)."""
    seq = [line.split() for line in (ROOT / "tb" / "golden" / name / "runtime.txt").read_text().splitlines()]
    with_m = gen.get("RuntimeParams_g", False) and gen["EncodingOrder_g"] == "BI"
    return [tuple(int(v) for v in values[5:8]) + ((int(values[21]),) if with_m else ()) for values in seq]


def runtime_starts(name, gen):
    """Acceptance cycles of the first sample of every image of runtime.txt relative to the first (throughput
    model)."""
    dims = runtime_dims(name, gen)
    cycles = ocp_throughput.runtime_accept_cycles(gen, dims)
    starts, k = [], 0
    for dim in dims:
        starts.append(cycles[k] - cycles[0])
        k += dim[0] * dim[1] * dim[2]
    return ",".join(str(v) for v in starts)


def add(test, name, generics):
    """A configuration without and with the image framing (suffix _last)."""
    test.add_config(name=name, generics=generics)
    test.add_config(name=name + "_last", generics=dict(generics, UseInLast_g=True))


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
        gen["MaxBytes_g"] = ocp_model.max_image_bytes(cfg)
        gen["OutWidth_g"] = 32 if name in THROUGHPUT else WIDTHS[n % len(WIDTHS)]
        exp = ocp_throughput.issue_span(gen, images=IMAGES) if name in THROUGHPUT else 0
        period = ocp_throughput.image_period(gen) if name in PERIOD else 0
        if name in ocp_configs.RANDOM and n % 3 == 0:
            # Every third random configuration runs with back pressure only
            add(golden, name, dict(gen, InGapPct_g=30, OutStallPct_g=60))
        else:
            add(golden, name, dict(gen, ExpCycles_g=exp, ExpPeriod_g=period))
        if name in BACK_PRESSURE:
            add(golden, name + "_bp", dict(gen, InGapPct_g=30, OutStallPct_g=60))
        if name in RATE:
            n_img = RATE[name]
            n = gen["XSize_g"] * gen["YSize_g"] * gen["ZSize_g"]
            cycles = ocp_throughput.issue_cycles(gen, images=n_img)
            starts = ",".join(str(cycles[k * n] - cycles[0]) for k in range(n_img))
            add(golden, name + "_rate", dict(gen, Images_g=n_img, OutWidth_g=64, ExpStarts_g=starts))
        if name in SEQUENCE:
            add(golden, name + "_seq", dict(gen, Images_g=SEQUENCE[name], InGapPct_g=20, OutStallPct_g=70))
        if name in ECC:
            ch = ocp_throughput.ecc_channels(gen)
            channels |= set(ch)
            add(ecc, name, dict(gen, EccChannels_g=",".join(str(c) for c in ch)))
        if name in RESET:
            add(reset, name, dict(gen, InGapPct_g=10, OutStallPct_g=20))
    missing = set(ocp_throughput.ECC_CHANNELS) - channels
    assert not missing, "error injection: no configuration with the memories {}".format(sorted(missing))

    # Runtime configurations: the image sequences (TC-CO-52, TC-CO-54), every second configuration also with input
    # gaps and output stalls; the timing test (TC-CO-53); the range test (TC-CO-57)
    runtime = tb.test("test_runtime")
    for n, (name, cfg) in enumerate(ocp_configs.RUNTIME.items()):
        gen = runtime_generics(name, cfg)
        add(runtime, name, dict(gen, ExpStarts_g=runtime_starts(name, gen)))
        if n % 2 == 1:
            add(runtime, name + "_bp", dict(gen, InGapPct_g=30, OutStallPct_g=60))
    timing = tb.test("test_runtime_timing")
    for name in RUNTIME_TIMING:
        add(timing, name, runtime_generics(name, ocp_configs.RUNTIME[name]))
    rng = tb.test("test_runtime_range")
    for name in ocp_configs.RUNTIME_RANGE:
        gen = runtime_generics(name, ocp_configs.RUNTIME[name])
        lines = (ROOT / "tb" / "golden" / name / "range.txt").read_text().splitlines()
        add(rng, name, dict(gen, RtList_g="range", RtImages_g=len(lines)))
    # Queue test (TC-CO-58): the configuration queue full while the output is held low
    queue = tb.test("test_runtime_queue")
    for name, cfg in ocp_configs.queue_configs().items():
        add(queue, name, runtime_generics(name, cfg, "queue"))

    # Runtime parameters: the image sequences with the parameters of every image, back to back and with input gaps
    # and output stalls (TC-CO-59), the range test (TC-CO-60), the queue test (TC-CO-61)
    for name, cfg in ocp_configs.RUNTIME_PARAMS.items():
        gen = dict(runtime_generics(name, cfg), RuntimeParams_g=True)
        add(runtime, name, dict(gen, ExpStarts_g=runtime_starts(name, gen)))
        add(runtime, name + "_bp", dict(gen, InGapPct_g=30, OutStallPct_g=60))
        lines = (ROOT / "tb" / "golden" / name / "range.txt").read_text().splitlines()
        add(rng, name, dict(gen, RtList_g="range", RtImages_g=len(lines)))
        if name in ocp_configs.RUNTIME_PARAMS_QUEUE:
            add(queue, name, dict(runtime_generics(name, cfg, "queue"), RuntimeParams_g=True))
        # The output held after the header and some body bytes of a larger first image: the queue fills behind the
        # read pointer of the sample-adaptive or the block-adaptive coder while the header pointer has passed it
        if name in ocp_configs.RUNTIME_PARAMS_QUEUE_HOLD:
            gen = dict(runtime_generics(name, cfg, "queuehold"), RuntimeParams_g=True)
            add(queue, name + "_hold", dict(gen, QueueHoldBytes_g=gen["HeaderBytes_g"] + ocp_configs.QUEUE_HOLD_BODY))

    framing = tb.test("test_framing")
    for name, width, bp in FRAMING:
        cfg = ocp_configs.ALL[name]
        gen = ocp_generics.generics(cfg)
        gen.update(GoldenDir_g=(ROOT / "tb" / "golden" / name).as_posix(), OutWidth_g=width, UseInLast_g=True,
                   HeaderBytes_g=len(ocp_model.header(cfg)), InGapPct_g=bp, OutStallPct_g=2 * bp,
                   MaxBytes_g=ocp_model.max_image_bytes(cfg),
                   AbortPos_g=",".join(str(p) for p in golden_tool.abort_positions(name, cfg)))
        framing.add_config(name=name, generics=gen)

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
            gen["MaxBytes_g"] = ocp_model.max_image_bytes(cfg)
            gen["OutWidth_g"] = WIDTHS[n % len(WIDTHS)]
            if n % 4 == 3:
                gen.update(InGapPct_g=30, OutStallPct_g=60)
            add(golden, name, gen)
