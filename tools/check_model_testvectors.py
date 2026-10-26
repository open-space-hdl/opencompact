# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Validates the reference model (ocp_model.py) with the CCSDS 123.0-B-2 test data set.

The CCSDS test data (directory with sample-NNNNNN.flex, -hdr.bin, -optional_tables.bin, -error_limits.bin,
-hybrid_initial_accumulators.bin and the raw image) holds images compressed with randomly chosen configurations.
For every sample the script reads the configuration from the header, compresses the raw image with the model and
compares the result with the compressed file byte by byte. With --decode it also decodes the compressed file with the
decoder of the model (ocp_model.decompress): the decoded image must equal the raw image under lossless compression
and differ from it by at most the maximum error of every sample under near-lossless compression.

Usage: python tools/check_model_testvectors.py <test data directory> [first] [count] [--jobs N] [--decode]
"""

import argparse
import os
import re
import sys
from functools import partial
from multiprocessing import Pool
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ocp_model  # noqa: E402


RAW = {}


def raw_files(d):
    """Raw image of every sample of the data set (one directory listing; the data set has some 150000 files)."""
    if not RAW:
        for name in os.listdir(d):
            if name.endswith(".raw"):
                RAW[name[:13]] = Path(d) / name
    return RAW


def load(base):
    d = base.parent
    stem = base.name
    raw = raw_files(d)[stem]
    m = re.search(r"-([su])32be-(\d+)x(\d+)x(\d+)\.raw$", raw.name)
    signed = m.group(1) == "s"
    nz, ny, nx = int(m.group(2)), int(m.group(3)), int(m.group(4))
    data = raw.read_bytes()
    vals = [int.from_bytes(data[i:i + 4], "big", signed=signed) for i in range(0, len(data), 4)]
    img = [[vals[(z * ny + y) * nx:(z * ny + y) * nx + nx] for y in range(ny)] for z in range(nz)]
    flex = (d / (stem + ".flex")).read_bytes()
    hdr = (d / (stem + "-hdr.bin")).read_bytes()
    optf = d / (stem + "-optional_tables.bin")
    opt = optf.read_bytes() if optf.exists() else b""
    cfg, hlen = ocp_model.parse_header(hdr, opt)
    assert (cfg["large_n_x"], cfg["large_n_y"], cfg["large_n_z"]) == (nx, ny, nz)
    elf = d / (stem + "-error_limits.bin")
    el = elf.read_bytes() if elf.exists() else b""
    limits = [int.from_bytes(el[i:i + 2], "big") for i in range(0, len(el) - 1, 2)]
    if cfg["entropy_coder_type"] == 1:
        acf = d / (stem + "-hybrid_initial_accumulators.bin")
        rd = ocp_model.BitReader(acf.read_bytes())
        w = cfg["large_d"] + cfg["gamma_0"]
        cfg["hybrid_initial_accumulator"] = [rd.get(w) for _ in range(nz)]
    return cfg, img, limits, flex, hdr[:hlen]


def check(base, decode=False):
    try:
        cfg, img, limits, flex, hdr = load(base)
        gen_hdr = ocp_model.header(cfg)
        if gen_hdr != flex[:len(gen_hdr)]:
            return base.name, "header", cfg
        out = ocp_model.compress(cfg, img, limits)
        if out != flex:
            pos = next((i for i in range(min(len(out), len(flex))) if out[i] != flex[i]), min(len(out), len(flex)))
            return base.name, "body mismatch at byte {} (len {} vs {})".format(pos, len(out), len(flex)), cfg
        if decode:
            err = check_decoded(base, cfg, img, flex)
            if err:
                return base.name, err, cfg
        return base.name, None, cfg
    except Exception as exc:  # noqa: BLE001
        return base.name, "exception {!r}".format(exc), None


def check_decoded(base, cfg, img, flex):
    """The decoder of the model reconstructs the image: identical samples under lossless compression, every sample
    within its maximum error mz(t) otherwise."""
    optf = base.parent / (base.name + "-optional_tables.bin")
    dcfg, dec, merr = ocp_model.decompress(flex, optf.read_bytes() if optf.exists() else None)
    for z in range(cfg["large_n_z"]):
        for y in range(cfg["large_n_y"]):
            for x in range(cfg["large_n_x"]):
                if abs(dec[z][y][x] - img[z][y][x]) > merr[z][y][x]:
                    return "decoded sample ({}, {}, {}) is {}, the image has {} (maximum error {})".format(
                        z, y, x, dec[z][y][x], img[z][y][x], merr[z][y][x])
    if cfg["quantizer_fidelity_control_method"] == 0 and dec != img:
        return "decoded lossless image differs"
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("first", nargs="?", type=int, default=0)
    ap.add_argument("count", nargs="?", type=int, default=1000000)
    ap.add_argument("--jobs", type=int, default=1)
    ap.add_argument("--max-samples", type=int, default=0, help="skip images with more samples")
    ap.add_argument("--stride", type=int, default=1, help="check every n-th sample of the data set")
    ap.add_argument("--min-samples", type=int, default=0, help="skip images with fewer samples")
    ap.add_argument("--decode", action="store_true",
                    help="also decode every compressed image with the decoder of the model and check it")
    args = ap.parse_args()
    d = Path(args.dir)
    bases = sorted(d / n[:13] for n in os.listdir(d) if n.endswith(".flex"))[args.first:args.first + args.count]
    bases = bases[::args.stride]
    if args.max_samples:
        keep = []
        for b in bases:
            raw = raw_files(d)[b.name]
            if args.min_samples <= raw.stat().st_size // 4 <= args.max_samples:
                keep.append(b)
        bases = keep
    fails = 0
    done = 0
    coders = [0, 0, 0]
    job = partial(check, decode=args.decode)
    if args.jobs > 1:
        pool = Pool(args.jobs)
        results = pool.imap_unordered(job, bases)
    else:
        pool = None
        results = map(job, bases)
    try:
        for name, err, cfg in results:
            done += 1
            if cfg:
                coders[cfg["entropy_coder_type"]] += 1
            if err:
                fails += 1
                ec = cfg["entropy_coder_type"] if cfg else "?"
                print("FAIL", name, err, "coder", ec, flush=True)
            if done % 250 == 0:
                print("progress {}/{} checked, {} failures".format(done, len(bases), fails), flush=True)
    finally:
        if pool is not None:
            pool.close()
    print("checked {} samples ({} sample-adaptive, {} hybrid, {} block-adaptive), {} failures".format(
        len(bases), coders[0], coders[1], coders[2], fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
