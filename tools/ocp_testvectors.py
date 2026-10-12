# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Prepares test vectors of the CCSDS 123.0-B-2 test data set for the core testbench.

The CCSDS test data set holds images compressed with randomly chosen configurations (see
check_model_testvectors.py for its file layout). The data set is not part of the repository. This script selects
test vectors, converts each into the golden directory format of the core testbench and writes the selection into an
output directory:

- <out>/<name>/image.raw          image in the input order of the compressor (little-endian 8, 16 or 32-bit samples)
- <out>/<name>/compressed.bin     compressed image of the data set (header and body)
- <out>/<name>/error_limits.bin   periodic error limit values (16-bit big-endian), only with periodic updating
- <out>/<name>/config.json        configuration (parameter names of ocp_model.default_config())
- <out>/<name>/delta.txt          entropy coder input sequence of the reference model (predictor testbench)
- <out>/index.json                names of the selected test vectors

The selection is greedy: it first takes the test vectors that add the most parameter values not yet selected
(coder, order, fidelity, prediction mode, local sums, bit depth, number of prediction bands, weight resolution, tables
and so on), then fills up to the requested count with a random choice taken in turn from the groups of coder, order
and fidelity. Only images up to --max-samples samples are
considered. The reference model must reproduce every selected compressed image.

The core and the predictor testbench run the selection when the environment variable OCP_TESTVECTORS names the
output directory:

    python tools/ocp_testvectors.py <test data directory> --out <dir> --count 300
    OCP_TESTVECTORS=<dir> python run.py -p 4 "*ocp_core_tb.tv_*"
