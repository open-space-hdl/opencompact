# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Tests of the decoder of the reference model (ocp_model.decompress) against the golden data of the testbenches.

- The compressed images of tb/golden/<configuration>/compressed.bin come from the CNES encoder. The decoder
  reconstructs every lossless image exactly, and every near-lossless image exactly as the CNES decoder does
  (tools/tests/golden_decoded/<configuration>.raw, written by tools/golden.py --decoded), within the maximum error of
  every sample.
- The image sequences of the runtime configurations (compressed by the reference model) decode to their images.
- Tables that the header leaves out are taken from a configuration dict as well as from the optional tables file.
- Data that is not a compressed image raises DecodeError.

Run: python -m pytest tools/tests
"""

import sys
from pathlib import Path

import pytest

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
import ocp_configs  # noqa: E402
import ocp_model  # noqa: E402

GOLDEN = TOOLS.parent / "tb" / "golden"
DECODED = TOOLS / "tests" / "golden_decoded"

LOSSLESS = [n for n, c in ocp_configs.ALL.items() if c["quantizer_fidelity_control_method"] == 0]
NEAR_LOSSLESS = [n for n, c in ocp_configs.ALL.items() if c["quantizer_fidelity_control_method"] != 0]
RUNTIME = dict(ocp_configs.RUNTIME, **ocp_configs.RUNTIME_QUEUE_ONLY, **ocp_configs.RUNTIME_PARAMS,
               **ocp_configs.RUNTIME_PARAMS_SEQUENCE_ONLY, **ocp_configs.RUNTIME_PARAMS_QUEUE_ONLY)
WITH_TABLES = [n for n in ocp_configs.ALL if (GOLDEN / n / "optional_tables.bin").exists()]


def read_raw(cfg, path):
    nb = ocp_configs.sample_bytes(cfg)
    data = Path(path).read_bytes()
    return [int.from_bytes(data[i:i + nb], "little", signed=cfg["sample_type"] == 1) for i in range(0, len(data), nb)]


def golden(name):
    """Compressed image and optional tables of a golden configuration."""
    d = GOLDEN / name
    opt = d / "optional_tables.bin"
    return (d / "compressed.bin").read_bytes(), opt.read_bytes() if opt.exists() else None


def decode(data, opt=None, tables=None):
    cfg, img, merr = ocp_model.decompress(data, opt, tables)
    return cfg, ocp_model.image_samples(cfg, img), ocp_model.image_samples(cfg, merr)


def within(samples, decoded, max_error):
    return len(samples) == len(decoded) and all(abs(a - b) <= m for a, b, m in zip(samples, decoded, max_error))


@pytest.mark.parametrize("name", LOSSLESS)
def test_lossless_golden(name):
    c = ocp_configs.ALL[name]
    cfg, decoded, max_error = decode(*golden(name))
    assert decoded == read_raw(c, GOLDEN / name / "image.raw")
    assert not any(max_error)


@pytest.mark.parametrize("name", NEAR_LOSSLESS)
def test_near_lossless_golden(name):
    c = ocp_configs.ALL[name]
    cfg, decoded, max_error = decode(*golden(name))
    assert decoded == read_raw(c, DECODED / (name + ".raw")), "differs from the CNES decoder"
    assert within(read_raw(c, GOLDEN / name / "image.raw"), decoded, max_error)


@pytest.mark.parametrize("name", RUNTIME)
def test_runtime_sequences(name):
    out = GOLDEN / name
    files = sorted(out.glob("compressed_*.bin")) + sorted(out.glob("range_*.bin")) + sorted(out.glob("queue*_*.bin"))
    assert files
    for comp in files:
        prefix, k = comp.stem.rsplit("_", 1)
        raw = out / ("image_{}.raw".format(k) if prefix == "compressed" else "{}_image_{}.raw".format(prefix, k))
        # Per-band values that the header leaves out (band-varying K of rp06) come from the configuration
        cfg, decoded, max_error = decode(comp.read_bytes(), tables=RUNTIME[name])
        samples = read_raw(cfg, raw)
        assert within(samples, decoded, max_error), comp.name
        if cfg["quantizer_fidelity_control_method"] == 0:
            assert decoded == samples, comp.name


@pytest.mark.parametrize("name", WITH_TABLES)
def test_tables_from_configuration(name):
    """A table that the header leaves out comes from the configuration given to the compressor."""
    data, opt = golden(name)
    assert decode(data, tables=ocp_configs.ALL[name])[1] == decode(data, opt)[1]


def test_tables_missing():
    data, _ = golden(WITH_TABLES[0])
    with pytest.raises(ocp_model.DecodeError):
        ocp_model.decompress(data)


@pytest.mark.parametrize("coder", [0, 1, 2])
def test_truncated(coder):
    name = next(n for n in LOSSLESS + NEAR_LOSSLESS if ocp_configs.ALL[n]["entropy_coder_type"] == coder and
                n not in WITH_TABLES)
    data, _ = golden(name)
    _, hlen = ocp_model.parse_header(data)
    with pytest.raises(ocp_model.DecodeError):
        ocp_model.decompress(data[:hlen + (len(data) - hlen) // 2])
    with pytest.raises(ocp_model.DecodeError):
        ocp_model.decompress(data[:hlen - 1])


def test_hybrid_trailing_bytes():
    """The hybrid coder is decoded from the end: bytes after the compressed image are not allowed."""
    name = next(n for n in LOSSLESS if ocp_configs.ALL[n]["entropy_coder_type"] == 1 and n not in WITH_TABLES)
    data, _ = golden(name)
    with pytest.raises(ocp_model.DecodeError):
        ocp_model.decompress(data + b"\x5a")


@pytest.mark.parametrize("table", ["CODES_REVERSED", "FLUSH_REVERSED"])
def test_reversed_codes_prefix_free(table):
    """The low-entropy codewords and flush words are suffix-free (CCSDS 5.4.3.3.1), so read backward they decode
    without ambiguity."""
    for code in getattr(ocp_model, table):
        words = sorted(code)
        assert all(not b.startswith(a) for a, b in zip(words, words[1:]))


@pytest.mark.parametrize("name", ["c01_lossless_bip", "c03_lossless_bsq_narrow", "c05_near_rel_bi4_signed"])
def test_sample_order(name):
    c = ocp_configs.ALL[name]
    img = ocp_configs.make_image(c)
    samples = ocp_model.image_samples(c, img)
    assert samples == ocp_configs.input_order(c, img)
    assert ocp_model.image_from_samples(c, samples) == img
