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


def stride_cycles(g, lat, st):
    """Cycle-accurate model of the stride order of one image: the input buffer accepts a sample per cycle while it
    has room for the unprocessed samples; the slots advance one per cycle, a sample is issued once it has arrived,
    the samples it depends on have left the feedback loops and the output buffer has room; the output buffer is
    read in the input order once a sample is finished. Returns the cycles in which the samples are accepted at the
    input and in which the items are read from the output buffer."""
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
    return in_cyc, out_cyc


def stride_spans(g, lat, st):
    """Cycles between the first and the last sample at the input and between the first and the last item at the
    output of one image in stride order."""
    in_cyc, out_cyc = stride_cycles(g, lat, st)
    return in_cyc[-1] - in_cyc[0], out_cyc[-1] - out_cyc[0]


def rep_equals_sample(g):
    """Sample representatives equal the samples: lossless compression without damping (CCSDS 4.9.2)."""
    damping = [int(v) for v in str(g["Damping_g"]).split(",")]
    return g["Fidelity_g"] == "LOSSLESS" and (g["SampleRepResolution_g"] == 0 or not any(damping))


def issue_dist(bsq, sfd, nx, ny, nz, p, rep_is_sample, w_used, cross_rep, l_win, l_rep, l_dw):
    """Issue conditions that depend on the image dimensions (function issueDist of ocp_pkg)."""
    m = min(sfd, nz)
    gap1 = bsq or m == 1
    run_rows = bsq or nz == 1
    if bsq:
        row_gap, diff_gap = nx - 1, nx * ny
    else:
        row_gap = (nx - 1) * m
        diff_gap = row_gap + 1
    same_rep = not rep_is_sample and (w_used or row_gap < l_rep)
    cross_dw = p > 0 and (bsq or m < nz) and diff_gap < l_dw
    l_fix = max(0 if gap1 else l_win, l_rep if same_rep else 0)
    l_cross = max(l_rep if cross_rep else 0, l_dw if cross_dw else 0)
    return {"m": m, "gap1": gap1, "run_rows": run_rows, "l_fix": l_fix, "l_cross": l_cross}


def start_params(g):
    """Flags and latencies of the predictor of a configuration that the image-start sequencer (ocp_image_start)
    uses."""
    lat = latencies(g)
    p = g["PredictionBands_g"]
    narrow = g["LocalSum_g"] in ("NARROW_NEIGHBOR", "NARROW_COLUMN")
    rep_is_sample = rep_equals_sample(g)
    return {"bsq": g["EncodingOrder_g"] == "BSQ", "sfd": g["SubFrameDepth_g"], "p": p,
            "rep_is_sample": rep_is_sample, "w_used": g["PredictionMode_g"] == "FULL" or not narrow,
            "cross_rep": not rep_is_sample and (p > 0 or narrow),
            "l_win": lat["stages"]["ram"] + 2, "l_rep": lat["stages"]["rep_sum"] + 2,
            "l_dw": lat["stages"]["dz"] + 2}


def image_start_cycles(g):
    """Clock cycles of the image-start sequencer from Start to Done (imageStartCycles of ocp_pkg)."""
    s = start_params(g)
    w = 1
    while 2 ** w <= max(s["l_rep"], s["l_dw"]):
        w += 1
    return w + 3


def latencies(g, speculation=True, dims=None):
    """Pipeline stages and required issue distances (cycles) for the generics g of a configuration. With dims =
    (nx, ny, nz) or (nx, ny, nz, m) the generics are the maxima of a runtime configuration: the structure
    (speculation, memories) follows the maxima, the issue distances the dimensions of the image (and its M with the
    runtime parameters)."""
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
    if dims is not None:
        sfd = dims[3] if len(dims) > 3 else g["SubFrameDepth_g"]
        rt = issue_dist(bsq, sfd, *dims[:3], p, rep_is_sample, w_used, cross_rep, st["ram"] + 2, l_rep, l_dw)
        run_rows, l_fix, l_cross = rt["run_rows"], rt["l_fix"], rt["l_cross"]
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
        4: g["PredictionBands_g"] > 0 and (bsq or m < nz or (g.get("RuntimeParams_g", False) and nz > 1)),
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


