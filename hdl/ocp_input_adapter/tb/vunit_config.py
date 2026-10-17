# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""VUnit configurations of ocp_input_adapter_tb.

Every width of the SDU stream (8 to 128 bits) with containers of 1 to 4 bytes (D = 8, 12, 16, 20, 24, 32): the
converter at integer and non-integer ratios, up- and downsizing, and the configurations without converter (one
container per beat). Two configurations use the default masks (UserWidth_g = 1). test_samples, test_faults and
test_reset run every configuration, every second one with input gaps and output stalls; test_rate runs without back
pressure.
"""

# (InWidth_g, DynamicRange_g, UserWidth_g)
CONFIGS = [
    (128, 8, 22), (128, 12, 22), (128, 16, 22), (128, 20, 22), (128, 32, 22),
    (64, 16, 22), (64, 20, 22),
    (32, 32, 22), (32, 20, 22), (32, 12, 22),
    (16, 16, 22), (16, 12, 22), (16, 24, 22),
    (8, 8, 22), (8, 20, 22), (8, 32, 22),
    (128, 16, 1), (16, 16, 1),
]


def configure(lib):
    tb = lib.test_bench("ocp_input_adapter_tb")
    for n, (width, d, user) in enumerate(CONFIGS):
        name = "w{}_d{}_u{}".format(width, d, user)
        gen = {"InWidth_g": width, "DynamicRange_g": d, "UserWidth_g": user}
        bp = dict(gen, InGapPct_g=30, OutStallPct_g=40) if n % 2 else gen
        for test in ("test_samples", "test_faults", "test_reset"):
            tb.test(test).add_config(name=name + ("_bp" if n % 2 else ""), generics=bp)
        tb.test("test_rate").add_config(name=name, generics=gen)
