# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Generates the golden compressed images of the verification with the CNES reference software.

For every configuration of tools/ocp_configs.py (ALL) the script writes into tb/golden/<configuration>/:

- image.raw            test image in the input order of the compressor (little-endian 8, 16 or 32-bit samples)
- compressed.bin       compressed image produced by the CNES encoder (lcnl_encoder): the golden reference
- optional_tables.bin  tables that the header does not contain (only when there are such tables)
- error_limits.bin     periodic error limit values, 16-bit big-endian (only with periodic error limit updating)
- delta.txt            mapped quantizer indices and error limit values in entropy coder input order, from the
                       reference model (tools/ocp_model.py), for the unit testbench of the predictor
- aborted_<n>.bin      (with --aborted) the image aborted by an early In_Last on sample n (counted from 0 in the
                       input order), from the reference model (ocp_model.compress_aborted): the CNES software has no
                       such output; the model reproduces the CNES encoder for every complete image

The script checks that the reference model produces the same compressed image as the CNES encoder and that the
CNES decoder reconstructs the image within the error limits.

With --decoded the script writes, for every near-lossless configuration, the image that the CNES decoder
(lcnl_decoder) reconstructs from tb/golden/<configuration>/compressed.bin into
tools/tests/golden_decoded/<configuration>.raw (the format of image.raw). The tests of the decoder of the reference
model (tools/tests) compare its output with these images; a lossless image needs none, it equals image.raw.

The CNES reference software (Linux executables lcnl_header_tool, lcnl_encoder, lcnl_decoder,
lcnl_supplementary_tables_encoder) runs natively on Linux or through WSL on Windows. Its bin directory is given with
--cnes-bin or the environment variable OCP_CNES_BIN (a path of the Linux file system).

Usage: python tools/golden.py [--cnes-bin <dir>] [configuration ...]
       python tools/golden.py --decoded [--cnes-bin <dir>] [configuration ...]
       python tools/golden.py --aborted [configuration ...]   (aborted images only; no CNES software needed)
