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

import json
import math
import sys
from pathlib import Path

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


# Defaults of the generics of ocp_core that a configuration of tools/ocp_configs.py does not set
DEFAULTS = {"RuntimeConfig_g": False, "RuntimeParams_g": False, "Speculation_g": True, "OutWidth_g": 8}


def memories(g):
    """The memories of ocp_core for the generics g: a list of dicts with name, channel (ErrInj_Channel), depth,
    width (data bits per word) and codeword (stored bits per word)."""
    g = dict(DEFAULTS, **g)
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


def quad_products(g):
    """Every product of a local difference (D + 3 bits) and a weight (Omega + 3 bits) has both operands wider than the
    18 bits of a math block, so that it takes four of them."""
    return g["DynamicRange_g"] + 3 > 18 and g["WeightResolution_g"] + 3 > 18


def logic_features(g):
    """Structure features of the logic of ocp_core for the generics g, the inputs of the linear LUT and flip-flop
    model: name -> value. Every feature is a quantity the generics determine (a datapath width times the number of
    its instances, or 1 for a block that exists)."""
    g = dict(DEFAULTS, **g)
    d, om = g["DynamicRange_g"], g["WeightResolution_g"]
    lat = ocp_throughput.latencies(g, g["Speculation_g"])
    c1 = max(lat["c"], 1)
    fid = g["Fidelity_g"]
    qw = max(d, 16) + 2
    stride = not g["RuntimeConfig_g"] and ocp_throughput.stride_params(g, lat) is not None
    coder = g["EntropyCoder_g"]
    return {
        "base": 1,
        "dyn_range": d,
        "products": c1 * (d + om + 12),
        "weights": c1 * (om + 3),
        "cascade": c1 * (d + 3) * (om + 3) if quad_products(g) else 0,
        "register": g["RegisterSize_g"] - 32,
        "quantizer": qw * (d + 16) if fid != "LOSSLESS" else 0,
        "relative": d + 16 if fid in ("RELATIVE", "ABSOLUTE_RELATIVE") else 0,
        "representatives": d + om if not ocp_throughput.rep_equals_sample(g) else 0,
        "stride": d if stride else 0,
        "periodic": 1 if g["PeriodicUpdate_g"] else 0,
        "hybrid": 1 if coder == "HYBRID" else 0,
        "block": d * g["BlockSize_g"] // 8 if coder == "BLOCK_ADAPTIVE" else 0,
        "counters": log2ceil(g["XSize_g"]) + log2ceil(g["YSize_g"]) + log2ceil(g["ZSize_g"]),
        "out_width": g["OutWidth_g"],
        "runtime_config": 1 if g["RuntimeConfig_g"] else 0,
        "runtime_params": 1 if g["RuntimeParams_g"] else 0,
    }


def clock_features(g):
    """Structure features of the critical path of ocp_core for the generics g, the inputs of the linear model of the
    clock period: name -> value."""
    g = dict(DEFAULTS, **g)
    d, om = g["DynamicRange_g"], g["WeightResolution_g"]
    c1 = max(ocp_throughput.latencies(g, g["Speculation_g"])["c"], 1)
    return {
        "base": 1,
        "cascade": 1 if quad_products(g) else 0,
        "block": 1 if g["EntropyCoder_g"] == "BLOCK_ADAPTIVE" else 0,
        "near_lossless": 1 if g["Fidelity_g"] != "LOSSLESS" else 0,
        "wide": c1 * max(d + om - 35, 0),
    }


# The models of every target, fitted by tools/ocp_estimate_fit.py to the calibration file
# tools/tests/calibration_<target>.json: the coefficients of the LUT and flip-flop model for the features of
# logic_features() (one decimal), those of the clock period in picoseconds for the features of clock_features()
# (integers), and the notes on the source and the accuracy. The fit writes them to the JavaScript module
# tools/estimate/ocp_models.mjs (export const MODELS = <JSON>;), which ocp_resources.mjs imports and this module reads.
MODELS_FILE = Path(__file__).resolve().parent / "estimate" / "ocp_models.mjs"


def _load_models():
    if not MODELS_FILE.exists():
        return {}
    text = MODELS_FILE.read_text(encoding="utf-8")
    start = text.index("export const MODELS = ") + len("export const MODELS = ")
    return json.loads(text[start:text.rindex(";")])


MODELS = _load_models()

MEMORY_NOTE = ("Memories: exact for the generics; the sizes of the RTL, checked against the GHDL netlist of every "
               "configuration of the regression. Stored bits include the SECDED check bits.")


