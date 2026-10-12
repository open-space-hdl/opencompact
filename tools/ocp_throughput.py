# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Throughput model of the OpenCompact predictor.

The predictor (hdl/ocp_predictor) is a pipeline without internal stalls. Its issue stage starts a sample once the
samples it depends on have left the feedback loops: the previous sample of the same band (weights, window of the
previous line and, in near-lossless compression, sample representatives) and, in near-lossless compression or with
central local differences kept in memory, the sample of the previous band at the same pixel. Lossless compression with
damping (Theta > 0 and a phi_z > 0) counts as near-lossless here: its sample representatives depend on the predicted
sample (CCSDS 4.9.2). When consecutive samples belong to the same band, the weight loop speculates over the error
signs and needs no distance. This module mirrors
the pipeline stages and the required distances of the RTL and computes the issue cycle of every item of the entropy
coder input sequence. The predictor testbench checks that the RTL issues the samples of a configuration in exactly
the computed number of cycles.

Usage: python tools/ocp_throughput.py [configuration ...]
"""

import math
import sys

import ocp_configs
import ocp_generics


def tree_stages(n):
    """Stages of the adder tree of the dot product (four operands per stage)."""
    stages, reach = 1, 4
    while reach < n:
        reach *= 4
        stages += 1
    return stages


def gcd(a, b):
    while b:
        a, b = b, a % b
    return a


def stride_params(g, lat):
    """Stride order of BI order with M = NZ in near-lossless compression (or lossless compression with damping)
    with dependencies between the bands of a pixel: sample (z, t) in slot t M + z S with S >= L_cross coprime with M
    (None when not used)."""
    nz = g["ZSize_g"]
    m = min(g["SubFrameDepth_g"], nz)
    narrow = g["LocalSum_g"] in ("NARROW_NEIGHBOR", "NARROW_COLUMN")
    cross_rep = not rep_equals_sample(g) and (g["PredictionBands_g"] > 0 or narrow)
    periodic = g["PeriodicUpdate_g"] and g["Fidelity_g"] != "LOSSLESS"
    if not (g.get("Stride_g", True) and g["EncodingOrder_g"] == "BI" and m == nz and nz > 1 and cross_rep and
            not periodic):
        return None
    s = max(lat["l_cross"], 2)
    while gcd(s, m) != 1:
        s += 1
    return {"s": s, "m": m, "skew": (m - 1) * (s - 1)}


def stride_spans(g, lat, st):
    """Cycle-accurate model of the stride order of one image: the input buffer accepts a sample per cycle while it
    has room for the unprocessed samples; the slots advance one per cycle, a sample is issued once it has arrived,
    the samples it depends on have left the feedback loops and the output buffer has room; the output buffer is
    read in the input order once a sample is finished. Returns the cycles between the first and the last sample at
    the input and between the first and the last item at the output."""
    m, s = st["m"], st["s"]
    nx, npix = g["XSize_g"], g["XSize_g"] * g["YSize_g"]
    narr = npix * m
    sinv = next(i for i in range(1, m) if (s * i) % m == 1)
    depth = lat["depth"]
    out = lat["stages"]["out"]
    in_depth = 2 ** math.ceil(math.log2(st["skew"] + m + 8))
    out_depth = 2 ** math.ceil(math.log2(st["skew"] + 2 * depth + 16))
    last_slot = (npix - 1) * m + (m - 1) * s
    arr = low_a = n = oa = 0
    o_slot = 0
    o_z = 0
    done_slot = None
    writes = {}
    last_band, last_pixel = {}, {}
    in_cyc, out_cyc = [], []
    cyc = 0
    pdone = False
    while len(out_cyc) < narr:
        # Registered state of this cycle: arr, low_a, n, oa, done_slot
        arr_next = arr
        if arr < narr and arr - low_a < in_depth:
            in_cyc.append(cyc)
            arr_next = arr + 1
        if cyc in writes:
            done_now = writes.pop(cyc)
        else:
            done_now = None
        if not pdone:
            z = (n * sinv) % m
            t = (n - z * s) // m
            advance = t < 0 or t >= npix
            if not advance:
                y, x = divmod(t, nx)
                a = t * m + z
                need_w = lat["c"] > 0 and t > 1
                l_same = max(lat["l_fix"], lat["l_w"] if need_w else 0)
                ok = a < arr and n - oa < out_depth - depth - 8
                if z in last_band and cyc < last_band[z] + l_same:
                    ok = False
                if lat["l_cross"]:
                    if (z - 1, x) in last_pixel and cyc < last_pixel[(z - 1, x)] + lat["l_cross"]:
                        ok = False
                    if (lat["narrow"] and y == 0 and x > 0 and (z - 1, x - 1) in last_pixel and
                            cyc < last_pixel[(z - 1, x - 1)] + lat["l_cross"]):
                        ok = False
                if ok:
                    advance = True
                    last_band[z] = cyc
                    last_pixel[(z, x)] = cyc
                    # Finished (written to the output buffer) at the end of cycle + out + 1
                    writes[cyc + out + 2] = n
                    if z == m - 1:
                        low_a += m
                    if n == last_slot:
                        pdone = True
            if advance and not pdone:
                n += 1
        # Reader: next input index once its slot is finished
        if done_now is not None:
            done_slot = done_now
        if oa < narr and done_slot is not None and o_slot <= done_slot:
            out_cyc.append(cyc)
            oa += 1
            if o_z == m - 1:
                o_z = 0
                o_slot -= (m - 1) * s - m
            else:
                o_z += 1
                o_slot += s
        arr = arr_next
        cyc += 1
    return in_cyc[-1] - in_cyc[0], out_cyc[-1] - out_cyc[0]


def rep_equals_sample(g):
    """Sample representatives equal the samples: lossless compression without damping (CCSDS 4.9.2)."""
    damping = [int(v) for v in str(g["Damping_g"]).split(",")]
    return g["Fidelity_g"] == "LOSSLESS" and (g["SampleRepResolution_g"] == 0 or not any(damping))


def latencies(g, speculation=True):
    """Pipeline stages and required issue distances (cycles) for the generics g of a configuration."""
    d = g["DynamicRange_g"]
    nx, ny, nz = g["XSize_g"], g["YSize_g"], g["ZSize_g"]
    bsq = g["EncodingOrder_g"] == "BSQ"
    m = min(g["SubFrameDepth_g"], nz)
    p = g["PredictionBands_g"]
    full = g["PredictionMode_g"] == "FULL"
    narrow = g["LocalSum_g"] in ("NARROW_NEIGHBOR", "NARROW_COLUMN")
    fid = g["Fidelity_g"]
    lossless = fid == "LOSSLESS"
    rep_is_sample = rep_equals_sample(g)
    c = p + 3 * int(full)
    c1 = max(c, 1)
    qw = max(d, 16) + 2
    w_used = full or not narrow
    gap1 = bsq or m == 1
    run_rows = bsq or nz == 1
    ts = tree_stages(c1 + 1)
    thresh_sign = fid not in ("RELATIVE", "ABSOLUTE_RELATIVE")
    spec = speculation and thresh_sign and gap1 and c > 0 and ts == 1 and (rep_is_sample or not w_used)

    st = {"ram": 2, "diff": 3, "inc": 4, "prod": 5}
    st["tree"] = st["prod"] + ts
    st["sgn"] = st["tree"] + 1
    st["pred_b"] = st["sgn"] + 1
    st["quant"] = st["pred_b"] + 1
    st["limit"] = st["quant"] + 1
    st["upd"] = (st["sgn"] if thresh_sign else st["limit"]) + 1
    st["rep"] = st["limit"] + (0 if lossless else qw) + 1
    st["rep_mul"] = st["rep"] + 1
    st["rep_sum"] = st["rep_mul"] + 1
    st["out"] = max(st["rep_sum"], st["upd"])
    st["dz"] = st["diff"] if rep_is_sample else st["rep_sum"]

    l_w = st["upd"] - 1 if c > 0 else 0
    l_win = 0 if gap1 else st["ram"] + 2
    l_rep = st["rep_sum"] + 2
    row_gap = (nx - 1) * (1 if bsq else m)
    same_rep = not rep_is_sample and (w_used or row_gap < l_rep)
    l_fix = max(l_win, l_rep if same_rep else 0)
    diff_ram = p > 0 and (bsq or m < nz)
    l_dw = st["dz"] + 2
    diff_gap = nx * ny if bsq else (nx - 1) * m + 1
    cross_rep = not rep_is_sample and (p > 0 or narrow)
    cross_dw = diff_ram and diff_gap < l_dw
    l_cross = max(l_rep if cross_rep else 0, l_dw if cross_dw else 0)
    return {"stages": st, "depth": st["out"] + 1, "spec": spec, "run_rows": run_rows, "c": c, "narrow": narrow,
            "l_w": l_w, "l_fix": l_fix, "l_cross": l_cross}


# Error injection channels of ocp_core (ErrInj_Channel): the memories of the predictor (0 to 11) and of the entropy
# coder (12, 13)
ECC_CHANNELS = {
    0: "sample representatives of the line", 1: "window of the previous line", 2: "previous sample representative",
    3: "first sample representative of the line", 4: "central local differences", 5: "weights",
    6: "absolute error limits", 7: "relative error limits", 8: "predictor output FIFO", 9: "stride input buffer",
    10: "stride output buffer", 11: "stride local differences", 12: "coder statistics", 13: "codeword FIFO",
}


def ecc_channels(g):
    """Error injection channels whose memory exists in a configuration (mirrors the generate conditions of
    ocp_predictor and of the entropy coders)."""
    nz = g["ZSize_g"]
    bsq = g["EncodingOrder_g"] == "BSQ"
    m = min(g["SubFrameDepth_g"], nz)
    fid = g["Fidelity_g"]
    periodic = g["PeriodicUpdate_g"] and fid != "LOSSLESS" and not bsq
    lat = latencies(g, g.get("Speculation_g", True))
    present = {
        0: True,
        1: not (bsq or m == 1),
        2: True,
        3: True,
        4: g["PredictionBands_g"] > 0 and (bsq or m < nz),
        5: lat["c"] > 0 and not (lat["spec"] and lat["run_rows"]),
        6: periodic and fid in ("ABSOLUTE", "ABSOLUTE_RELATIVE") and g["AbsBandDependent_g"],
        7: periodic and fid in ("RELATIVE", "ABSOLUTE_RELATIVE") and g["RelBandDependent_g"],
        8: True,
        12: g["EntropyCoder_g"] in ("SAMPLE_ADAPTIVE", "HYBRID"),
        13: True,
    }
    stride = stride_params(g, lat) is not None
    present.update({9: stride, 10: stride, 11: stride})
    return [ch for ch in sorted(present) if present[ch]]


def items(g):
    """Entropy coder input sequence (CCSDS 5.4.2): ("L", ...) for an error limit value, ("S", z, y, x) for a sample."""
    nx, ny, nz = g["XSize_g"], g["YSize_g"], g["ZSize_g"]
    lossless = g["Fidelity_g"] == "LOSSLESS"
    if g["EncodingOrder_g"] == "BSQ":
        for z in range(nz):
            for y in range(ny):
                for x in range(nx):
                    yield ("S", z, y, x)
        return
    m = min(g["SubFrameDepth_g"], nz)
    fid = g["Fidelity_g"]
    n_lim = 0
    if g["PeriodicUpdate_g"] and not lossless:
        if fid in ("ABSOLUTE", "ABSOLUTE_RELATIVE"):
            n_lim += nz if g["AbsBandDependent_g"] else 1
        if fid in ("RELATIVE", "ABSOLUTE_RELATIVE"):
            n_lim += nz if g["RelBandDependent_g"] else 1
    for y in range(ny):
        if n_lim and y % (2 ** g["UpdatePeriodExp_g"]) == 0:
            for _ in range(n_lim):
                yield ("L", 0, 0, 0)
        for low in range(0, nz, m):
            for x in range(nx):
                for z in range(low, min(low + m, nz)):
                    yield ("S", z, y, x)


def issue_cycles(g, speculation=True, images=1):
    """Issue cycle of every sample of images consecutive images (without back pressure at the input and the
    output)."""
    lat = latencies(g, speculation)
    nx = g["XSize_g"]
    last_band = {}
    last_pixel = {}
    cycles = []
    cyc = -1
    sequence = [item for _ in range(images) for item in items(g)]
    for kind, z, y, x in sequence:
        cyc += 1
        if kind != "S":
            continue
        t = y * nx + x
        need_w = (lat["c"] > 0 and t > 1 and
                  (not lat["spec"] or (not lat["run_rows"] and x == 0)))
        l_same = max(lat["l_fix"], lat["l_w"] if need_w else 0)
        if z in last_band:
            cyc = max(cyc, last_band[z] + l_same)
        if lat["l_cross"]:
            if (z - 1, x) in last_pixel:
                cyc = max(cyc, last_pixel[(z - 1, x)] + lat["l_cross"])
            if lat["narrow"] and y == 0 and x > 0 and (z - 1, x - 1) in last_pixel:
                cyc = max(cyc, last_pixel[(z - 1, x - 1)] + lat["l_cross"])
        last_band[z] = cyc
        last_pixel[(z, x)] = cyc
        cycles.append(cyc)
    return cycles


def issue_span(g, speculation=True, images=1):
    """Cycles between the acceptance of the first and of the last sample of images consecutive images. In stride
    order the input buffer accepts the samples of an image without a gap (one image only)."""
    lat = latencies(g, speculation)
    st = stride_params(g, lat)
    if st is not None:
        assert images == 1
        return stride_spans(g, lat, st)[0]
    cycles = issue_cycles(g, speculation, images)
    return cycles[-1] - cycles[0]


def output_span(g, speculation=True):
    """Cycles between the first and the last item at the output of the predictor in stride order (0: not
    modelled)."""
    lat = latencies(g, speculation)
    st = stride_params(g, lat)
    return stride_spans(g, lat, st)[1] if st is not None else 0


def main():
    names = sys.argv[1:] or list(ocp_configs.CONFIGS)
    print(f"{'configuration':28} {'samples':>8} {'cycles':>8} {'cyc/sample':>10} {'depth':>6} {'order':>8} "
          f"{'L_w':>4} {'L_fix':>5} {'L_cross':>7}")
    for name in names:
        g = ocp_generics.generics(ocp_configs.CONFIGS[name])
        lat = latencies(g)
        st = stride_params(g, lat)
        n = g["XSize_g"] * g["YSize_g"] * g["ZSize_g"]
        if st is not None:
            # Stride order: from the first to the last item at the output
            span = stride_spans(g, lat, st)[1]
            order = f"S={st['s']}"
        else:
            span = issue_span(g)
            order = "spec" if lat["spec"] else "input"
        print(f"{name:28} {n:8} {span:8} {(span + 1) / n:10.2f} {lat['depth']:6} {order:>8} "
              f"{lat['l_w']:4} {lat['l_fix']:5} {lat['l_cross']:7}")


if __name__ == "__main__":
    main()
