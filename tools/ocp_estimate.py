# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Resource estimate of ocp_core from its generics.

memories(g) lists every memory of ocp_core for the generics g (the names of the VHDL generics, as
ocp_generics.generics() gives them): the name, the error injection channel, the depth, the data width and the width
of the stored SECDED codeword (olo_ft_ram_sdp, olo_ft_fifo_sync). The sizes mirror the constants of the RTL
(ocp_predictor, the entropy coders, ocp_cw_buffer), the existence of every memory the generate conditions
(ocp_throughput.ecc_channels()). ram_bits(g) sums them, with and without the check bits. The numbers do not depend on
the FPGA vendor; how a synthesis tool maps a memory (block RAM, distributed RAM, registers) does.

The throughput (cycles per sample, image period) is computed by tools/ocp_throughput.py.

Usage: python tools/ocp_estimate.py [configuration ...]
"""

import math
import sys

import ocp_configs
import ocp_generics
import ocp_throughput

# Codeword buffer of the entropy coders (ocp_pkg)
CW_WIDTH = 96
CW_LEN_WIDTH = 7
# Depth of the codeword buffer FIFO (ocp_sample_adaptive_coder, ocp_hybrid_coder, ocp_block_adaptive_coder)
CW_FIFO_DEPTH = 16


def ecc_codeword_width(width):
    """Width of the SECDED codeword of a data word (eccCodewordWidth of olo_ft_pkg_ecc): the data bits, the Hamming
    parity bits and one overall parity bit."""
    r = 1
    while 2 ** r < width + r + 1:
        r += 1
    return width + r + 1


def log2ceil(n):
    return max(math.ceil(math.log2(n)), 0) if n > 1 else 0


def memories(g):
    """The memories of ocp_core for the generics g: a list of dicts with name, channel (ErrInj_Channel), depth,
    width (data bits per word) and codeword (stored bits per word)."""
    g = dict(g)
    g.setdefault("Speculation_g", True)
    g.setdefault("RuntimeConfig_g", False)
    g.setdefault("RuntimeParams_g", False)
    nx, ny, nz = g["XSize_g"], g["YSize_g"], g["ZSize_g"]
    d = g["DynamicRange_g"]
    bsq = g["EncodingOrder_g"] == "BSQ"
    p = g["PredictionBands_g"]
    full = g["PredictionMode_g"] == "FULL"
    c1 = max(p + 3 * int(full), 1)
    lat = ocp_throughput.latencies(g, g["Speculation_g"])
    present = set(ocp_throughput.ecc_channels(g))
    st = ocp_throughput.stride_params(g, lat) if not g["RuntimeConfig_g"] else None
    if st is None:
        present -= {9, 10, 11}
    band_slots = 2 if bsq else max(nz, 2)
    diff_bits = max(p, 1) * (d + 3)
    sizes = {
        0: ("sample representatives of the line", max(3 * nx if bsq else nz * nx, 2), d),
        1: ("window of the previous line", band_slots, 2 * d),
        2: ("previous sample representative", band_slots, d),
        3: ("first sample representative of the line", band_slots, d),
        4: ("central local differences", max(nx * ny if bsq else nx, 2), diff_bits),
        5: ("weights", band_slots, c1 * (g["WeightResolution_g"] + 3)),
        6: ("absolute error limits", nz + 1, 16),
        7: ("relative error limits", nz + 1, 16),
        8: ("predictor output FIFO", ocp_throughput.output_fifo_depth(lat), max(d, 16) + 2 + log2ceil(nz + 1) + 3),
        12: ("coder statistics", nz + 1, d + 2 * g["RescaleCounterSize_g"] + 3),
        13: ("codeword FIFO", CW_FIFO_DEPTH, CW_WIDTH + CW_LEN_WIDTH + 1),
    }
    if st is not None:
        m, s, skew = st["m"], st["s"], st["skew"]
        k_ctx = 2 ** log2ceil(s // m + 1)
        sizes[9] = ("stride input buffer", 2 ** log2ceil(skew + m + 8), d)
        sizes[10] = ("stride output buffer", 2 ** log2ceil(skew + 2 * lat["depth"] + 16), d)
        sizes[11] = ("stride local differences", band_slots * k_ctx, diff_bits)
    return [{"name": sizes[ch][0], "channel": ch, "depth": sizes[ch][1], "width": sizes[ch][2],
             "codeword": ecc_codeword_width(sizes[ch][2])} for ch in sorted(present)]


def ram_bits(g):
    """(data bits, stored bits with the SECDED check bits) of all memories of ocp_core."""
    mems = memories(g)
    return sum(m["depth"] * m["width"] for m in mems), sum(m["depth"] * m["codeword"] for m in mems)


def check_cases():
    """The generics of ocp_core for the checks of the estimate (tools/tests, lint/memory_check.py): every
    configuration of tools/ocp_configs.py, the runtime configurations, the runtime parameter configurations, and
    variants without speculation and with the runtime configuration where they change the memories."""
    rt = {"RuntimeConfig_g": True}
    rp = {"RuntimeConfig_g": True, "RuntimeParams_g": True}
    groups = [(ocp_configs.ALL, {}), (ocp_configs.RUNTIME, rt), (ocp_configs.RUNTIME_QUEUE_ONLY, rt),
              (ocp_configs.RUNTIME_PARAMS, rp), (ocp_configs.RUNTIME_PARAMS_SEQUENCE_ONLY, rp),
              (ocp_configs.RUNTIME_PARAMS_QUEUE_ONLY, rp)]
    cases = {}
    for configs, extra in groups:
        for name, c in configs.items():
            cases[name] = dict(ocp_generics.generics(c), **extra)
    # Without the speculative weight loop the weights are kept in memory; with the runtime configuration a
    # configuration of the stride order has no stride buffers
    cases["c25_nospec"] = dict(ocp_generics.generics(ocp_configs.ALL["c25_tp_bsq_lossless"]), Speculation_g=False)
    cases["c29_runtime"] = dict(ocp_generics.generics(ocp_configs.ALL["c29_tp_bip_near_stride"]), **rt)
    return cases


def main():
    names = sys.argv[1:] or list(ocp_configs.ALL)
    for name in names:
        g = ocp_generics.generics(ocp_configs.ALL[name])
        data, stored = ram_bits(g)
        print("{:30s} {:9d} bits of data, {:9d} bits stored ({:.3f} Mbit)".format(name, data, stored, stored / 2 ** 20))
        for m in memories(g):
            print("    {:2d} {:42s} {:6d} x {:4d} ({:4d})".format(m["channel"], m["name"], m["depth"], m["width"],
                                                                 m["codeword"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