def linear_estimate(coef, features):
    """sum(coefficient x feature), rounded to a multiple of 10 (halves up), in integer arithmetic on the coefficients
    in tenths so that the JavaScript port gives the same number."""
    tenths = sum(round(coef[name] * 10) * value for name, value in features.items())
    return (tenths + 50) // 100 * 10


def clock_estimate(coef, features):
    """The clock frequency in MHz (rounded down) for the period sum(coefficient x feature) in picoseconds."""
    period = sum(coef[name] * value for name, value in features.items())
    return 1000000 // period


def estimate_resources(g, target="polarfire"):
    """Resource estimate of ocp_core for the generics g: the bits and the list of the memories, and the logic (LUT,
    flip-flops) and the clock frequency of a target where the model has data for it (None otherwise), with notes on
    the sources and the validity. tools/estimate/ocp_resources.mjs estimateResources() gives the same result."""
    data, stored = ram_bits(g)
    model = MODELS.get(target)
    lut = ff = fmax = None
    if model:
        features = logic_features(g)
        lut = linear_estimate(model["lut"], features)
        ff = linear_estimate(model["ff"], features)
        fmax = clock_estimate(model["period_ps"], clock_features(g))
    return {
        "ramBits": {"data": data, "stored": stored},
        "memories": memories(g),
        "lut": lut,
        "ff": ff,
        "fmaxMHz": fmax,
        "notes": [MEMORY_NOTE] + (model["notes"] if model else ["LUT, flip-flops and clock frequency: no model yet."]),
    }


def _reg(d, om):
    """Register size R at the lower bound of CCSDS 4.7.1: max(32, D + Omega + 2)."""
    return max(32, d + om + 2)


def _base_a(**kw):
    """BIP, lossless, full prediction with P = 3, sample-adaptive coder (like c01)."""
    c = dict(large_n_x=32, large_n_y=12, large_n_z=16, large_d=16, large_m=16, large_b=4, large_p=3, large_omega=13,
             log_two_t_inc=6, v_min=-1, v_max=3, large_u_max=18, gamma_star=6, gamma_0=1, k_prime_prime_vector=[4])
    c.update(kw)
    c.setdefault("large_r", _reg(c["large_d"], c["large_omega"]))
    return ocp_configs.cfg(**c)


def _base_b(**kw):
    """BSQ, near-lossless with an absolute error limit, full prediction with P = 3, block-adaptive coder (J = 16)."""
    c = dict(large_n_x=32, large_n_y=12, large_n_z=8, large_d=16, sample_encoding_order=1, large_m=0, large_b=4,
             large_p=3, large_omega=13, log_two_t_inc=6, v_min=-1, v_max=3, quantizer_fidelity_control_method=1,
             large_d_large_a=6, a_vector=[4], entropy_coder_type=2, large_j=16, r=64)
    c.update(kw)
    c.setdefault("large_r", _reg(c["large_d"], c["large_omega"]))
    return ocp_configs.cfg(**c)


def _base_c(**kw):
    """BIP with M = NZ, near-lossless with an absolute error limit, full prediction with P = 3 (stride order),
    hybrid coder."""
    c = dict(large_n_x=12, large_n_y=6, large_n_z=24, large_d=16, large_m=24, large_b=4, large_p=3, large_omega=13,
             log_two_t_inc=5, v_min=-1, v_max=3, quantizer_fidelity_control_method=1, large_d_large_a=4,
             a_vector=[2], entropy_coder_type=1, large_u_max=16, gamma_star=6, gamma_0=1,
             hybrid_initial_accumulator=[100])
    c.update(kw)
    c.setdefault("large_r", _reg(c["large_d"], c["large_omega"]))
    return ocp_configs.cfg(**c)


