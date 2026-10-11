# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Generates the golden compressed images of the verification with the CNES reference software.

For every configuration of tools/ocp_configs.py the script writes into tb/golden/<configuration>/:

- image.raw            test image in the input order of the compressor (little-endian 8, 16 or 32-bit samples)
- compressed.bin       compressed image produced by the CNES encoder (lcnl_encoder): the golden reference
- optional_tables.bin  tables that the header does not contain (only when there are such tables)
- error_limits.bin     periodic error limit values, 16-bit big-endian (only with periodic error limit updating)
- delta.txt            mapped quantizer indices and error limit values in entropy coder input order, from the
                       reference model (tools/ocp_model.py), for the unit testbench of the predictor

The script checks that the reference model produces the same compressed image as the CNES encoder and that the
CNES decoder reconstructs the image within the error limits.

The CNES reference software (Linux executables lcnl_header_tool, lcnl_encoder, lcnl_decoder,
lcnl_supplementary_tables_encoder) runs natively on Linux or through WSL on Windows. Its bin directory is given with
--cnes-bin or the environment variable OCP_CNES_BIN (a path of the Linux file system).

Usage: python tools/golden.py [--cnes-bin <dir>] [configuration ...]
"""

import argparse
import os
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
WINDOWS = os.name == "nt"

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
        run(cnes_bin, ["lcnl_header_tool"] + hdr_args + sit_args(c) + ["-s", "/dev/zero", "hdr_tmp"], tmp)
        texts = []
        for i, t in enumerate(c["supplementary_information_tables"]):
            (tmp / "sit_{}.txt".format(i)).write_text(sit_text(c, t))
            texts.append("sit_{}.txt".format(i))
        run(cnes_bin, ["lcnl_supplementary_tables_encoder", "hdr_tmp", "sit.bin"] + texts, tmp)
        hdr_args = ["-d", "hdr_tmp", "-s", "sit.bin"]
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cnes-bin", default=os.environ.get("OCP_CNES_BIN"))
    ap.add_argument("configs", nargs="*")
    args = ap.parse_args()
    if not args.cnes_bin:
        raise SystemExit("give the bin directory of the CNES reference software with --cnes-bin or OCP_CNES_BIN")
    names = args.configs or list(ocp_configs.CONFIGS)
    for name in names:
        generate(name, ocp_configs.CONFIGS[name], args.cnes_bin)


if __name__ == "__main__":
    main()