# Tail of the hybrid coder (ocp_hybrid_coder): after the last item of an image, accepted in cycle a, the coder takes
# no item in the cycles a + 1 to a + HYBRID_TAIL + NZ: its pipeline of 8 stages empties (a + 9), it outputs the 8 flush
# words (a + 10 to a + 17), then reads the final accumulators of the NZ bands with a latency of 2 (a + 18 on) and ends
# the image with the last of them (a + 19 + NZ)
HYBRID_TAIL = 19


def output_fifo_depth(lat):
    """Depth of the output FIFO of the predictor: room for every item in flight (ocp_predictor, FifoDepth_c)."""
    depth = 1
    while depth < lat["depth"] + 8:
        depth *= 2
    return depth


def coder_cycles(g, speculation=True, images=1, dims=None, start=None, tail=True):
    """Issue cycle of every sample of consecutive images, with the output of the predictor modelled cycle by cycle
    from the RTL (CO-TP-01):

    - the issue stage takes the next item once the samples it depends on have left the feedback loops (as
      issue_cycles) and while Inflight + level + 2 does not exceed the depth of the output FIFO (ocp_predictor);
    - an item reaches the output FIFO `depth` cycles after its issue; the FIFO (olo_ft_fifo_sync) counts a write in
      its level from the next cycle, offers the item two cycles after the write and lowers the level two cycles
      after the read;
    - the register stage behind the FIFO (olo_base_pl_stage) holds a main and a shadow item, its ready is registered;
    - the hybrid coder takes no item during the tail of an image (HYBRID_TAIL + NZ cycles after its last item), the
      other coders take one item per cycle.

    The codewords leave the coder without back pressure (the bit packer keeps up, CO-TP-01).

    With dims ((nx, ny, nz) of every image, or (nx, ny, nz, m) with the runtime parameters; g holds the maxima) the
    images have their own dimensions (runtime configuration): the first sample of an image is accepted with the
    configuration in the cycle after the last sample of the previous image was issued (the output FIFO does not hold
    it back) and issued once the image-start sequencer is done, start + 1 cycles later; its acceptance cycle is
    returned for it.

    With tail false the output takes one item per cycle whatever the coder (the predictor alone, as in its
    testbench)."""
    lat0 = latencies(g, speculation)
    depth = lat0["depth"]
    fdepth = output_fifo_depth(lat0)
    hybrid = tail and g["EntropyCoder_g"] == "HYBRID"
    if dims is None:
        dims = [(g["XSize_g"], g["YSize_g"], g["ZSize_g"])] * images
        runtime = False
    else:
        runtime = True
    seq = []
    for dim in dims:
        nx, ny, nz = dim[:3]
        gi = dict(g, XSize_g=nx, YSize_g=ny, ZSize_g=nz)
        if len(dim) > 3:
            gi["SubFrameDepth_g"] = dim[3]
        lat = latencies(g, speculation, dims=tuple(dim)) if runtime else lat0
        image = list(items(gi))
        seq += [(item, k == len(image) - 1, k == 0, HYBRID_TAIL + nz, lat, nx) for k, item in enumerate(image)]
    issue = 0
    last_band = {}
    last_pixel = {}
    prev = -1
    take = None
    writes = {}
    inflight = 0
    fifo = []
    wr_level = rd_level = 0
    rd_up = wr_down = False
    main = shadow = None
    in_ready = True
    ending_until = -1
    taken = 0
    cycles = []
    t = 0
    while taken < len(seq):
        # Combinational signals of the cycle
        coder_ready = not (hybrid and t <= ending_until)
        written = writes.pop(t, None)
        fifo_read = rd_level > 0 and in_ready
        issued = False
        if issue < len(seq):
            (kind, z, y, x), _, first, _, lat, nx = seq[issue]
            earliest = prev + 1
            if runtime and first:
                # The first sample of the image is accepted with the configuration, then held for the image start
                if take is None:
                    take = prev + 1
                earliest = take + start + 1
            if kind == "S":
                need_w = (lat["c"] > 0 and y * nx + x > 1 and
                          (not lat["spec"] or (not lat["run_rows"] and x == 0)))
                l_same = max(lat["l_fix"], lat["l_w"] if need_w else 0)
                if z in last_band:
                    earliest = max(earliest, last_band[z] + l_same)
                if lat["l_cross"]:
                    if (z - 1, x) in last_pixel:
                        earliest = max(earliest, last_pixel[(z - 1, x)] + lat["l_cross"])
                    if lat["narrow"] and y == 0 and x > 0 and (z - 1, x - 1) in last_pixel:
                        earliest = max(earliest, last_pixel[(z - 1, x - 1)] + lat["l_cross"])
            if t >= earliest and inflight + wr_level + 2 <= fdepth:
                issued = True
                prev = t
                if kind == "S":
                    last_band[z] = t
                    last_pixel[(z, x)] = t
                    cycles.append(take if runtime and first else t)
                take = None
                writes[t + depth] = issue
                issue += 1
        # Registers at the end of the cycle: items in flight, FIFO, register stage, coder
        inflight += int(issued) - int(written is not None)
        new_rd_up = written is not None
        new_wr_level = wr_level
        if written is not None:
            fifo.append(written)
            new_wr_level += 0 if wr_down else 1
        elif wr_down:
            new_wr_level -= 1
        new_wr_down = fifo_read
        new_rd_level = rd_level
        read = None
        if fifo_read:
            read = fifo.pop(0)
            new_rd_level -= 0 if rd_up else 1
        elif rd_up:
            new_rd_level += 1
        stuck = main is not None and not coder_ready and (rd_level > 0 or shadow is not None)
        if main is not None and coder_ready:
            if seq[main][1] and hybrid:
                ending_until = t + seq[main][3]
            taken += 1
            main, shadow = shadow, None
        if fifo_read:
            if stuck:
                shadow = read
            else:
                main = read
        in_ready = not stuck
        wr_level, rd_level, rd_up, wr_down = new_wr_level, new_rd_level, new_rd_up, new_wr_down
        t += 1
    return cycles


