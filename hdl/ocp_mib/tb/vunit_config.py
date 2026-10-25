# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""VUnit configurations of ocp_mib_tb.

test_config runs one configuration per entry of tools/ocp_mib_words.json without the runtime configuration (every
configuration of tools/ocp_configs.py with the generics of a channel) and compares the registers ID to BLOCK with
the words of the file and LIMITS with its LIMITS word; test_counters and test_reset run the first configuration.
test_runtime_config and test_runtime_commit run the entries with the runtime configuration (RUNTIME of
tools/ocp_configs.py).
"""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
WORDS = ROOT / "tools" / "ocp_mib_words.json"
REGISTERS = ["ID", "GENERICS", "IMAGE_X", "IMAGE_Y", "IMAGE_Z", "SAMPLES", "ORDER", "CODER", "PREDICTOR", "WEIGHTS",
             "ADAPTIVE", "BLOCK"]


def signed32(text):
    v = int(text, 16)
    return v - (1 << 32) if v >= 1 << 31 else v


def configure(lib):
    tb = lib.test_bench("ocp_mib_tb")
    table = json.loads(WORDS.read_text(encoding="utf-8"))
    first = True
    for name, entry in table.items():
        gen = dict(entry["generics"])
        gen["ExpWords_g"] = ",".join(str(signed32(entry["words"][r])) for r in REGISTERS)
        gen["ExpLimits_g"] = signed32(entry["words"]["LIMITS"])
        if gen["RuntimeConfig_g"]:
            tb.test("test_runtime_config").add_config(name=name, generics=gen)
            tb.test("test_runtime_commit").add_config(name=name, generics=gen)
            continue
        tb.test("test_config").add_config(name=name, generics=gen)
        if first:
            tb.test("test_counters").add_config(name=name, generics=gen)
            tb.test("test_reset").add_config(name=name, generics=gen)
            first = False