"""

import argparse
import os
import random
import re
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ocp_configs  # noqa: E402
import ocp_model  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
GOLDEN = ROOT / "tb" / "golden"
DECODED = ROOT / "tools" / "tests" / "golden_decoded"
WINDOWS = os.name == "nt"
# Plain tables per call of lcnl_supplementary_tables_encoder: it stops with "Invalid number of arguments" for 14 or
# 15 tables, although the standard allows 15
SIT_GROUP = int(os.environ.get("OCP_SIT_GROUP", "13"))

# Configurations with aborted images (test_framing of ocp_core_tb, test_errors of ocp_channel_tb): every
# encoding order and coder, the stride order, periodic error limits
ABORTED = ["c22_single_pixel_hybrid", "c31_small_bi_periodic_abs", "r01_random", "c32_small_bip_periodic_rel",
           "c37_block_d32_custom", "r04_random", "c33_small_bip_stride_block", "c35_small_bil_periodic_spec",
           "r13_random", "c34_small_bsq_lossless", "r22_random", "r08_random", "c29_tp_bip_near_stride",
           "c30_tp_bip_both_stride",
           # hybrid coder in BSQ and BIL order (tail of bands without statistics)
           "r21_random", "c26_tp_bil_near_abs",
           # ocp_channel_tb
           "c36_block_j64_spikes", "r09_random", "r17_random", "r24_random"]

# Header tool parameters in the order in which they are set (vectors depend on N_Z, P and the prediction mode)
SCALARS = [
    "user_defined_data", "large_n_x", "large_n_y", "large_n_z", "sample_type", "large_d", "sample_encoding_order",
    "large_m", "large_b", "entropy_coder_type", "quantizer_fidelity_control_method",
    "sample_representative_flag", "large_p", "prediction_mode", "weight_exponent_offset_flag", "local_sum_type",
    "large_r", "large_omega", "log_two_t_inc", "v_min", "v_max", "weight_exponent_offset_table_flag",
    "weight_initialization_method", "weight_initialization_table_flag", "large_q",
    "periodic_updating_flag", "u", "absolute_error_limit_assignment_method", "large_d_large_a",
    "relative_error_limit_assignment_method", "large_d_large_r", "large_theta", "band_varying_damping_flag",
    "damping_table_flag", "band_varying_offset_flag", "offset_table_flag",
]
SA_HYBRID = ["large_u_max", "gamma_star", "gamma_0"]
SA_ONLY = ["band_varying_k_flag", "accumulator_initialization_table_flag"]
BLOCK = ["large_j", "restricted_code_options", "r"]


def to_linux(path):
    p = Path(path).resolve()
    if not WINDOWS:
        return str(p)
    drive = p.drive.rstrip(":").lower()
    return "/mnt/" + drive + p.as_posix()[len(p.drive):]


def run(cnes_bin, args, cwd):
    """Runs a CNES tool (args[0]) in cwd; paths in args are relative to cwd."""
    cmd = shlex.join([cnes_bin.rstrip("/") + "/" + args[0]] + args[1:])
    if WINDOWS:
        full = ["wsl.exe", "-e", "bash", "-c", "cd {} && {}".format(shlex.quote(to_linux(cwd)), cmd)]
    else:
        full = ["bash", "-c", cmd]
    res = subprocess.run(full, cwd=cwd, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if res.returncode != 0:
        raise RuntimeError("{} failed:\n{}\n{}".format(cmd, res.stdout, res.stderr))
    return res.stdout


def header_args(c):
    """-x options of lcnl_header_tool for a configuration."""
    opts = []
    for name in SCALARS:
        opts.append("{}={}".format(name, c[name]))
    if c["entropy_coder_type"] in (0, 1):
        opts += ["{}={}".format(n, c[n]) for n in SA_HYBRID]
    if c["entropy_coder_type"] == 0:
        opts += ["{}={}".format(n, c[n]) for n in SA_ONLY]
    if c["entropy_coder_type"] == 2:
        opts += ["large_j={}".format(c["large_j"]), "restricted_code_options={}".format(c["restricted_code_options_flag"]),
                 "r={}".format(c["r"])]
    vectors = ["a_vector", "r_vector", "phi_vector", "psi_vector"]
    if c["weight_initialization_method"]:
        vectors.append("large_lambda_vector")
    if c["weight_exponent_offset_flag"]:
        vectors.append("zeta_vector")
    if c["entropy_coder_type"] == 0:
        vectors.append("k_prime_prime_vector")
    for name in vectors:
        opts.append("{}={}".format(name, ",".join(str(v) for v in c[name])))
    args = []
    for o in opts:
        args += ["-x", o]
    return args


def sit_args(c):
    args = []
    sits = c["supplementary_information_tables"]
    if not sits:
        return args
    args += ["-x", "supplementary_information_table_count={}".format(len(sits))]
    for i, t in enumerate(sits):
        pre = "supplementary_information_table_{}_".format(i)
        args += ["-x", pre + "table_type={}".format(t["type"]), "-x", pre + "table_purpose={}".format(t["purpose"]),
                 "-x", pre + "table_structure={}".format(t["structure"]),
                 "-x", pre + "supplementary_user_defined_data={}".format(t["user_data"])]
        if t["type"] in (0, 1):
            args += ["-x", pre + "large_d_large_i={}".format(t["di"])]
        else:
            args += ["-x", pre + "large_d_large_f={}".format(t["df"]), "-x", pre + "large_d_large_e={}".format(t["de"]),
                     "-x", pre + "beta={}".format(t["beta"])]
    return args


def sit_element_bits(c, t):
    """Bits of the elements of a supplementary information table (CCSDS 5.3.2.3): DI per integer element, 1 + DE + DF
    per float element."""
    n = [1, c["large_n_z"], c["large_n_z"] * c["large_n_x"], c["large_n_y"] * c["large_n_x"]][t["structure"]]
    return n * (t["di"] if t["type"] in (0, 1) else 1 + t["de"] + t["df"])


def sit_text(c, t):
    """Plain-text table of the supplementary tables encoder (one row per z or y, columns along x)."""
    def fmt(e):
        if t["type"] in (0, 1):
            return str(e)
        b, ex, j = e
        df, beta = t["df"], t["beta"]
        if ex == 0:
            val = j * 2.0 ** (1 - beta - df)
        else:
            val = (1 + j / 2.0 ** df) * 2.0 ** (ex - beta)
        return "{:.17E}".format(-val if b else val)
    data = t["data"]
    if t["structure"] == 0:
        rows = [data[:1]]
    elif t["structure"] == 1:
        rows = [[e] for e in data[:c["large_n_z"]]]
    else:
        n = c["large_n_x"]
        rows = [data[i:i + n] for i in range(0, len(data), n)]
    return "\n".join(",".join(fmt(e) for e in r) for r in rows) + "\n"


def table_values(text):
    """Values of a plain-text supplementary information table, in order."""
    return [float(v) for v in re.split(r"[\s,]+", text.strip()) if v]


def write_raw(c, samples, path):
    nb = ocp_configs.sample_bytes(c)
    signed = c["sample_type"] == 1
    with open(path, "wb") as f:
        f.write(b"".join(s.to_bytes(nb, "little", signed=signed) for s in samples))


def raw_format(c):
    nb = ocp_configs.sample_bytes(c)
    return "{}{}le".format("s" if c["sample_type"] else "u", 8 * nb)


def read_raw(c, path):
    nb = ocp_configs.sample_bytes(c)
    data = Path(path).read_bytes()
    return [int.from_bytes(data[i:i + nb], "little", signed=c["sample_type"] == 1) for i in range(0, len(data), nb)]


def hybrid_acc_file(c, path):
    w = ocp_model.BitWriter()
    width = c["large_d"] + c["gamma_0"]
    for v in ocp_model.vec(c, "hybrid_initial_accumulator", c["large_n_z"]):
        w.put(v, width)
    w.align()
    Path(path).write_bytes(w.to_bytes())


def delta_text(c, img, limits):
    """Entropy coder input sequence from the model: 'S <z> <t> <delta>' or 'L <a|r> <value>' per line."""
    delta, lim = ocp_model.predict(c, img, limits)
    lines = []
    for item in ocp_model.input_sequence(c, delta, lim):
        if item[0] == "limit":
            lines.append("L {} {:08X}".format(item[1], item[2]))
        else:
            lines.append("S {} {} {:08X}".format(item[1], item[2], item[3]))
    return "\n".join(lines) + "\n"


def generate(name, c, cnes_bin):
    out = GOLDEN / name
    tmp = out / "tmp"
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir(parents=True)
    img = ocp_configs.make_image(c)
    samples = ocp_configs.input_order(c, img)
    write_raw(c, samples, out / "image.raw")
    shutil.copy(out / "image.raw", tmp / "image.raw")
    limits = ocp_configs.error_limit_updates(c)
    hdr_args = header_args(c)
    if c["supplementary_information_tables"]:
        run(cnes_bin, ["lcnl_header_tool"] + hdr_args + sit_args(c) +
            ["-s", "/dev/zero", "-o", "opt_tmp.bin", "hdr_tmp"], tmp)
        opt_tmp = ["-o", "opt_tmp.bin"] if (tmp / "opt_tmp.bin").exists() and (tmp / "opt_tmp.bin").stat().st_size \
            else []
        # The supplementary tables encoder takes at most SIT_GROUP plain tables per call: the tables are encoded in
        # groups, each with a header that describes the tables of the group. Its output holds the table elements bit
        # by bit, padded with zeros to a byte only at the end, so the groups are joined bit by bit
        sits = c["supplementary_information_tables"]
        bits = ""
        for first in range(0, len(sits), SIT_GROUP):
            group = dict(c, supplementary_information_tables=sits[first:first + SIT_GROUP])
            run(cnes_bin, ["lcnl_header_tool"] + hdr_args + sit_args(group) +
                ["-s", "/dev/zero", "-o", "opt_tmp.bin", "hdr_group"], tmp)
            texts = []
            for i, t in enumerate(group["supplementary_information_tables"]):
                (tmp / "sit_{}.txt".format(first + i)).write_text(sit_text(c, t))
                texts.append("sit_{}.txt".format(first + i))
            run(cnes_bin, ["lcnl_supplementary_tables_encoder"] + opt_tmp + ["hdr_group", "sit_group.bin"] + texts,
                tmp)
            data = (tmp / "sit_group.bin").read_bytes()
            length = sum(sit_element_bits(c, t) for t in group["supplementary_information_tables"])
            bits += "".join(format(byte, "08b") for byte in data)[:length]
        bits += "0" * (-len(bits) % 8)
        (tmp / "sit.bin").write_bytes(bytes(int(bits[i:i + 8], 2) for i in range(0, len(bits), 8)))
        hdr_args = (["-t", "opt_tmp.bin"] if opt_tmp else []) + ["-d", "hdr_tmp", "-s", "sit.bin"]
    run(cnes_bin, ["lcnl_header_tool"] + hdr_args + ["-o", "optional_tables.bin", "header.bin"], tmp)
    enc = ["lcnl_encoder"]
    dec = ["lcnl_decoder"]
    opt = tmp / "optional_tables.bin"
    if opt.exists() and opt.stat().st_size:
        enc += ["-o", "optional_tables.bin"]
        dec += ["-o", "optional_tables.bin"]
        shutil.copy(opt, out / "optional_tables.bin")
    if limits:
        (tmp / "error_limits.bin").write_bytes(b"".join(v.to_bytes(2, "big") for v in limits))
        enc += ["-q", "error_limits.bin"]
        shutil.copy(tmp / "error_limits.bin", out / "error_limits.bin")
    if c["entropy_coder_type"] == 1:
        hybrid_acc_file(c, tmp / "hybrid_acc.bin")
        enc += ["-a", "hybrid_acc.bin"]
    fmt = raw_format(c)
    run(cnes_bin, enc + ["header.bin", fmt, "image.raw", "compressed.bin"], tmp)
    run(cnes_bin, dec + ["compressed.bin", fmt, "decoded.raw"], tmp)
    golden = (tmp / "compressed.bin").read_bytes()
    (out / "compressed.bin").write_bytes(golden)
    # The model must reproduce the CNES result
    model = ocp_model.compress(c, img, limits)
    if model != golden:
        pos = next((i for i in range(min(len(model), len(golden))) if model[i] != golden[i]),
                   min(len(model), len(golden)))
        raise RuntimeError("{}: model differs from CNES at byte {} ({} vs {} bytes)".format(name, pos, len(model),
                                                                                            len(golden)))
    # The decoder reconstructs the image within the error limits
    decoded = read_raw(c, tmp / "decoded.raw")
    maxerr = max(abs(a - b) for a, b in zip(samples, decoded))
    if c["quantizer_fidelity_control_method"] == 0 and maxerr:
        raise RuntimeError("{}: lossless image not reconstructed exactly".format(name))
    # Every supplementary information table decodes from the compressed image to its values (this also checks the
    # tables that were encoded in separate groups)
    for i, t in enumerate(c["supplementary_information_tables"]):
        run(cnes_bin, ["lcnl_supplementary_tables_decoder"] + dec[1:] +
            ["compressed.bin", str(i), "sit_decoded_{}.txt".format(i)], tmp)
        if table_values((tmp / "sit_decoded_{}.txt".format(i)).read_text()) != table_values(sit_text(c, t)):
            raise RuntimeError("{}: supplementary information table {} does not decode to its values".format(name, i))
    (out / "delta.txt").write_text(delta_text(c, img, limits), newline="\n")
    for _ in range(10):
        try:
            shutil.rmtree(tmp)
            break
        except PermissionError:
            time.sleep(1)    # WSL may still hold the directory for a moment
    ratio = 8.0 * len(golden) / len(samples)
    print("{:28s} {:6d} samples, {:7d} bytes, {:6.3f} bit/sample, max error {}".format(name, len(samples),
                                                                                      len(golden), ratio, maxerr))


def write_decoded(name, c, cnes_bin):
    """The image that the CNES decoder reconstructs from the golden compressed image of a near-lossless
    configuration, in the format of image.raw."""
    src = GOLDEN / name
    tmp = DECODED / ("tmp_" + name)
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir(parents=True)
    shutil.copy(src / "compressed.bin", tmp / "compressed.bin")
    dec = ["lcnl_decoder"]
    if (src / "optional_tables.bin").exists():
        shutil.copy(src / "optional_tables.bin", tmp / "optional_tables.bin")
        dec += ["-o", "optional_tables.bin"]
    run(cnes_bin, dec + ["compressed.bin", raw_format(c), "decoded.raw"], tmp)
    DECODED.mkdir(parents=True, exist_ok=True)
    shutil.copy(tmp / "decoded.raw", DECODED / (name + ".raw"))
    decoded = read_raw(c, tmp / "decoded.raw")
    samples = read_raw(c, src / "image.raw")
    for _ in range(10):
        try:
            shutil.rmtree(tmp)
            break
        except PermissionError:
            time.sleep(1)    # WSL may still hold the directory for a moment
    print("{:28s} {:6d} samples decoded by CNES, max error {}".format(
        name, len(decoded), max(abs(a - b) for a, b in zip(samples, decoded))))


def abort_positions(name, c):
    """Samples with the early In_Last (counted from 0 in the input order): the first sample, the middle, the last but
    one and one position drawn with the configuration name as seed; in BI order also the last band of the first pixel,
    the first band of the second pixel, the last band of the last pixel but one and the middle band of the middle pixel
    (the classes of the slot window of the stride order)."""
    n = c["large_n_x"] * c["large_n_y"] * c["large_n_z"]
    nz = c["large_n_z"]
    pos = {0, n // 2, max(n - 2, 0), random.Random(name).randint(0, max(n - 2, 0))}
    if c["sample_encoding_order"] == 0 and nz > 1:
        pos |= {nz - 1, nz, n - nz - 1, (n // nz // 2) * nz + nz // 2}
    return sorted(p for p in pos if 0 <= p < n - 1)


def write_aborted(name, c):
    """Aborted images of a configuration at its abort positions, from the reference model."""
    out = GOLDEN / name
    img = ocp_configs.make_image(c)
    limits = ocp_configs.error_limit_updates(c)
    for old in out.glob("aborted_*.bin"):
        old.unlink()
    for p in abort_positions(name, c):
        (out / "aborted_{}.bin".format(p)).write_bytes(ocp_model.compress_aborted(c, img, p + 1, limits))
    print("{:28s} aborted at {}".format(name, ", ".join(str(p) for p in abort_positions(name, c))))


def check_runtime_header(name, ci, data, params=False):
    """The header of a compressed image of a runtime sequence, decoded by the header parser of the model, carries
    the dimensions, the sub-frame interleaving depth and the error limit values of the image (CO-HD-08); with params
    also its runtime parameters (CO-RP-01). Tables that the header leaves out come from the configuration."""
    hdr, _ = ocp_model.parse_header(data, tables=ci)
    fields = ["large_n_x", "large_n_y", "large_n_z", "large_m"]
    fid = ci["quantizer_fidelity_control_method"]
    if fid in (1, 3):
        fields.append("a_vector")
    if fid in (2, 3):
        fields.append("r_vector")
    if params:
        use = ocp_configs.params_in_use(ci)
        fields += ["user_defined_data", "log_two_t_inc", "v_min", "v_max"]
        if use["adp"]:
            fields += ["large_u_max", "gamma_star", "gamma_0"]
        if use["k"]:
            fields.append("k_prime_prime_vector")
        if use["r"]:
            fields.append("r")
    for f in fields:
        if hdr[f] != ci[f]:
            raise RuntimeError("{}: header field {} is {}, the image has {}".format(name, f, hdr[f], ci[f]))


def write_runtime(name, c):
    """Golden data of a runtime configuration (reference model; the model reproduces the CNES encoder for every
    complete image): the seeded image sequence of TC-CO-52 (runtime.txt, image_<k>.raw, compressed_<k>.bin,
    delta_<k>.txt), for the configurations of RUNTIME_RANGE the range test of TC-CO-57 (range.txt,
    range_image_<k>.raw, range_<k>.bin) and for those of RUNTIME_QUEUE the queue test of TC-CO-58 (queue.txt,
    queue_image_<k>.raw, queue_<k>.bin). A line of runtime.txt, range.txt and queue.txt holds the values driven on the
    configuration inputs of the core (NX, NY, NZ, absolute and relative error limit value), then the values the core
    takes (CO-RC-07)."""
    out = GOLDEN / name
    out.mkdir(parents=True, exist_ok=True)
    for old in list(out.glob("image_*.raw")) + list(out.glob("compressed_*.bin")) + list(out.glob("delta_*.txt")) + \
            list(out.glob("range*")) + list(out.glob("queue*")) + list(out.glob("rtabort*")):
        old.unlink()
    # (list, raw file, compressed file, with the entropy coder input, seed base, images)
    jobs = [("runtime", "image_{:02d}.raw", "compressed_{:02d}.bin", True, 0,
             [(d, d) for d in ocp_configs.runtime_sequence(c)])]
    if name in ocp_configs.RUNTIME_RANGE:
        jobs.append(("range", "range_image_{:02d}.raw", "range_{:02d}.bin", False, 100,
                     ocp_configs.runtime_range_sequence(c)))
    if name in ocp_configs.RUNTIME_QUEUE:
        jobs.append(("queue", "queue_image_{:02d}.raw", "queue_{:02d}.bin", False, 200,
                     ocp_configs.runtime_queue_sequence(c)))
    write_jobs(name, c, out, jobs)
    # Images of the runtime sequence aborted by an early In_Last (TC-CO-53): rtabort.txt holds the image and the
    # sample with the early In_Last (counted from 0), rtabort_<k>.bin the compressed image of the samples taken
    lines = []
    for k in ocp_configs.RUNTIME_ABORT:
        nx, ny, nz, a, r = ocp_configs.runtime_sequence(c)[k]
        ci = ocp_configs.runtime_image_cfg(c, nx, ny, nz, a, r, index=k)
        pos = (nx * ny * nz) // 2
        (out / "rtabort_{:02d}.bin".format(k)).write_bytes(
            ocp_model.compress_aborted(ci, ocp_configs.make_image(ci), pos + 1))
        lines.append("{} {}".format(k, pos))
    (out / "rtabort.txt").write_text("\n".join(lines) + "\n", newline="\n")


def write_runtime_params(name, c):
    """Golden data of a runtime parameter configuration (RUNTIME_PARAMS, reference model): the sequence of TC-CO-59
    (runtime.txt, image_<k>.raw, compressed_<k>.bin, delta_<k>.txt), the range test of TC-CO-60 (range.txt,
    range_image_<k>.raw, range_<k>.bin) and for those of RUNTIME_PARAMS_QUEUE the queue test of TC-CO-61 (queue.txt,
    queue_image_<k>.raw, queue_<k>.bin). A line of the lists holds the driven and the taken configuration (NX, NY,
    NZ, absolute and relative error limit value), then the driven and the taken runtime parameters (PARAM_NAMES of
    ocp_configs)."""
    out = GOLDEN / name
    out.mkdir(parents=True, exist_ok=True)
    for old in list(out.glob("image_*.raw")) + list(out.glob("compressed_*.bin")) + list(out.glob("delta_*.txt")) + \
            list(out.glob("range*")) + list(out.glob("queue*")) + list(out.glob("runtime*")):
        old.unlink()
    jobs = [("runtime", "image_{:02d}.raw", "compressed_{:02d}.bin", True, 0, ocp_configs.runtime_params_sequence(c)),
            ("range", "range_image_{:02d}.raw", "range_{:02d}.bin", False, 100,
             ocp_configs.runtime_params_range_sequence(c))]
    if name in ocp_configs.RUNTIME_PARAMS_QUEUE:
        jobs.append(("queue", "queue_image_{:02d}.raw", "queue_{:02d}.bin", False, 200,
                     ocp_configs.runtime_params_queue_sequence(c)))
    write_jobs(name, c, out, jobs)
    # Queue test with the output held after the header of the first image (queuehold.txt, queuehold_image_<k>.raw,
    # queuehold_<k>.bin), images of QUEUE_HOLD_IMAGE
    if name in ocp_configs.RUNTIME_PARAMS_QUEUE_HOLD:
        write_jobs(name, dict(c, image=ocp_configs.QUEUE_HOLD_IMAGE), out,
                   [("queuehold", "queuehold_image_{:02d}.raw", "queuehold_{:02d}.bin", False, 300,
                     ocp_configs.runtime_params_queue_hold_sequence(name, c))])


def write_params_sequence_only(name, c):
    """Golden data of a runtime parameter configuration of the sequence test only (RUNTIME_PARAMS_SEQUENCE_ONLY,
    TC-CO-59): runtime.txt, image_<k>.raw, compressed_<k>.bin, delta_<k>.txt."""
    out = GOLDEN / name
    out.mkdir(parents=True, exist_ok=True)
    for old in list(out.glob("image_*.raw")) + list(out.glob("compressed_*.bin")) + list(out.glob("delta_*.txt")) + \
            list(out.glob("runtime*")):
        old.unlink()
    write_jobs(name, c, out, [("runtime", "image_{:02d}.raw", "compressed_{:02d}.bin", True, 0,
                               ocp_configs.runtime_params_sequence(c))])


def write_params_queue_only(name, c):
    """Golden data of a runtime parameter configuration of the queue test only (RUNTIME_PARAMS_QUEUE_ONLY, TC-CO-61):
    queue.txt, queue_image_<k>.raw, queue_<k>.bin; the first image has all bands (a long tail of the hybrid coder)."""
    out = GOLDEN / name
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("queue*"):
        old.unlink()
    write_jobs(name, c, out, [("queue", "queue_image_{:02d}.raw", "queue_{:02d}.bin", False, 200,
                               ocp_configs.runtime_params_queue_sequence(c, long_tail=True))])


def write_queue_only(name, c):
    """Golden data of a configuration of the queue test only (RUNTIME_QUEUE_ONLY, TC-CO-58): queue.txt,
    queue_image_<k>.raw, queue_<k>.bin."""
    out = GOLDEN / name
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("queue*"):
        old.unlink()
    write_jobs(name, c, out, [("queue", "queue_image_{:02d}.raw", "queue_{:02d}.bin", False, 200,
                                ocp_configs.runtime_queue_sequence(c, name in ocp_configs.QUEUE_LONG_TAIL))])


def write_jobs(name, c, out, jobs):
    """Image lists of a runtime configuration: test images, compressed images (reference model, header checked) and
    with with_delta the entropy coder input sequences; a line of the list holds the driven and the taken values of
    the configuration, with runtime parameters (entries of four) then the driven and the taken parameters."""
    for list_name, raw_name, bin_name, with_delta, seed_base, seq in jobs:
        lines = []
        nbytes = 0
        for k, entry in enumerate(seq):
            driven, taken = entry[0], entry[1]
            params = entry[3] if len(entry) > 2 else None
            ci = ocp_configs.runtime_image_cfg(c, *taken, index=seed_base + k, params=params)
            img = ocp_configs.make_image(ci)
            write_raw(ci, ocp_configs.input_order(ci, img), out / raw_name.format(k))
            data = ocp_model.compress(ci, img)
            check_runtime_header(name, ci, data, params is not None)
            (out / bin_name.format(k)).write_bytes(data)
            if with_delta:
                (out / "delta_{:02d}.txt".format(k)).write_text(delta_text(ci, img, []), newline="\n")
            lines.append(" ".join(str(v) for part in entry for v in part))
            nbytes += len(data)
        (out / (list_name + ".txt")).write_text("\n".join(lines) + "\n", newline="\n")
        print("{:28s} {:6s} {:3d} images, {:7d} bytes".format(name, list_name, len(seq), nbytes))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cnes-bin", default=os.environ.get("OCP_CNES_BIN"))
    ap.add_argument("--aborted", action="store_true", help="write only the aborted images (reference model)")
    ap.add_argument("--runtime", action="store_true",
                    help="write only the image sequences of the runtime configurations (reference model)")
    ap.add_argument("--decoded", action="store_true",
                    help="write only the images decoded by the CNES decoder (near-lossless configurations)")
    ap.add_argument("configs", nargs="*")
    args = ap.parse_args()
    if args.aborted:
        for name in args.configs or ABORTED:
            write_aborted(name, ocp_configs.ALL[name])
        return
    if args.runtime:
        for name in args.configs or (list(ocp_configs.RUNTIME) + list(ocp_configs.RUNTIME_QUEUE_ONLY) +
                                     list(ocp_configs.RUNTIME_PARAMS) +
                                     list(ocp_configs.RUNTIME_PARAMS_SEQUENCE_ONLY) +
                                     list(ocp_configs.RUNTIME_PARAMS_QUEUE_ONLY)):
            if name in ocp_configs.RUNTIME_QUEUE_ONLY:
                write_queue_only(name, ocp_configs.RUNTIME_QUEUE_ONLY[name])
            elif name in ocp_configs.RUNTIME_PARAMS:
                write_runtime_params(name, ocp_configs.RUNTIME_PARAMS[name])
            elif name in ocp_configs.RUNTIME_PARAMS_SEQUENCE_ONLY:
                write_params_sequence_only(name, ocp_configs.RUNTIME_PARAMS_SEQUENCE_ONLY[name])
            elif name in ocp_configs.RUNTIME_PARAMS_QUEUE_ONLY:
                write_params_queue_only(name, ocp_configs.RUNTIME_PARAMS_QUEUE_ONLY[name])
            else:
                write_runtime(name, ocp_configs.RUNTIME[name])
        return
    if not args.cnes_bin:
        raise SystemExit("give the bin directory of the CNES reference software with --cnes-bin or OCP_CNES_BIN")
    if args.decoded:
        for name in args.configs or [n for n, c in ocp_configs.ALL.items()
                                     if c["quantizer_fidelity_control_method"] != 0]:
            write_decoded(name, ocp_configs.ALL[name], args.cnes_bin)
        return
    names = args.configs or list(ocp_configs.ALL)
    for name in names:
        generate(name, ocp_configs.ALL[name], args.cnes_bin)


if __name__ == "__main__":
    main()