def issue_cycles(g, speculation=True, images=1):
    """Issue cycle of every sample of images consecutive images (without back pressure at the input and the
    output). With the hybrid coder and more than one image the tail of an image can hold back the next image through
    the output FIFO of the predictor (coder_cycles); within one image the coder takes one item per cycle. In stride
    order the samples enter an input buffer (stride_cycles)."""
    if images > 1 and g["EntropyCoder_g"] == "HYBRID" and stride_params(g, latencies(g, speculation)) is None:
        return coder_cycles(g, speculation, images)
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


def runtime_accept_cycles(g, dims, speculation=True, tail=True):
    """Acceptance cycle of every sample at the input of the predictor for consecutive images of a runtime
    configuration (g: the generics with the maxima; dims: (nx, ny, nz) or (nx, ny, nz, m) of every image), without
    back pressure. The first sample of an image is accepted with the configuration (CO-RC-03) in the cycle after the
    last sample of the previous image was issued, and issued image_start_cycles(g) + 1 cycles later, once the
    image-start sequencer is done (CO-RC-05); with the hybrid coder the tail of an image can hold back the next image
    (coder_cycles). With tail false the output takes one item per cycle (the predictor without an entropy coder)."""
    return coder_cycles(g, speculation, dims=dims, start=image_start_cycles(g), tail=tail)


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


def image_period(g, speculation=True):
    """Cycles between the acceptance of the first samples of two consecutive images (back to back, without back
    pressure at the input and the output). Outside stride order the issue cycles of two images give it. In stride
    order the next image starts once all slots of the image have passed and its last item has been read from the
    output buffer: the read takes two cycles, and the input buffer accepts the first sample of the next image one
    cycle after the start, four cycles after the read of the last item."""
    lat = latencies(g, speculation)
    st = stride_params(g, lat)
    if st is not None:
        in_cyc, out_cyc = stride_cycles(g, lat, st)
        return out_cyc[-1] + 4 - in_cyc[0]
    n = g["XSize_g"] * g["YSize_g"] * g["ZSize_g"]
    cycles = issue_cycles(g, speculation, images=2)
    return cycles[n] - cycles[0]


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
