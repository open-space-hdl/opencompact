# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Decompresses a compressed image of CCSDS 123.0-B-2 with the decoder of the reference model (tools/ocp_model.py).

The decoded image holds the clipped quantizer bin centers: under lossless compression the samples of the image, under
near-lossless compression values that differ from them by at most the maximum error of every sample (CCSDS 4.1,
4.8.2.1). It is written in the input order of the compressor (CCSDS 5.4.2) as little-endian 8, 16 or 32-bit samples,
the format of the raw images of the testbenches and of the CNES reference software. The decoder needs Python only.

With --compare the decoded image is checked against the original image in the same format: identical under lossless
compression, every sample within its maximum error under near-lossless compression. The exit code is 1 when the check
fails or the data is not a compressed image.

Usage: python tools/ocp_decompress.py <compressed image> [-o <decoded raw image>] [--optional-tables <file>]
       [--compare <raw image>]
"""

import argparse
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ocp_model  # noqa: E402

CODERS = ["sample-adaptive", "hybrid", "block-adaptive"]
FIDELITY = ["lossless", "absolute error limit", "relative error limit", "absolute and relative error limits"]


def sample_bytes(cfg):
    d = cfg["large_d"]
    return 1 if d <= 8 else 2 if d <= 16 else 4


def write_raw(cfg, samples, path):
    nb = sample_bytes(cfg)
    signed = cfg["sample_type"] == 1
    Path(path).write_bytes(b"".join(s.to_bytes(nb, "little", signed=signed) for s in samples))


def read_raw(cfg, path):
    nb = sample_bytes(cfg)
    data = Path(path).read_bytes()
    return [int.from_bytes(data[i:i + nb], "little", signed=cfg["sample_type"] == 1) for i in range(0, len(data), nb)]


def compare(cfg, original, decoded, max_error):
    """Prints the comparison with the original image; returns True when it passes."""
    if len(original) != len(decoded):
        print("original: {} samples, the decoded image has {}".format(len(original), len(decoded)))
        return False
    errors = [abs(a - b) for a, b in zip(original, decoded)]
    beyond = sum(1 for e, m in zip(errors, max_error) if e > m)
    print("maximum error:      {} (largest maximum error {})".format(max(errors), max(max_error)))
    print("samples beyond their maximum error: {}".format(beyond))
    mse = sum(e * e for e in errors) / len(errors)
    peak = (1 << cfg["large_d"]) - 1
    print("PSNR:               {}".format("infinite" if mse == 0 else "{:.2f} dB".format(
        10 * math.log10(peak * peak / mse))))
    if cfg["quantizer_fidelity_control_method"] == 0 and any(errors):
        print("result: FAIL (lossless image not reconstructed exactly)")
        return False
    print("result: {}".format("FAIL" if beyond else "PASS"))
    return beyond == 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("compressed", help="compressed image (header and body)")
    ap.add_argument("-o", "--output", help="decoded raw image")
    ap.add_argument("--optional-tables", help="tables that the header does not carry (CNES layout)")
    ap.add_argument("--compare", help="original raw image to check the decoded image against")
    args = ap.parse_args()
    data = Path(args.compressed).read_bytes()
    opt = Path(args.optional_tables).read_bytes() if args.optional_tables else None
    try:
        cfg, img, merr = ocp_model.decompress(data, opt)
    except ocp_model.DecodeError as exc:
        print("error: {}".format(exc))
        return 1
    decoded = ocp_model.image_samples(cfg, img)
    max_error = ocp_model.image_samples(cfg, merr)
    order = "BSQ" if cfg["sample_encoding_order"] else "BI, M = {}".format(cfg["large_m"])
    print("image:              NX {}, NY {}, NZ {}, D {} ({}), {} order".format(
        cfg["large_n_x"], cfg["large_n_y"], cfg["large_n_z"], cfg["large_d"],
        "signed" if cfg["sample_type"] else "unsigned", order))
    print("compression:        {} coder, {}".format(CODERS[cfg["entropy_coder_type"]],
                                                    FIDELITY[cfg["quantizer_fidelity_control_method"]]))
    print("compressed image:   {} bytes, {:.3f} bits per sample".format(len(data), 8.0 * len(data) / len(decoded)))
    if args.output:
        write_raw(cfg, decoded, args.output)
        print("decoded image:      {}".format(args.output))
    if args.compare:
        return 0 if compare(cfg, read_raw(cfg, args.compare), decoded, max_error) else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