def _sweep():
    """Configurations of the synthesis sweep of the resource model: name -> (configuration, further generics of
    ocp_core). Three base configurations, each parameter varied alone, and the configurations of user guide section
    8.2."""
    s = {"sa_base": (_base_a(), {}), "sb_base": (_base_b(), {}), "sc_base": (_base_c(), {})}
    for d in (8, 12, 24, 32):
        s[f"sa_d{d}"] = (_base_a(large_d=d), {})
    for om in (4, 10, 19):
        s[f"sa_om{om}"] = (_base_a(large_omega=om), {})
    for p in (0, 1, 7, 15):
        s[f"sa_p{p}"] = (_base_a(large_p=p), {})
    s["sa_p3_reduced"] = (_base_a(prediction_mode=1), {})
    s["sa_narrow_neighbor"] = (_base_a(local_sum_type=1), {})
    s["sa_wide_column"] = (_base_a(local_sum_type=2), {})
    s["sa_bi_m4"] = (_base_a(large_m=4), {})
    s["sa_bil"] = (_base_a(large_m=1), {})
    s["sa_bsq"] = (_base_a(sample_encoding_order=1, large_m=0), {})
    s["sa_hybrid"] = (_base_a(entropy_coder_type=1, hybrid_initial_accumulator=[100]), {})
    for j in (8, 16, 32, 64):
        s[f"sa_block_j{j}"] = (_base_a(entropy_coder_type=2, large_j=j, r=64), {})
    s["sa_out8"] = (_base_a(), {"OutWidth_g": 8})
    s["sa_out64"] = (_base_a(), {"OutWidth_g": 64})
    s["sa_large"] = (_base_a(large_n_x=128, large_n_y=64, large_n_z=64, large_m=64), {})
    s["sa_small"] = (_base_a(large_n_x=8, large_n_y=8, large_n_z=4, large_m=4), {})
    s["sa_runtime"] = (_base_a(), {"RuntimeConfig_g": True})
    s["sa_runtime_params"] = (_base_a(), {"RuntimeConfig_g": True, "RuntimeParams_g": True})
    # Speculative weight loop: BSQ, lossless, reduced prediction with narrow local sums (like c25)
    spec = _base_a(sample_encoding_order=1, large_m=0, prediction_mode=1, local_sum_type=1, large_n_z=6)
    s["sa_spec"] = (spec, {})
    s["sa_nospec"] = (spec, {"Speculation_g": False})
    s["sb_lossless"] = (_base_b(quantizer_fidelity_control_method=0), {})
    s["sb_rel"] = (_base_b(quantizer_fidelity_control_method=2, large_d_large_r=8, r_vector=[30]), {})
    s["sb_both"] = (_base_b(quantizer_fidelity_control_method=3, large_d_large_r=8, r_vector=[30]), {})
    s["sb_sample_adaptive"] = (_base_b(entropy_coder_type=0, large_u_max=18, gamma_star=6, gamma_0=1,
                                       k_prime_prime_vector=[4]), {})
    s["sb_runtime_params"] = (_base_b(), {"RuntimeConfig_g": True, "RuntimeParams_g": True})
    # Periodic error limit updating: BI with M < NZ (no stride order)
    s["sb_bi_periodic"] = (_base_b(sample_encoding_order=0, large_m=4, periodic_updating_flag=1, u=1), {})
    for nz in (6, 48):
        s[f"sc_nz{nz}"] = (_base_c(large_n_z=nz, large_m=nz), {})
    s["sc_sample_adaptive"] = (_base_c(entropy_coder_type=0, k_prime_prime_vector=[4]), {})
    s["sc_reps"] = (_base_c(sample_representative_flag=1, large_theta=4, phi_vector=[3], psi_vector=[2]), {})
    # Second and third points of the blocks that the variations above add only once or twice
    s["sb_bi_periodic_d24"] = (_base_b(sample_encoding_order=0, large_m=4, periodic_updating_flag=1, u=1, large_d=24),
                               {})
    s["sb_bi_periodic_both"] = (_base_b(sample_encoding_order=0, large_m=4, periodic_updating_flag=1, u=1,
                                        quantizer_fidelity_control_method=3, large_d_large_r=8, r_vector=[30]), {})
    s["sb_runtime"] = (_base_b(), {"RuntimeConfig_g": True})
    s["sc_runtime"] = (_base_c(), {"RuntimeConfig_g": True})
    s["sc_runtime_params"] = (_base_c(), {"RuntimeConfig_g": True, "RuntimeParams_g": True})
    s["sa_spec_d24"] = (_base_a(sample_encoding_order=1, large_m=0, prediction_mode=1, local_sum_type=1, large_n_z=6,
                                large_d=24), {})
    s["sa_spec_p1"] = (_base_a(sample_encoding_order=1, large_m=0, prediction_mode=1, local_sum_type=1, large_n_z=6,
                               large_p=1), {})
    for name in ("c01_lossless_bip", "c03_lossless_bsq_narrow", "c04_near_abs_hybrid", "c06_near_both_block",
                 "c11_wide_d32", "c20_hybrid_d28", "c25_tp_bsq_lossless", "c26_tp_bil_near_abs", "c27_tp_bip_full",
                 "c29_tp_bip_near_stride", "c30_tp_bip_both_stride"):
        s[name] = (ocp_configs.ALL[name], {})
    return s


SWEEP = _sweep()


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
    # The configurations of the synthesis sweep of the resource model
    for name, (c, extra) in SWEEP.items():
        if name not in cases:
            cases[name] = dict(ocp_generics.generics(c), **extra)
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
