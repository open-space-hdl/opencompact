# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Generics of ocp_core (and of its testbenches) for a configuration of tools/ocp_configs.py.

Vector generics are given as comma-separated strings, the supplementary information tables as a hexadecimal
string; the testbenches convert them (ocp_tb_pkg).
"""

import copy

import ocp_model

CODERS = {0: "SAMPLE_ADAPTIVE", 1: "HYBRID", 2: "BLOCK_ADAPTIVE"}
FIDELITY = {0: "LOSSLESS", 1: "ABSOLUTE", 2: "RELATIVE", 3: "ABSOLUTE_RELATIVE"}
LOCAL_SUMS = {0: "WIDE_NEIGHBOR", 1: "NARROW_NEIGHBOR", 2: "WIDE_COLUMN", 3: "NARROW_COLUMN"}


def int_list(values):
    return ",".join(str(v) for v in (values if values else [0]))


def sup_table_hex(c):
    """Supplementary Information Tables subpart (CCSDS 5.3.2.3) as a hexadecimal string."""
    if not c["supplementary_information_tables"]:
        return "00"
    full = ocp_model.header(c)
    bare = copy.deepcopy(c)
    bare["supplementary_information_tables"] = []
    plain = ocp_model.header(bare)
    return full[12:12 + len(full) - len(plain)].hex().upper()


def generics(c):
    sr = c["sample_representative_flag"] == 1
    return {
        "XSize_g": c["large_n_x"],
        "YSize_g": c["large_n_y"],
        "ZSize_g": c["large_n_z"],
        "DynamicRange_g": c["large_d"],
        "SignedSamples_g": c["sample_type"] == 1,
        "UserData_g": c["user_defined_data"],
        "EncodingOrder_g": "BSQ" if c["sample_encoding_order"] == 1 else "BI",
        "SubFrameDepth_g": max(c["large_m"], 1),
        "OutputWordSize_g": c["large_b"],
        "EntropyCoder_g": CODERS[c["entropy_coder_type"]],
        "SupTableCount_g": len(c["supplementary_information_tables"]),
        "SupTableData_g": sup_table_hex(c),
        "PredictionBands_g": c["large_p"],
        "PredictionMode_g": "REDUCED" if c["prediction_mode"] == 1 else "FULL",
        "LocalSum_g": LOCAL_SUMS[c["local_sum_type"]],
        "RegisterSize_g": c["large_r"],
        "WeightResolution_g": c["large_omega"],
        "WeightUpdateInterval_g": c["log_two_t_inc"],
        "WeightUpdateVmin_g": c["v_min"],
        "WeightUpdateVmax_g": c["v_max"],
        "WeightExpOffsetsUsed_g": c["weight_exponent_offset_flag"] == 1,
        "WeightExpOffsetTable_g": c["weight_exponent_offset_table_flag"] == 1,
        "WeightExpOffsets_g": int_list(c["zeta_vector"]),
        "CustomWeights_g": c["weight_initialization_method"] == 1,
        "WeightInitTable_g": c["weight_initialization_table_flag"] == 1,
        "WeightInitResolution_g": c["large_q"],
        "WeightInitValues_g": int_list(c["large_lambda_vector"]),
        "Fidelity_g": FIDELITY[c["quantizer_fidelity_control_method"]],
        "PeriodicUpdate_g": c["periodic_updating_flag"] == 1,
        "UpdatePeriodExp_g": c["u"],
        "AbsBandDependent_g": c["absolute_error_limit_assignment_method"] == 1,
        "AbsBitDepth_g": c["large_d_large_a"],
        "AbsErrorLimits_g": int_list(c["a_vector"]),
        "RelBandDependent_g": c["relative_error_limit_assignment_method"] == 1,
        "RelBitDepth_g": c["large_d_large_r"],
        "RelErrorLimits_g": int_list(c["r_vector"]),
        "SampleRepResolution_g": c["large_theta"] if sr else 0,
        "DampingBandVarying_g": c["band_varying_damping_flag"] == 1,
        "DampingTable_g": c["damping_table_flag"] == 1,
        "Damping_g": int_list(c["phi_vector"]),
        "OffsetBandVarying_g": c["band_varying_offset_flag"] == 1,
        "OffsetTable_g": c["offset_table_flag"] == 1,
        "Offset_g": int_list(c["psi_vector"]),
        "UnaryLimit_g": c["large_u_max"],
        "RescaleCounterSize_g": c["gamma_star"],
        "InitialCountExp_g": c["gamma_0"],
        "AccuInitBandVarying_g": c["band_varying_k_flag"] == 1,
        "AccuInitTable_g": c["accumulator_initialization_table_flag"] == 1,
        "AccuInit_g": int_list(c["k_prime_prime_vector"]),
        "HybridAccuInit_g": int_list([v & 0x7FFFFFFF for v in c["hybrid_initial_accumulator"]]),
        "HybridAccuInitHigh_g": int_list([v >> 31 for v in c["hybrid_initial_accumulator"]]),
        "BlockSize_g": c["large_j"],
        "RestrictedCodes_g": c["restricted_code_options_flag"] == 1,
        "RefInterval_g": c["r"],
    }


# Generics of the predictor testbench (subset of the core generics)
PREDICTOR = [
    "XSize_g", "YSize_g", "ZSize_g", "DynamicRange_g", "SignedSamples_g", "EncodingOrder_g", "SubFrameDepth_g",
    "PredictionBands_g", "PredictionMode_g", "LocalSum_g", "RegisterSize_g", "WeightResolution_g",
    "WeightUpdateInterval_g", "WeightUpdateVmin_g", "WeightUpdateVmax_g", "WeightExpOffsetsUsed_g",
    "WeightExpOffsets_g", "CustomWeights_g", "WeightInitResolution_g", "WeightInitValues_g", "Fidelity_g",
    "PeriodicUpdate_g", "UpdatePeriodExp_g", "AbsBandDependent_g", "AbsErrorLimits_g", "RelBandDependent_g",
    "RelErrorLimits_g", "SampleRepResolution_g", "Damping_g", "Offset_g",
]