"""

import argparse
import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_model_testvectors as tv  # noqa: E402
import golden  # noqa: E402
import ocp_configs  # noqa: E402
import ocp_model  # noqa: E402


def bucket(v, edges):
    """Index of the first edge that is >= v."""
    return next(i for i, e in enumerate(edges + [v]) if v <= e)


def features(c):
    """Parameter values of a configuration that the selection tries to cover."""
    nz = c["large_n_z"]
    m = c["large_m"]
    if c["sample_encoding_order"] == 1:
        order = "bsq"
    elif m == 1:
        order = "bil"
    elif m >= nz:
        order = "bip"
    else:
        order = "bi"
    coder = c["entropy_coder_type"]
    fid = c["quantizer_fidelity_control_method"]
    f = {
        "coder": coder,
        "order": order,
        "fidelity": fid,
        "mode": c["prediction_mode"],
        "local_sum": c["local_sum_type"],
        "coder_order": (coder, order),
        "coder_fidelity": (coder, fid),
        "mode_local_sum": (c["prediction_mode"], c["local_sum_type"]),
        "d": bucket(c["large_d"], [2, 4, 8, 12, 16, 20, 24, 28, 31, 32]),
        "signed": c["sample_type"],
        "p": bucket(c["large_p"], [0, 1, 2, 3, 5, 8, 11, 14, 15]),
        "omega": bucket(c["large_omega"], [4, 6, 9, 12, 15, 18, 19]),
        "r_tight": c["large_r"] == max(32, c["large_d"] + c["large_omega"] + 2),
        "r_64": c["large_r"] == 64,
        "tinc": c["log_two_t_inc"],
        "vmin_vmax": bucket(c["v_max"] - c["v_min"], [0, 3, 7, 11, 15]),
        "b": c["large_b"],
        "nx1": c["large_n_x"] == 1,
        "ny1": c["large_n_y"] == 1,
        "nz1": nz == 1,
        "sup_tables": bucket(len(c["supplementary_information_tables"]), [0, 1, 3, 15]),
        "sup_types": tuple(sorted({t["type"] for t in c["supplementary_information_tables"]})),
        "zeta": (c["weight_exponent_offset_flag"], c["weight_exponent_offset_table_flag"]),
        "custom_weights": (c["weight_initialization_method"], c["weight_initialization_table_flag"]),
    }
    if fid:
        f["periodic"] = c["periodic_updating_flag"]
        f["periodic_u"] = c["u"] if c["periodic_updating_flag"] else None
        if fid in (1, 3):
            f["abs_dep"] = c["absolute_error_limit_assignment_method"]
            f["abs_depth"] = bucket(c["large_d_large_a"], [1, 4, 8, 12, 16])
        if fid in (2, 3):
            f["rel_dep"] = c["relative_error_limit_assignment_method"]
            f["rel_depth"] = bucket(c["large_d_large_r"], [1, 4, 8, 12, 16])
        f["sample_rep"] = c["sample_representative_flag"]
        if c["sample_representative_flag"]:
            f["theta"] = c["large_theta"]
            f["damping"] = (c["band_varying_damping_flag"], c["damping_table_flag"])
            f["offset"] = (c["band_varying_offset_flag"], c["offset_table_flag"])
    if coder in (0, 1):
        f["umax"] = bucket(c["large_u_max"], [8, 12, 16, 24, 32])
        f["gamma_star"] = c["gamma_star"]
        f["gamma_0"] = c["gamma_0"]
    if coder == 0:
        f["k_init"] = (c["band_varying_k_flag"], c["accumulator_initialization_table_flag"])
    if coder == 2:
        f["j"] = c["large_j"]
        f["restricted"] = c["restricted_code_options_flag"]
        f["ref"] = bucket(c["r"], [1, 4, 16, 64, 256, 4095, 4096])
    return {(k, v) for k, v in f.items()}


def select(cands, count, seed):
    """Greedy selection of the candidates (name, feature set) that cover the most feature values."""
    rng = random.Random(seed)
    pool = list(cands)
    rng.shuffle(pool)
    covered = set()
    chosen = []
    while pool and len(chosen) < count:
        best = max(range(len(pool)), key=lambda i: len(pool[i][1] - covered))
        if not pool[best][1] - covered:
            break
        covered |= pool[best][1]
        chosen.append(pool.pop(best)[0])
    greedy = len(chosen)
    # Fill up in turn from the groups of coder, order and fidelity
    groups = {}
    for name, f in pool:
        key = tuple(sorted(v for v in f if v[0] in ("coder", "order", "fidelity")))
        groups.setdefault(key, []).append(name)
    keys = sorted(groups)
    while len(chosen) < count and keys:
        for key in list(keys):
            if len(chosen) == count:
                break
            chosen.append(groups[key].pop())
            if not groups[key]:
                keys.remove(key)
    return chosen, greedy, len(covered)


def write_vector(base, out):
    cfg, img, limits, flex, _ = tv.load(base)
    if ocp_model.compress(cfg, img, limits) != flex:
        raise RuntimeError("{}: the reference model does not reproduce the compressed image".format(base.name))
    d = out / ("tv_" + base.name[7:])
    d.mkdir(parents=True, exist_ok=True)
    golden.write_raw(cfg, ocp_configs.input_order(cfg, img), d / "image.raw")
    (d / "compressed.bin").write_bytes(flex)
    if cfg["quantizer_fidelity_control_method"] and cfg["periodic_updating_flag"]:
        (d / "error_limits.bin").write_bytes(b"".join(v.to_bytes(2, "big") for v in limits))
    (d / "config.json").write_text(json.dumps(cfg, sort_keys=True), newline="\n")
    (d / "delta.txt").write_text(golden.delta_text(cfg, img, limits), newline="\n")
    return d.name


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir", help="directory of the CCSDS test data set")
    ap.add_argument("--out", required=True, help="output directory")
    ap.add_argument("--count", type=int, default=300)
    ap.add_argument("--max-samples", type=int, default=4096)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    d = Path(args.dir)
    out = Path(args.out)
    raw = tv.raw_files(d)
    cands = []
    for stem in sorted(raw):
        if raw[stem].stat().st_size // 4 > args.max_samples:
            continue
        hdr = (d / (stem + "-hdr.bin")).read_bytes()
        optf = d / (stem + "-optional_tables.bin")
        cfg, _ = ocp_model.parse_header(hdr, optf.read_bytes() if optf.exists() else b"")
        cands.append((stem, features(cfg)))
    chosen, greedy, covered = select(cands, args.count, args.seed)
    print("{} candidates, {} selected ({} for {} parameter values)".format(len(cands), len(chosen), greedy, covered))
    names = [write_vector(d / stem, out) for stem in sorted(chosen)]
    (out / "index.json").write_text(json.dumps(names, indent=0), newline="\n")


if __name__ == "__main__":
    main()
