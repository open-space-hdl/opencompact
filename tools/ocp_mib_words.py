# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Expected configuration registers of ocp_mib (ID to BLOCK) for the configurations of tools/ocp_configs.py.

The words follow from the generics of a channel with the field positions of hdl/ocp_mib/regs/ocp_regs.yml. The
testbench of ocp_mib reads every register back and compares it with tools/ocp_mib_words.json, so the file is verified
by simulation; a system that computes the words itself can compare with the same file.

python tools/ocp_mib_words.py          writes tools/ocp_mib_words.json
python tools/ocp_mib_words.py --check  fails when the file does not match the configurations
"""

import argparse
import json
import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ocp_configs  # noqa: E402
import ocp_generics  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
REGS = ROOT / "hdl" / "ocp_mib" / "regs" / "ocp_regs.yml"
OUT = ROOT / "tools" / "ocp_mib_words.json"

CONFIG_REGISTERS = ["ID", "GENERICS", "IMAGE_X", "IMAGE_Y", "IMAGE_Z", "SAMPLES", "ORDER", "CODER", "PREDICTOR",
                    "WEIGHTS", "ADAPTIVE", "BLOCK"]

# Channel generics besides those of ocp_core (the widths of the channel testbench)
CHANNEL = {"InStreamWidth_g": 128, "OutStreamWidth_g": 128, "OutWidth_g": 64, "Speculation_g": True}


def fields():
    """Register name -> (offset, {field name: (lo, hi)})."""
    d = yaml.safe_load(REGS.read_text(encoding="utf-8"))
    out = {}
    for r in d["registers"]:
        f = {}
        for fd in r["fields"]:
            bits = str(fd["bits"])
            hi, lo = (bits.split(":") + [bits])[:2] if ":" in bits else (bits, bits)
            f[fd["name"]] = (int(lo), int(hi))
        out[r["name"]] = (r["offset"], f)
    return d["id"], out


def field_values(g):
    """Value of every configuration field from the generics (the rules of the register map)."""
    coder = {"SAMPLE_ADAPTIVE": 0, "HYBRID": 1, "BLOCK_ADAPTIVE": 2}[g["EntropyCoder_g"]]
    fid = {"LOSSLESS": 0, "ABSOLUTE": 1, "RELATIVE": 2, "ABSOLUTE_RELATIVE": 3}[g["Fidelity_g"]]
    bi = g["EncodingOrder_g"] == "BI"
    periodic = g["PeriodicUpdate_g"] and fid != 0
    accu = [int(v) for v in str(g["AccuInit_g"]).split(",")]
    return {
        "GENERICS": {"IN_STREAM_BYTES": g["InStreamWidth_g"] // 8, "OUT_STREAM_BYTES": g["OutStreamWidth_g"] // 8,
                     "OUT_BYTES": g["OutWidth_g"] // 8, "SAMPLE_BYTES": (g["DynamicRange_g"] + 7) // 8,
                     "SPECULATION": int(g["Speculation_g"]), "RUNTIME_CONFIG": int(g.get("RuntimeConfig_g", False)),
                     "RUNTIME_PARAMS": int(g.get("RuntimeParams_g", False))},
        "IMAGE_X": {"SIZE": g["XSize_g"]},
        "IMAGE_Y": {"SIZE": g["YSize_g"]},
        "IMAGE_Z": {"SIZE": g["ZSize_g"]},
        "SAMPLES": {"USER_DATA": g["UserData_g"], "SIGNED": int(g["SignedSamples_g"]),
                    "DYNAMIC_RANGE": g["DynamicRange_g"]},
        "ORDER": {"SUB_FRAME_DEPTH": g["SubFrameDepth_g"] if bi else 0, "ENCODING": 0 if bi else 1},
        "CODER": {"SUP_TABLES": g["SupTableCount_g"], "FIDELITY": fid, "ENTROPY_CODER": coder,
                  "OUTPUT_WORD_SIZE": g["OutputWordSize_g"]},
        "PREDICTOR": {"UPDATE_PERIOD_EXP": g["UpdatePeriodExp_g"] if periodic else 0,
                      "PERIODIC_UPDATE": int(periodic), "SAMPLE_REP_RESOLUTION": g["SampleRepResolution_g"],
                      "REGISTER_SIZE": g["RegisterSize_g"],
                      "LOCAL_SUM": ["WIDE_NEIGHBOR", "NARROW_NEIGHBOR", "WIDE_COLUMN",
                                    "NARROW_COLUMN"].index(g["LocalSum_g"]),
                      "REDUCED": int(g["PredictionMode_g"] == "REDUCED"), "BANDS": g["PredictionBands_g"]},
        "WEIGHTS": {"INIT_RESOLUTION": g["WeightInitResolution_g"] if g["CustomWeights_g"] else 0,
                    "CUSTOM_INIT": int(g["CustomWeights_g"]), "EXP_OFFSETS": int(g["WeightExpOffsetsUsed_g"]),
                    "VMAX": g["WeightUpdateVmax_g"], "VMIN": g["WeightUpdateVmin_g"],
                    "UPDATE_INTERVAL": g["WeightUpdateInterval_g"], "RESOLUTION": g["WeightResolution_g"]},
        "ADAPTIVE": {} if coder == 2 else {
            "ACCU_INIT": (15 if g["AccuInitBandVarying_g"] else accu[0]) if coder == 0 else 0,
            "INITIAL_COUNT": g["InitialCountExp_g"], "RESCALE_SIZE": g["RescaleCounterSize_g"],
            "UNARY_LIMIT": g["UnaryLimit_g"]},
        "BLOCK": {} if coder != 2 else {
            "REF_INTERVAL": g["RefInterval_g"], "RESTRICTED": int(g["RestrictedCodes_g"]),
            "BLOCK_SIZE": g["BlockSize_g"]},
        # Band-independent error limit values of the generics (zero for a method not in use or with band-dependent
        # limits); with the runtime configuration the values of the last image, after a reset these
        "LIMITS": {"ABS": first(g["AbsErrorLimits_g"]) if fid in (1, 3) and not g["AbsBandDependent_g"] else 0,
                   "REL": first(g["RelErrorLimits_g"]) if fid in (2, 3) and not g["RelBandDependent_g"] else 0},
    }


def first(values):
    return int(str(values).split(",")[0])


def words(g):
    """Register name -> 32-bit word."""
    reg_id, regs = fields()
    values = field_values(g)
    out = {"ID": reg_id}
    for name in CONFIG_REGISTERS[1:] + ["LIMITS"]:
        w = 0
        for fname, value in values[name].items():
            lo, hi = regs[name][1][fname]
            width = hi - lo + 1
            assert -(1 << (width - 1)) <= value < (1 << width), (name, fname, value)
            w |= (value & ((1 << width) - 1)) << lo
        out[name] = w
    return out


def channel_generics(c):
    g = ocp_generics.generics(c)
    g.update(CHANNEL)
    return g


def table():
    keep = ["InStreamWidth_g", "OutStreamWidth_g", "OutWidth_g", "Speculation_g", "XSize_g", "YSize_g", "ZSize_g",
            "DynamicRange_g", "SignedSamples_g", "UserData_g", "EncodingOrder_g", "SubFrameDepth_g",
            "OutputWordSize_g", "EntropyCoder_g", "Fidelity_g", "SupTableCount_g", "PredictionBands_g",
            "PredictionMode_g", "LocalSum_g", "RegisterSize_g", "SampleRepResolution_g", "PeriodicUpdate_g",
            "UpdatePeriodExp_g", "WeightResolution_g", "WeightUpdateInterval_g", "WeightUpdateVmin_g",
            "WeightUpdateVmax_g", "WeightExpOffsetsUsed_g", "CustomWeights_g", "WeightInitResolution_g",
            "UnaryLimit_g", "RescaleCounterSize_g", "InitialCountExp_g", "AccuInitBandVarying_g", "AccuInit_g",
            "BlockSize_g", "RestrictedCodes_g", "RefInterval_g", "AbsBandDependent_g", "AbsBitDepth_g",
            "AbsErrorLimits_g", "RelBandDependent_g", "RelBitDepth_g", "RelErrorLimits_g", "HybridAccuInit_g",
            "HybridAccuInitHigh_g", "RuntimeConfig_g", "RuntimeParams_g"]
    out = {}
    configs = [(name, c, False, False) for name, c in ocp_configs.ALL.items()]
    configs += [(name, c, True, False) for name, c in ocp_configs.RUNTIME.items()]
    configs += [(name, c, True, True) for name, c in ocp_configs.RUNTIME_PARAMS.items()]
    for name, c, runtime, params in configs:
        g = channel_generics(c)
        g["RuntimeConfig_g"] = runtime
        g["RuntimeParams_g"] = params
        out[name] = {"generics": {k: g[k] for k in keep},
                     "words": {k: "0x{:08X}".format(v) for k, v in words(g).items()}}
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true", help="fail when the file is not up to date")
    args = ap.parse_args()
    text = json.dumps(table(), indent=1) + "\n"
    current = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
    if args.check:
        if current != text:
            print("Not up to date (run python tools/ocp_mib_words.py):", OUT.relative_to(ROOT))
            return 1
        print("MIB words up to date")
        return 0
    OUT.write_text(text, encoding="utf-8", newline="\n")
    print("Written:", OUT.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
