# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Core configurations of the OpenCompact verification and their test images.

Every configuration is a dict of CCSDS 123.0-B-2 parameters with the names of ocp_model.default_config() plus
"image" (generator of the test image, see make_image) and "seed". tools/golden.py compresses the test image of
every configuration with the CNES reference software; run.py runs ocp_core with every configuration and compares its
output with that golden compressed image.
"""

import math
import random

from ocp_model import default_config


def cfg(**kw):
    c = default_config()
    c.update(kw)
    return c


def lambda_table(nz, p, full):
    """Custom weight initialization vectors (Q = 10 bits): small directional weights, decaying inter-band
    weights that vary from band to band."""
    out = []
    for z in range(nz):
        if full:
            out += [5 - z % 3, -3 + z % 2, 1]
        out += [100 + 3 * z, 12 - z // 3, 2, -1][:min(z, p)]
    return out


def zeta_table(nz, p, full, seed):
    """Weight exponent offsets in the range -6 to 5 (per band: intra-band offset in full mode, then Pz* inter-band
    offsets)."""
    rng = random.Random(seed)
    return [rng.randint(-6, 5) for z in range(nz) for _ in range(min(z, p) + (1 if full else 0))]


CONFIGS = {
    # Lossless baseline: full prediction, wide neighbor-oriented local sums, BIP, sample-adaptive coder
    "c01_lossless_bip": cfg(
        large_n_x=32, large_n_y=12, large_n_z=16, large_d=16, large_m=16, large_b=4,
        large_p=3, large_omega=13, large_r=32, log_two_t_inc=6, v_min=-1, v_max=3,
        large_u_max=18, gamma_star=6, gamma_0=1, k_prime_prime_vector=[4],
        image="scene", seed=1),
    # Push-broom imager: reduced prediction, wide column-oriented local sums, BIL, band-dependent accumulator
    # initialization table in the header
    "c02_lossless_bil_column": cfg(
        large_n_x=24, large_n_y=12, large_n_z=12, large_d=12, large_m=1, large_b=2,
        large_p=5, prediction_mode=1, local_sum_type=2, large_omega=10, large_r=40, log_two_t_inc=5,
        v_min=-2, v_max=4,
        large_u_max=16, gamma_star=8, gamma_0=3, band_varying_k_flag=1, accumulator_initialization_table_flag=1,
        k_prime_prime_vector=[2, 3, 4, 5, 6, 7, 8, 9, 3],
        image="stripes", seed=2),
    # BSQ order, narrow neighbor-oriented local sums, 8-bit samples, weight exponent offsets in the header
    "c03_lossless_bsq_narrow": cfg(
        large_n_x=20, large_n_y=10, large_n_z=8, large_d=8, sample_encoding_order=1, large_m=0, large_b=1,
        large_p=2, local_sum_type=1, large_omega=8, large_r=32, log_two_t_inc=4, v_min=-3, v_max=2,
        weight_exponent_offset_flag=1, weight_exponent_offset_table_flag=1,
        zeta_vector=zeta_table(8, 2, True, 3),
        large_u_max=12, gamma_star=5, gamma_0=2, k_prime_prime_vector=[2],
        image="scene", seed=3),
    # Near-lossless with a band-independent absolute error limit, sample representatives, hybrid coder
    "c04_near_abs_hybrid": cfg(
        large_n_x=24, large_n_y=12, large_n_z=12, large_d=16, large_m=12, large_b=8,
        large_p=3, large_omega=14, large_r=48, log_two_t_inc=6, v_min=-1, v_max=3,
        quantizer_fidelity_control_method=1, large_d_large_a=4, a_vector=[2],
        sample_representative_flag=1, large_theta=3, phi_vector=[3], psi_vector=[2],
        entropy_coder_type=1, large_u_max=16, gamma_star=7, gamma_0=2,
        hybrid_initial_accumulator=[40, 60, 80, 100, 120, 140, 160, 180],
        image="scene", seed=4),
    # Signed samples, BI order with M = 4, band-dependent relative error limits, narrow column-oriented local sums,
    # reduced prediction with weight exponent offsets, hybrid coder
    "c05_near_rel_bi4_signed": cfg(
        large_n_x=20, large_n_y=10, large_n_z=14, large_d=14, sample_type=1, large_m=4, large_b=3,
        large_p=6, prediction_mode=1, local_sum_type=3, large_omega=12, large_r=36, log_two_t_inc=5,
        v_min=-2, v_max=5,
        quantizer_fidelity_control_method=2, relative_error_limit_assignment_method=1, large_d_large_r=8,
        r_vector=[16, 32, 64, 8, 0, 128, 24],
        weight_exponent_offset_flag=1, weight_exponent_offset_table_flag=1, zeta_vector=zeta_table(14, 6, False, 5),
        entropy_coder_type=1, large_u_max=20, gamma_star=6, gamma_0=1, hybrid_initial_accumulator=[64],
        image="scene", seed=5),
    # Absolute and relative error limits, band-varying damping and offset tables, block-adaptive coder with a short
    # reference sample interval
    "c06_near_both_block": cfg(
        large_n_x=24, large_n_y=12, large_n_z=10, large_d=16, large_m=10, large_b=2,
        large_p=4, large_omega=15, large_r=64, log_two_t_inc=7, v_min=0, v_max=4,
        quantizer_fidelity_control_method=3, absolute_error_limit_assignment_method=1, large_d_large_a=5,
        a_vector=[1, 2, 3, 4, 8, 12, 16, 31, 0, 5], relative_error_limit_assignment_method=0, large_d_large_r=10,
        r_vector=[40],
        sample_representative_flag=1, large_theta=4, band_varying_damping_flag=1, damping_table_flag=1,
        phi_vector=[0, 5, 10, 15, 3, 7], band_varying_offset_flag=1, offset_table_flag=1,
        psi_vector=[1, 2, 4, 8, 15, 0],
        entropy_coder_type=2, large_j=16, r=4,
        image="scene", seed=6),
    # Lossless block-adaptive coder on a low-entropy image in BSQ order (zero-block option, remainder of segment)
    "c07_lossless_block_bsq": cfg(
        large_n_x=32, large_n_y=16, large_n_z=6, large_d=10, sample_encoding_order=1, large_m=0, large_b=4,
        large_p=1, large_omega=9, large_r=32, log_two_t_inc=4, v_min=-6, v_max=-2,
        entropy_coder_type=2, large_j=64, r=4096,
        image="flat", seed=7),
    # 4-bit samples with the restricted set of code options of the block-adaptive coder
    "c08_restricted_d4": cfg(
        large_n_x=16, large_n_y=16, large_n_z=8, large_d=4, large_m=1, large_b=1,
        large_p=2, large_omega=6, large_r=32, log_two_t_inc=4, v_min=-4, v_max=1,
        entropy_coder_type=2, large_j=8, restricted_code_options_flag=1, r=128,
        image="scene", seed=8),
    # Custom weight initialization (table in the header) and weight exponent offsets (not in the header)
    "c09_custom_weights": cfg(
        large_n_x=20, large_n_y=12, large_n_z=10, large_d=16, large_m=10, large_b=4,
        large_p=4, local_sum_type=0, large_omega=16, large_r=40, log_two_t_inc=8, v_min=-2, v_max=6,
        weight_initialization_method=1, weight_initialization_table_flag=1, large_q=10,
        large_lambda_vector=lambda_table(10, 4, True),
        weight_exponent_offset_flag=1, weight_exponent_offset_table_flag=0,
        zeta_vector=zeta_table(10, 4, True, 9),
        large_u_max=24, gamma_star=9, gamma_0=4, k_prime_prime_vector=[6],
        image="scene", seed=9),
    # Periodic error limit updating every 2 frames with band-dependent absolute and band-independent relative error
    # limits, BI order with M = 2, hybrid coder
    "c10_periodic_limits": cfg(
        large_n_x=16, large_n_y=12, large_n_z=8, large_d=16, large_m=2, large_b=2,
        large_p=3, large_omega=12, large_r=40, log_two_t_inc=5, v_min=-1, v_max=3,
        quantizer_fidelity_control_method=3, periodic_updating_flag=1, u=1,
        absolute_error_limit_assignment_method=1, large_d_large_a=5, a_vector=[0],
        relative_error_limit_assignment_method=0, large_d_large_r=6, r_vector=[0],
        entropy_coder_type=1, large_u_max=18, gamma_star=6, gamma_0=1, hybrid_initial_accumulator=[100],
        image="scene", seed=10),
    # 32-bit unsigned samples, P = 15, largest weight resolution and register size, 8-byte output words
    "c11_wide_d32": cfg(
        large_n_x=12, large_n_y=8, large_n_z=18, large_d=32, large_m=18, large_b=8,
        large_p=15, large_omega=19, large_r=64, log_two_t_inc=4, v_min=-6, v_max=9,
        large_u_max=32, gamma_star=11, gamma_0=8, k_prime_prime_vector=[14],
        image="scene", seed=11),
    # Image of width one (reduced prediction and column-oriented local sums are mandatory)
    "c12_single_column": cfg(
        large_n_x=1, large_n_y=64, large_n_z=8, large_d=16, large_m=8, large_b=2,
        large_p=2, prediction_mode=1, local_sum_type=3, large_omega=11, large_r=32, log_two_t_inc=4,
        v_min=-1, v_max=2,
        large_u_max=16, gamma_star=6, gamma_0=1, k_prime_prime_vector=[5],
        image="scene", seed=12),
    # Single band without inter-band prediction, hybrid coder on a low-entropy image (low-entropy codes)
    "c13_single_band_hybrid": cfg(
        large_n_x=48, large_n_y=32, large_n_z=1, large_d=12, large_m=1, large_b=1,
        large_p=0, large_omega=10, large_r=32, log_two_t_inc=4, v_min=-3, v_max=3,
        entropy_coder_type=1, large_u_max=12, gamma_star=5, gamma_0=1, hybrid_initial_accumulator=[0],
        image="flat", seed=13),
    # Supplementary information tables in the header (unsigned 1-D, signed 0-D, float 2-D-zx, unsigned 2-D-yx)
    "c14_supplementary_tables": cfg(
        large_n_x=12, large_n_y=8, large_n_z=6, large_d=16, large_m=6, large_b=4, user_defined_data=171,
        large_p=2, large_omega=13, large_r=32, log_two_t_inc=5, v_min=-1, v_max=3,
        large_u_max=16, gamma_star=6, gamma_0=2, k_prime_prime_vector=[3],
        supplementary_information_tables=[
            {"type": 0, "purpose": 2, "structure": 1, "user_data": 3, "di": 12,
             "data": [400 + 25 * z for z in range(6)]},
            {"type": 1, "purpose": 1, "structure": 0, "user_data": 0, "di": 9, "data": [-200]},
            {"type": 2, "purpose": 0, "structure": 2, "user_data": 15, "df": 10, "de": 5, "beta": 15,
             "data": [((z + x) % 2, 10 + (z % 5), (37 * z + 11 * x) % 1024) for z in range(6) for x in range(12)]},
            {"type": 0, "purpose": 4, "structure": 3, "user_data": 9, "di": 1,
             "data": [1 if (x * 7 + y * 3) % 23 == 0 else 0 for y in range(8) for x in range(12)]},
        ],
        image="scene", seed=14),
    # Uncorrelated full-range noise: unary length limit (escape codewords) and fast statistics rescaling
    "c15_noise_escape": cfg(
        large_n_x=16, large_n_y=8, large_n_z=8, large_d=16, large_m=8, large_b=1,
        large_p=1, large_omega=8, large_r=32, log_two_t_inc=4, v_min=-6, v_max=9,
        large_u_max=8, gamma_star=4, gamma_0=1, k_prime_prime_vector=[0],
        image="noise", seed=15),
    # Band-dependent absolute error limits from 0 to 255: low-entropy statistics that select all 16 low-entropy codes
    # of the hybrid coder, escape symbols and flush words of many active prefixes
    "c16_hybrid_low_entropy": cfg(
        large_n_x=32, large_n_y=16, large_n_z=16, large_d=12, large_m=16, large_b=1,
        large_p=2, large_omega=10, large_r=32, log_two_t_inc=4, v_min=-2, v_max=3,
        quantizer_fidelity_control_method=1, absolute_error_limit_assignment_method=1, large_d_large_a=8,
        a_vector=[0, 3, 6, 12, 24, 48, 96, 160, 255],
        entropy_coder_type=1, large_u_max=12, gamma_star=5, gamma_0=1, hybrid_initial_accumulator=[0],
        image="scene", seed=16),
    # Constant bands with rare outliers in BSQ order: long runs of all-zeros blocks, remainder of segment, a reference
    # sample interval of 70 blocks (segments of 64 and 6 blocks)
    "c17_block_zero_runs": cfg(
        large_n_x=40, large_n_y=24, large_n_z=4, large_d=12, sample_encoding_order=1, large_m=0, large_b=2,
        large_p=1, large_omega=8, large_r=32, log_two_t_inc=4, v_min=-6, v_max=-2,
        entropy_coder_type=2, large_j=8, r=70,
        image="constant", seed=17),
    # 24-bit signed samples, noise in every second band: no-compression option and split-sample options with 5-bit
    # option identifiers, J = 32
    "c18_block_d24_mixed": cfg(
        large_n_x=16, large_n_y=8, large_n_z=12, large_d=24, sample_type=1, large_m=12, large_b=3,
        large_p=2, large_omega=12, large_r=48, log_two_t_inc=4, v_min=-2, v_max=4,
        entropy_coder_type=2, large_j=32, r=4096,
        image="mixed", seed=18),
    # 2-bit samples with the restricted set of code options (1-bit option identifiers), periodic band-dependent
    # absolute error limits in the block-adaptive coder input; vmax = 9 with Omega = 4: weight increments vanish
    "c19_block_restricted_d2": cfg(
        large_n_x=24, large_n_y=16, large_n_z=6, large_d=2, large_m=3, large_b=1,
        large_p=2, large_omega=4, large_r=32, log_two_t_inc=4, v_min=-6, v_max=9,
        quantizer_fidelity_control_method=1, periodic_updating_flag=1, u=2,
        absolute_error_limit_assignment_method=1, large_d_large_a=1, a_vector=[0],
        entropy_coder_type=2, large_j=16, restricted_code_options_flag=1, r=8,
        image="scene", seed=19),
    # 28-bit samples with the hybrid coder: initial accumulators of up to 2^(D + gamma0) - 1 = 2^33 - 1, final
    # accumulators of 2 + D + gamma* = 40 bits in the tail
    "c20_hybrid_d28": cfg(
        large_n_x=12, large_n_y=10, large_n_z=6, large_d=28, large_m=6, large_b=5,
        large_p=3, large_omega=14, large_r=50, log_two_t_inc=5, v_min=-1, v_max=3,
        entropy_coder_type=1, large_u_max=24, gamma_star=10, gamma_0=5,
        hybrid_initial_accumulator=[8589934591, 4294967296, 3000000000, 123456789, 0, 2147483648],
        image="scene", seed=20),
    # Sample-adaptive coder with periodic error limit updating every frame: band-independent absolute and
    # band-dependent relative error limits in the body, BIL
    "c21_sample_periodic": cfg(
        large_n_x=20, large_n_y=8, large_n_z=6, large_d=14, large_m=1, large_b=2,
        large_p=2, prediction_mode=1, local_sum_type=2, large_omega=11, large_r=36, log_two_t_inc=4, v_min=-2,
        v_max=3, quantizer_fidelity_control_method=3, periodic_updating_flag=1, u=0,
        absolute_error_limit_assignment_method=0, large_d_large_a=4,
        relative_error_limit_assignment_method=1, large_d_large_r=7,
        large_u_max=14, gamma_star=6, gamma_0=2, k_prime_prime_vector=[5],
        image="scene", seed=21),
    # Image of a single pixel per band: only uncoded first samples; the hybrid coder tail holds the initial
    # accumulators
    "c22_single_pixel_hybrid": cfg(
        large_n_x=1, large_n_y=1, large_n_z=6, large_d=16, large_m=6, large_b=4,
        large_p=2, prediction_mode=1, local_sum_type=3, large_omega=8, large_r=32, log_two_t_inc=4, v_min=-1,
        v_max=2,
        entropy_coder_type=1, large_u_max=16, gamma_star=6, gamma_0=3,
        hybrid_initial_accumulator=[0, 17, 300, 5000, 77, 1],
        image="scene", seed=22),
    # Three-bit samples with the largest weight resolution and the smallest scaling exponents: weight increments
    # beyond the weight range (saturation)
    "c23_extreme_weights": cfg(
        large_n_x=16, large_n_y=8, large_n_z=4, large_d=3, large_m=4, large_b=1,
        large_p=2, large_omega=19, large_r=32, log_two_t_inc=11, v_min=-6, v_max=-6,
        weight_exponent_offset_flag=1, weight_exponent_offset_table_flag=1, zeta_vector=[-6],
        large_u_max=8, gamma_star=4, gamma_0=1, k_prime_prime_vector=[1],
        image="noise", seed=23),
    # Reduced prediction without inter-band prediction (P = 0): no weights, the prediction is the local sum
    "c24_reduced_p0": cfg(
        large_n_x=24, large_n_y=12, large_n_z=3, large_d=10, large_m=3, large_b=2,
        large_p=0, prediction_mode=1, local_sum_type=2, large_omega=8, large_r=32, log_two_t_inc=4, v_min=-1,
        v_max=2,
        entropy_coder_type=2, large_j=8, r=16,
        image="scene", seed=24),
    # Throughput: BSQ order, lossless, reduced prediction with P = 3 and narrow local sums, 16-bit samples, Omega = 19,
    # R = 48: one sample per clock cycle with the speculative weight loop
    "c25_tp_bsq_lossless": cfg(
        large_n_x=32, large_n_y=12, large_n_z=6, large_d=16, sample_encoding_order=1, large_m=0, large_b=4,
        large_p=3, prediction_mode=1, local_sum_type=1, large_omega=19, large_r=48, log_two_t_inc=6, v_min=-1,
        v_max=3,
        large_u_max=18, gamma_star=6, gamma_0=1, k_prime_prime_vector=[5],
        image="scene", seed=25),
    # Throughput: BIL order (M = 1), near-lossless with an absolute error limit and sample representatives, reduced
    # prediction with P = 3, narrow column-oriented local sums, hybrid coder: one sample per clock cycle with the
    # speculative weight loop
    "c26_tp_bil_near_abs": cfg(
        large_n_x=40, large_n_y=8, large_n_z=6, large_d=16, large_m=1, large_b=4,
        large_p=3, prediction_mode=1, local_sum_type=3, large_omega=19, large_r=48, log_two_t_inc=6, v_min=-1,
        v_max=3,
        quantizer_fidelity_control_method=1, large_d_large_a=10, a_vector=[12],
        sample_representative_flag=1, large_theta=2, phi_vector=[2], psi_vector=[1],
        entropy_coder_type=1, large_u_max=16, gamma_star=6, gamma_0=2, hybrid_initial_accumulator=[300],
        image="scene", seed=26),
    # Throughput: BIP with 24 bands, full prediction with P = 3, wide neighbor-oriented local sums, block-adaptive
    # coder: one sample per clock cycle through the weight memory
    "c27_tp_bip_full": cfg(
        large_n_x=16, large_n_y=8, large_n_z=24, large_d=16, large_m=24, large_b=4,
        large_p=3, large_omega=19, large_r=64, log_two_t_inc=6, v_min=-1, v_max=3,
        entropy_coder_type=2, large_j=16, r=32,
        image="scene", seed=27),
    # Throughput: BSQ order, near-lossless with an absolute error limit, reduced prediction with P = 2 and narrow
    # neighbor-oriented local sums, 12-bit samples: one sample per clock cycle with the speculative weight loop
    "c28_tp_bsq_near_abs": cfg(
        large_n_x=40, large_n_y=6, large_n_z=4, large_d=12, sample_encoding_order=1, large_m=0, large_b=2,
        large_p=2, prediction_mode=1, local_sum_type=1, large_omega=15, large_r=48, log_two_t_inc=5, v_min=-2,
        v_max=3,
        quantizer_fidelity_control_method=1, large_d_large_a=6, a_vector=[3],
        large_u_max=16, gamma_star=6, gamma_0=1, k_prime_prime_vector=[3],
        image="scene", seed=28),
    # Throughput: BIP with 40 bands, near-lossless with an absolute error limit and sample representatives, full
    # prediction with P = 3: the stride order processes the bands of a pixel S bands apart
    "c29_tp_bip_near_stride": cfg(
        large_n_x=12, large_n_y=6, large_n_z=40, large_d=12, large_m=40, large_b=2,
        large_p=3, large_omega=14, large_r=48, log_two_t_inc=5, v_min=-1, v_max=3,
        quantizer_fidelity_control_method=1, large_d_large_a=4, a_vector=[2],
        sample_representative_flag=1, large_theta=2, phi_vector=[1], psi_vector=[2],
        large_u_max=16, gamma_star=6, gamma_0=1, k_prime_prime_vector=[3],
        image="scene", seed=29),
    # Throughput: BIP with 48 bands, absolute and relative error limits, reduced prediction with P = 2, narrow
    # column-oriented local sums, hybrid coder: stride order with relative error limits
    "c30_tp_bip_both_stride": cfg(
        large_n_x=10, large_n_y=5, large_n_z=48, large_d=16, large_m=48, large_b=4,
        large_p=2, prediction_mode=1, local_sum_type=3, large_omega=13, large_r=48, log_two_t_inc=5, v_min=-1,
        v_max=3,
        quantizer_fidelity_control_method=3, large_d_large_a=6, a_vector=[20], large_d_large_r=8, r_vector=[30],
        entropy_coder_type=1, large_u_max=16, gamma_star=6, gamma_0=2, hybrid_initial_accumulator=[500],
        image="scene", seed=30),
    # Small images for the error injection and the reset tests; together they have every memory of the core.
    # BI order with M = 2, periodic band-dependent absolute error limits, sample-adaptive coder
    "c31_small_bi_periodic_abs": cfg(
        large_n_x=6, large_n_y=4, large_n_z=6, large_d=12, large_m=2, large_b=2,
        large_p=2, large_omega=12, large_r=40, log_two_t_inc=4, v_min=-1, v_max=3,
        quantizer_fidelity_control_method=1, periodic_updating_flag=1, u=0,
        absolute_error_limit_assignment_method=1, large_d_large_a=3,
        large_u_max=16, gamma_star=6, gamma_0=1, k_prime_prime_vector=[3],
        image="scene", seed=31),
    # BIP, periodic band-dependent relative error limits, reduced prediction, hybrid coder
    "c32_small_bip_periodic_rel": cfg(
        large_n_x=6, large_n_y=4, large_n_z=5, large_d=14, large_m=5, large_b=3,
        large_p=3, prediction_mode=1, local_sum_type=2, large_omega=11, large_r=40, log_two_t_inc=4, v_min=-1,
        v_max=3,
        quantizer_fidelity_control_method=2, periodic_updating_flag=1, u=1,
        relative_error_limit_assignment_method=1, large_d_large_r=5,
        entropy_coder_type=1, large_u_max=16, gamma_star=6, gamma_0=2, hybrid_initial_accumulator=[50],
        image="scene", seed=32),
    # BIP, absolute error limit with sample representatives: stride order, block-adaptive coder
    "c33_small_bip_stride_block": cfg(
        large_n_x=5, large_n_y=4, large_n_z=6, large_d=16, large_m=6, large_b=4,
        large_p=2, large_omega=13, large_r=48, log_two_t_inc=5, v_min=-1, v_max=3,
        quantizer_fidelity_control_method=1, large_d_large_a=4, a_vector=[3],
        sample_representative_flag=1, large_theta=2, phi_vector=[1], psi_vector=[1],
        entropy_coder_type=2, large_j=8, r=4,
        image="scene", seed=33),
    # BSQ, lossless, full prediction (weights in memory), sample-adaptive coder
    "c34_small_bsq_lossless": cfg(
        large_n_x=8, large_n_y=4, large_n_z=4, large_d=10, sample_encoding_order=1, large_m=0, large_b=1,
        large_p=2, large_omega=10, large_r=32, log_two_t_inc=4, v_min=-2, v_max=3,
        large_u_max=12, gamma_star=5, gamma_0=1, k_prime_prime_vector=[2],
        image="scene", seed=34),
    # BIL with periodic updating of band-dependent absolute error limits every row, reduced prediction with narrow
    # neighbour-oriented local sums: speculative weight loop with error limit values in the sample sequence, one
    # sample per clock cycle
    "c35_small_bil_periodic_spec": cfg(
        large_n_x=40, large_n_y=4, large_n_z=4, large_d=12, large_m=1, large_b=2,
        large_p=2, prediction_mode=1, local_sum_type=1, large_omega=12, large_r=40, log_two_t_inc=4, v_min=-1,
        v_max=3,
        quantizer_fidelity_control_method=1, periodic_updating_flag=1, u=0,
        absolute_error_limit_assignment_method=1, large_d_large_a=3,
        large_u_max=16, gamma_star=6, gamma_0=1, k_prime_prime_vector=[3],
        image="scene", seed=35),
    # Block-adaptive coder with J = 64 in BSQ order on constant bands with spikes: fundamental sequence options with
    # two long codewords in a row, a run of all-zeros blocks before the last block of the image
    "c36_block_j64_spikes": cfg(
        large_n_x=64, large_n_y=8, large_n_z=2, large_d=12, sample_encoding_order=1, large_m=0, large_b=2,
        large_p=0, prediction_mode=1, local_sum_type=0, large_omega=8, large_r=32, log_two_t_inc=4, v_min=-1,
        v_max=2,
        entropy_coder_type=2, large_j=64, r=4096,
        image="spikes", seed=36),
    # Block-adaptive coder with D = 32 on uncorrelated noise: split-sample options with k >= 25 (fewer than four sets of
    # split bits per codeword); custom weight initialization with Q = Omega + 3 (no fill bits)
    "c37_block_d32_custom": cfg(
        large_n_x=8, large_n_y=4, large_n_z=3, large_d=32, sample_encoding_order=1, large_m=0, large_b=4,
        large_p=1, large_omega=19, large_r=64, log_two_t_inc=4, v_min=-1, v_max=3,
        weight_initialization_method=1, weight_initialization_table_flag=1, large_q=22,
        large_lambda_vector=[w for z in range(3)
                             for w in [(5 - z % 3) << 12, (-3 + z % 2) << 12, 1 << 12] + ([100 << 12] if z else [])],
        entropy_coder_type=2, large_j=16, r=4096,
        image="midnoise", seed=37),
}


# ------------------------------------------------------------------------------------------------
# Random configurations
# ------------------------------------------------------------------------------------------------
def random_sup_table(rng, nx, ny, nz):
    """Supplementary information table with random type, structure and content (CCSDS 3.5, 5.3.2.3; the purposes
    5 to 9 are reserved)."""
    t = {"type": rng.choice([0, 1, 2]), "purpose": rng.choice([0, 1, 2, 3, 4] + list(range(10, 16))),
         "structure": rng.randint(0, 3), "user_data": rng.randint(0, 15)}
    n = [1, nz, nz * nx, ny * nx][t["structure"]]
    if t["type"] == 2:
        t.update(df=rng.randint(1, 23), de=rng.randint(2, 8))
        t["beta"] = rng.randint(0, (1 << t["de"]) - 2)
        t["data"] = [(rng.randint(0, 1), rng.randint(0, (1 << t["de"]) - 2), rng.randint(0, (1 << t["df"]) - 1))
                     for _ in range(n)]
    else:
        di = rng.randint(1, 32)
        t["di"] = di
        if t["type"] == 0:
            t["data"] = [rng.randint(0, (1 << di) - 1) for _ in range(n)]
        else:
            t["data"] = [rng.randint(-(1 << (di - 1)), (1 << (di - 1)) - 1) for _ in range(n)]
    return t


def random_config(seed, max_samples=480):
    """Configuration with random values of all parameters in the ranges of CCSDS 123.0-B-2 and a small image."""
    rng = random.Random(seed)
    pick = rng.choice
    # Image: sometimes a single column, row or band
    while True:
        nx = 1 if rng.random() < 0.08 else rng.randint(2, 24)
        ny = 1 if rng.random() < 0.08 else rng.randint(2, 16)
        nz = 1 if rng.random() < 0.08 else rng.randint(2, 24)
        if nx * ny * nz <= max_samples:
            break
    d = pick([2, 3, 4, 5, 8, 10, 12, 14, 16, 16, 16, 18, 20, 22, 24, 26, 28, 30, 31, 32])
    bsq = rng.random() < 0.3
    c = cfg(large_n_x=nx, large_n_y=ny, large_n_z=nz, large_d=d, sample_type=rng.randint(0, 1),
            sample_encoding_order=int(bsq), large_m=0 if bsq else rng.randint(1, nz), large_b=rng.randint(1, 8),
            user_defined_data=rng.randint(0, 255), image=pick(["scene", "scene", "noise", "constant", "mixed", "flat",
                                                               "stripes"]),
            seed=seed)
    # Predictor (NX = 1: reduced mode and column-oriented local sums, CCSDS 4.4, 4.5)
    p = rng.randint(0, 15)
    full = nx > 1 and rng.random() < 0.5
    omega = rng.randint(4, 19)
    vmin = rng.randint(-6, 9)
    c.update(large_p=p, prediction_mode=0 if full else 1,
             local_sum_type=rng.choice([2, 3]) if nx == 1 else rng.randint(0, 3),
             large_omega=omega, large_r=rng.randint(max(32, d + omega + 2), 64), log_two_t_inc=rng.randint(4, 11),
             v_min=vmin, v_max=rng.randint(vmin, 9))
    nw = [min(z, p) + (3 if full else 0) for z in range(nz)]
    nzeta = sum(min(z, p) + (1 if full else 0) for z in range(nz))
    if nzeta and rng.random() < 0.3:
        c.update(weight_exponent_offset_flag=1, weight_exponent_offset_table_flag=rng.randint(0, 1),
                 zeta_vector=[rng.randint(-6, 5) for z in range(nz) for _ in range(min(z, p) + (1 if full else 0))])
    if sum(nw) and rng.random() < 0.25:
        q = rng.randint(3, omega + 3)
        c.update(weight_initialization_method=1, weight_initialization_table_flag=rng.randint(0, 1), large_q=q,
                 large_lambda_vector=[rng.randint(-(1 << (q - 1)), (1 << (q - 1)) - 1) for z in range(nz)
                                      for _ in range(nw[z])])
    # Quantizer (no periodic error limit updating in BSQ order, CCSDS 4.8.2.4.4)
    fid = pick([0, 0, 1, 2, 3])
    c["quantizer_fidelity_control_method"] = fid
    dmax = min(d - 1, 16)
    if fid:
        if not bsq and rng.random() < 0.3:
            c.update(periodic_updating_flag=1, u=rng.randint(0, 3))
        if fid in (1, 3):
            da = rng.randint(1, dmax)
            dep = rng.randint(0, 1)
            c.update(absolute_error_limit_assignment_method=dep, large_d_large_a=da,
                     a_vector=[rng.randint(0, (1 << da) - 1) for _ in range(nz if dep else 1)])
        if fid in (2, 3):
            dr = rng.randint(1, dmax)
            dep = rng.randint(0, 1)
            c.update(relative_error_limit_assignment_method=dep, large_d_large_r=dr,
                     r_vector=[rng.randint(0, (1 << dr) - 1) for _ in range(nz if dep else 1)])
    # Sample representatives (the subpart only with Theta > 0, CCSDS 5.3.3.5.1.1; offsets 0 in lossless
    # compression, CCSDS 4.9.1.2)
    if rng.random() < 0.5:
        theta = rng.randint(1, 4)
        c.update(sample_representative_flag=1, large_theta=theta)
        for flag, table, vec in (("band_varying_damping_flag", "damping_table_flag", "phi_vector"),
                                 ("band_varying_offset_flag", "offset_table_flag", "psi_vector")):
            varying = rng.randint(0, 1)
            top = 0 if vec == "psi_vector" and not fid else (1 << theta) - 1
            c.update({flag: varying, table: rng.randint(0, 1) if varying else 0,
                      vec: [rng.randint(0, top) for _ in range(nz if varying else 1)]})
    # Entropy coder
    coder = rng.randint(0, 2)
    c["entropy_coder_type"] = coder
    if coder in (0, 1):
        g0 = rng.randint(1, 8)
        c.update(large_u_max=rng.randint(8, 32), gamma_0=g0, gamma_star=rng.randint(max(4, g0 + 1), 11))
    if coder == 0:
        kmax = min(d - 2, 14)
        varying = rng.randint(0, 1)
        c.update(band_varying_k_flag=varying, accumulator_initialization_table_flag=rng.randint(0, 1) if varying else 0,
                 k_prime_prime_vector=[rng.randint(0, kmax) for _ in range(nz if varying else 1)])
    if coder == 1:
        top = (1 << (d + c["gamma_0"])) - 1
        c["hybrid_initial_accumulator"] = [rng.choice([0, top, rng.randint(0, top)]) for _ in range(nz)]
    if coder == 2:
        c.update(large_j=pick([8, 16, 32, 64]), restricted_code_options_flag=rng.randint(0, 1) if d <= 4 else 0,
                 r=pick([1, 2, 5, 16, 100, 4096, rng.randint(1, 4096)]))
    # Supplementary information tables
    if rng.random() < 0.15:
        c["supplementary_information_tables"] = [random_sup_table(rng, nx, ny, nz) for _ in range(rng.randint(1, 3))]
    return c


# Bounds of the header fields: user-defined data 255, 15 supplementary information tables, error limit update period
# 2^9, error limit bit depths DA = DR = 16 (D = 20), the accumulator initialization constant K = min(D - 2, 14) and
# the rescaling counter size gamma* = gamma0 + 1 of the sample-adaptive coder
CONFIGS["c38_header_bounds"] = cfg(
    large_n_x=6, large_n_y=3, large_n_z=3, large_d=20, large_m=2, large_b=2, user_defined_data=255,
    supplementary_information_tables=[random_sup_table(random.Random(380 + i), 6, 3, 3) for i in range(15)],
    large_p=2, prediction_mode=1, local_sum_type=1, large_omega=16, large_r=48, log_two_t_inc=4, v_min=-1, v_max=3,
    quantizer_fidelity_control_method=3, periodic_updating_flag=1, u=9,
    absolute_error_limit_assignment_method=1, large_d_large_a=16,
    relative_error_limit_assignment_method=1, large_d_large_r=16,
    large_u_max=32, gamma_star=8, gamma_0=7, k_prime_prime_vector=[14],
    image="scene", seed=38)

# Random configurations of the regression: r<seed>
RANDOM = {"r{:02d}_random".format(s): random_config(s) for s in range(1, 25)}

# All configurations with golden data
ALL = dict(CONFIGS, **RANDOM)

# ------------------------------------------------------------------------------------------------
# Runtime configurations (RuntimeConfig_g): the image dimensions of a configuration are the maxima; every image of a
# sequence takes its own NX, NY, NZ and band-independent error limit values (CO-RC-01, CO-RC-02). In BI order the
# sub-frame interleaving depth of an image is min(M, NZ).
# ------------------------------------------------------------------------------------------------
RUNTIME = {
    # BI with M = 1 (the speculative weight loop; images of one band run across rows), sample-adaptive, lossless
    "rc01_bi_m1_sample": cfg(
        large_n_x=16, large_n_y=12, large_n_z=8, large_d=12, large_m=1, large_b=2,
        large_p=3, large_omega=13, large_r=32, log_two_t_inc=5, v_min=-1, v_max=3,
        large_u_max=16, gamma_star=6, gamma_0=1, k_prime_prime_vector=[3],
        image="scene", seed=101),
    # BI with M = NZ, hybrid coder, absolute error limits, sample representatives: with constant dimensions this
    # configuration uses the stride order
    "rc02_bi_mnz_hybrid_abs": cfg(
        large_n_x=12, large_n_y=8, large_n_z=10, large_d=14, large_m=10, large_b=4,
        large_p=3, large_omega=14, large_r=48, log_two_t_inc=6, v_min=-1, v_max=3,
        quantizer_fidelity_control_method=1, large_d_large_a=6, a_vector=[3],
        sample_representative_flag=1, large_theta=2, phi_vector=[2], psi_vector=[1],
        entropy_coder_type=1, large_u_max=18, gamma_star=6, gamma_0=2,
        hybrid_initial_accumulator=[30, 45, 60, 75, 90, 105, 120, 135, 150, 165],
        image="scene", seed=102),
    # BSQ, narrow neighbor-oriented local sums, block-adaptive coder, relative error limits
    "rc03_bsq_block_rel": cfg(
        large_n_x=10, large_n_y=10, large_n_z=6, large_d=16, sample_encoding_order=1, large_m=0, large_b=1,
        large_p=2, local_sum_type=1, large_omega=12, large_r=40, log_two_t_inc=5, v_min=-2, v_max=4,
        quantizer_fidelity_control_method=2, large_d_large_r=8, r_vector=[20],
        entropy_coder_type=2, large_j=16, r=8,
        image="scene", seed=103),
    # BI with M = 4 (sub-frames), sample-adaptive, absolute and relative error limits
    "rc04_bi_m4_sample_both": cfg(
        large_n_x=16, large_n_y=8, large_n_z=12, large_d=16, large_m=4, large_b=3,
        large_p=4, large_omega=13, large_r=48, log_two_t_inc=6, v_min=-1, v_max=3,
        quantizer_fidelity_control_method=3, large_d_large_a=5, a_vector=[4], large_d_large_r=9, r_vector=[64],
        large_u_max=16, gamma_star=6, gamma_0=1, k_prime_prime_vector=[4],
        image="scene", seed=104),
    # BSQ, reduced prediction, wide column-oriented local sums (images of width 1), hybrid coder, lossless
    "rc05_bsq_column_hybrid": cfg(
        large_n_x=8, large_n_y=8, large_n_z=5, large_d=10, sample_encoding_order=1, large_m=0, large_b=2,
        large_p=2, prediction_mode=1, local_sum_type=2, large_omega=11, large_r=32, log_two_t_inc=4,
        v_min=-1, v_max=3,
        entropy_coder_type=1, large_u_max=14, gamma_star=5, gamma_0=1,
        hybrid_initial_accumulator=[20, 40, 60, 80, 100],
        image="scene", seed=105),
}

# Images per runtime sequence (TC-CO-52) and runtime configurations of the range test (TC-CO-57)
RUNTIME_IMAGES = 20
RUNTIME_RANGE = ["rc04_bi_m4_sample_both", "rc05_bsq_column_hybrid"]
# Images of a runtime sequence that the timing test (TC-CO-53) aborts with an early In_Last (the first is the largest
# image of the sequence)
RUNTIME_ABORT = [0, 6]
# Runtime configurations of the queue test (TC-CO-58): one with the hybrid coder (its tail pointer) and one without
RUNTIME_QUEUE = ["rc03_bsq_block_rel", "rc05_bsq_column_hybrid"]
# Runtime configuration of the queue test only (not in RUNTIME): the hybrid coder with 128 bands and flat images, so
# that the short body of an image fits into the codeword buffers but its tail (one accumulator per band) does not, and
# the queue fills behind the tail pointer while the header pointer has room (TC-CO-58)
RUNTIME_QUEUE_ONLY = {
    "rq06_bsq_column_hybrid_nz128": dict(RUNTIME["rc05_bsq_column_hybrid"], large_n_z=128, seed=106, image="flat",
                                         hybrid_initial_accumulator=[20 + 10 * (z % 64) for z in range(128)]),
}
# Queue configurations whose first image has the maximum number of bands (a long tail of the hybrid coder)
QUEUE_LONG_TAIL = ["rq06_bsq_column_hybrid_nz128"]


def queue_configs():
    """Name and configuration of every runtime configuration of the queue test."""
    out = {name: RUNTIME[name] for name in RUNTIME_QUEUE}
    out.update(RUNTIME_QUEUE_ONLY)
    return out
# Images of the queue test: smallest images first (more than the 16 entries of the configuration queue), then a few
# larger ones
QUEUE_SMALL = 24
QUEUE_LARGE = 4


def width_one_allowed(c):
    """Images of width 1 need reduced prediction and column-oriented local sums (CCSDS 4.3.1, 4.4.1)."""
    return c["prediction_mode"] == 1 and c["local_sum_type"] in (2, 3)


def runtime_limit(c, nx, ny, nz, a, r):
    """Values that the core takes for configuration inputs outside their ranges (CO-RC-07): NX, NY, NZ to 1 or to the
    maximum, NX = 1 to 2 where images must be at least two samples wide, error limit values to 2^DA - 1 and
    2^DR - 1; the error limit value of a method not in use is 0."""
    fid = c["quantizer_fidelity_control_method"]
    nx = min(max(nx, 1), c["large_n_x"])
    if nx == 1 and not width_one_allowed(c):
        nx = 2
    ny = min(max(ny, 1), c["large_n_y"])
    nz = min(max(nz, 1), c["large_n_z"])
    a = min(a, (1 << c["large_d_large_a"]) - 1) if fid in (1, 3) else 0
    r = min(r, (1 << c["large_d_large_r"]) - 1) if fid in (2, 3) else 0
    return nx, ny, nz, a, r


def runtime_image_cfg(c, nx, ny, nz, a, r, index, params=None):
    """Configuration of image `index` of a runtime sequence with its dimensions and error limit values (seed of the
    test image from the configuration and the index); with params (the values taken, PARAM_NAMES) also its runtime
    parameters."""
    d = dict(c)
    d.update(large_n_x=nx, large_n_y=ny, large_n_z=nz, seed=1000 * c["seed"] + index)
    if c["sample_encoding_order"] == 0:
        d["large_m"] = min(c["large_m"], nz)
    if c["quantizer_fidelity_control_method"] in (1, 3):
        d["a_vector"] = [a]
    if c["quantizer_fidelity_control_method"] in (2, 3):
        d["r_vector"] = [r]
    if params is not None:
        p = dict(zip(PARAM_NAMES, params))
        use = params_in_use(c)
        d.update(user_defined_data=p["user"], log_two_t_inc=p["tinc"], v_min=p["vmin"], v_max=p["vmax"])
        if use["m"]:
            d["large_m"] = p["m"]
        if use["adp"]:
            d.update(large_u_max=p["umax"], gamma_0=p["g0"], gamma_star=p["gstar"])
        if use["k"]:
            d["k_prime_prime_vector"] = [p["k"]]
        if use["r"]:
            d["r"] = p["r"]
    return d


def runtime_sequence(c, n=RUNTIME_IMAGES):
    """Seeded sequence of n images (nx, ny, nz, a, r) within the maxima and the bit depths of a runtime configuration:
    the first images take the bounds (1, or 2 where width 1 is not allowed, and the maximum of every dimension, the
    error limit values 0 and the maxima), single-pixel images included; the others are random."""
    rng = random.Random(7000 + c["seed"])
    fid = c["quantizer_fidelity_control_method"]
    xmin = 1 if width_one_allowed(c) else 2
    amax = (1 << c["large_d_large_a"]) - 1 if fid in (1, 3) else 0
    rmax = (1 << c["large_d_large_r"]) - 1 if fid in (2, 3) else 0
    mx, my, mz = c["large_n_x"], c["large_n_y"], c["large_n_z"]
    seq = [(mx, my, mz, amax, rmax), (xmin, 1, 1, 0, 0), (mx, 1, mz, amax, 0), (xmin, my, 1, 0, rmax),
           (xmin, 1, mz, amax, rmax), (mx, my, 1, 0, 0), (xmin, my, mz, amax, rmax), (mx, 1, 1, 0, rmax)]
    while len(seq) < n:
        seq.append((rng.randint(xmin, mx), rng.randint(1, my), rng.randint(1, mz), rng.randint(0, amax),
                    rng.randint(0, rmax)))
    return [runtime_limit(c, *img) for img in seq[:n]]


def runtime_queue_sequence(c, long_tail=False):
    """Images of the queue test (TC-CO-58): QUEUE_SMALL images of the smallest size (1 or 2 x 1 x 1) with random error
    limit values, then QUEUE_LARGE random images; with long_tail one image of the smallest width with all bands
    first. Each entry is (driven values, values taken by the core)."""
    rng = random.Random(9000 + c["seed"])
    fid = c["quantizer_fidelity_control_method"]
    xmin = 1 if width_one_allowed(c) else 2
    amax = (1 << c["large_d_large_a"]) - 1 if fid in (1, 3) else 0
    rmax = (1 << c["large_d_large_r"]) - 1 if fid in (2, 3) else 0
    seq = [(xmin, 1, c["large_n_z"], amax, rmax)] if long_tail else []
    seq += [(xmin, 1, 1, rng.randint(0, amax), rng.randint(0, rmax)) for _ in range(QUEUE_SMALL)]
    seq += [(rng.randint(xmin, c["large_n_x"]), rng.randint(1, c["large_n_y"]), rng.randint(1, c["large_n_z"]),
             rng.randint(0, amax), rng.randint(0, rmax)) for _ in range(QUEUE_LARGE)]
    return [(d, runtime_limit(c, *d)) for d in seq]


def runtime_range_sequence(c):
    """Images of the range test (TC-CO-57): the values driven on the configuration inputs, outside their ranges alone
    and together, between images with valid values; each entry is (driven values, values taken by the core)."""
    fid = c["quantizer_fidelity_control_method"]
    mx, my, mz = c["large_n_x"], c["large_n_y"], c["large_n_z"]
    da, dr = c["large_d_large_a"], c["large_d_large_r"]
    a_ok = 1 if fid in (1, 3) else 0
    r_ok = 1 if fid in (2, 3) else 0
    ok = (min(3, mx), min(2, my), min(3, mz), a_ok, r_ok)
    top = (1 << 17) - 1
    driven = [ok, (0, 0, 0, 0, 0), ok, (mx + 1, my + 1, mz + 1, 1 << da, 1 << dr), ok, (top, top, top, 65535, 65535),
              (0, my, mz + 1, 0, 0), (top, 0, 1, 1 << da, 0), (mx + 1, 1, 0, 0, 1 << dr), (1, my, mz, a_ok, r_ok),
              (1, 1, 1, 65535, 0), ok]
    return [(d, runtime_limit(c, *d)) for d in driven]


# ------------------------------------------------------------------------------------------------
# Runtime parameters (RuntimeParams_g): every image of a sequence also takes its own user-defined data, M (BI order),
# weight update parameters and entropy coder parameters (CO-RP-01). The values of a configuration are those after a
# reset and the maxima of M (SubFrameDepth_g), gamma* (RescaleCounterSize_g) and r (RefInterval_g).
# ------------------------------------------------------------------------------------------------
RUNTIME_PARAMS = {
    # BI with sub-frames up to M = 4, sample-adaptive coder with an accumulator initialisation constant
    "rp01_bi_m4_sample": dict(RUNTIME["rc04_bi_m4_sample_both"], gamma_star=11, seed=111),
    # BI with M up to NZ, hybrid coder; an initial accumulator of 2^15 or more raises the smallest gamma0 to 2
    "rp02_bi_mnz_hybrid": dict(RUNTIME["rc02_bi_mnz_hybrid_abs"], gamma_star=11, seed=112,
                               hybrid_initial_accumulator=[30, 45, 60, 75, 90, 105, 120, 135, 150, 40000]),
    # BSQ, block-adaptive coder with r up to 4096
    "rp03_bsq_block": dict(RUNTIME["rc03_bsq_block_rel"], r=4096, seed=113),
}
# Runtime parameter configurations of the queue test (TC-CO-61): the read pointer of the hybrid coder (its tail) and
# that of the sample-adaptive and the block-adaptive coder
RUNTIME_PARAMS_QUEUE = list(RUNTIME_PARAMS)

# Runtime parameters in the order of the lines of the image lists (driven, then taken)
PARAM_NAMES = ["user", "m", "tinc", "vmin", "vmax", "umax", "g0", "gstar", "k", "r"]


def params_in_use(c):
    """Runtime parameters in use (CO-RP-01): M in BI order; Umax, gamma0 and gamma* with the sample-adaptive and the
    hybrid coder; K with the sample-adaptive coder and an accumulator initialisation constant; r with the
    block-adaptive coder."""
    ec = c["entropy_coder_type"]
    return {"m": c["sample_encoding_order"] == 0, "adp": ec in (0, 1),
            "k": ec == 0 and not c["band_varying_k_flag"], "r": ec == 2}


def g0_min(c):
    """Smallest gamma0 (CO-RP-02): with the hybrid coder every initial accumulator below 2^(D + gamma0) (CCSDS
    5.4.3.3.4.3), else 1; 9 when there is none."""
    if c["entropy_coder_type"] != 1:
        return 1
    acc = c["hybrid_initial_accumulator"]
    peak = max(acc[min(z, len(acc) - 1)] for z in range(c["large_n_z"]))
    for g in range(1, 9):
        if peak < 1 << (c["large_d"] + g):
            return g
    return 9


def param_bounds(c, nz):
    """Ranges (low, high) of the runtime parameters in use for an image with nz bands, the dependent ones (vmax,
    gamma*) for the lowest value of the parameter they depend on (CO-RP-02)."""
    use = params_in_use(c)
    b = {"user": (0, 255), "tinc": (4, 11), "vmin": (-6, 9), "vmax": (-6, 9)}
    if use["m"]:
        b["m"] = (1, min(c["large_m"], nz))
    if use["adp"]:
        b.update(umax=(8, 32), g0=(g0_min(c), min(8, c["gamma_star"] - 1)), gstar=(4, c["gamma_star"]))
    if use["k"]:
        b["k"] = (0, min(c["large_d"] - 2, 14))
    if use["r"]:
        b["r"] = (1, c["r"])
    return b


def runtime_params_limit(c, nz, p):
    """Values that the core takes for runtime parameter inputs (CO-RP-02): every parameter in use to the nearest value
    of its range, gamma* after gamma0, vmax after vmin, M after NZ (nz: the NZ taken); a parameter not in use is 0
    (the Act_ outputs)."""
    v = dict(zip(PARAM_NAMES, p))
    use = params_in_use(c)

    def lim(x, lo, hi):
        return min(max(x, lo), hi)

    out = dict.fromkeys(PARAM_NAMES, 0)
    out["user"] = v["user"]
    out["tinc"] = lim(v["tinc"], 4, 11)
    out["vmin"] = lim(v["vmin"], -6, 9)
    out["vmax"] = lim(v["vmax"], out["vmin"], 9)
    if use["m"]:
        out["m"] = lim(v["m"], 1, min(c["large_m"], nz))
    if use["adp"]:
        out["umax"] = lim(v["umax"], 8, 32)
        out["g0"] = lim(v["g0"], g0_min(c), min(8, c["gamma_star"] - 1))
        out["gstar"] = lim(v["gstar"], max(4, out["g0"] + 1), c["gamma_star"])
    if use["k"]:
        out["k"] = lim(v["k"], 0, min(c["large_d"] - 2, 14))
    if use["r"]:
        out["r"] = lim(v["r"], 1, c["r"])
    return tuple(out[n] for n in PARAM_NAMES)


def random_params(c, nz, rng, edge=None):
    """Valid runtime parameters for an image with nz bands: random, or with edge "low" or "high" every parameter at
    the bound of its range (the dependent ones against the value they depend on); random values on the inputs of the
    parameters not in use (ignored by the core)."""
    b = param_bounds(c, nz)
    v = {}
    for n in ["user", "m", "tinc", "vmin", "umax", "g0", "k", "r"]:
        if n not in b:
            continue
        lo, hi = b[n]
        v[n] = lo if edge == "low" else hi if edge == "high" else rng.randint(lo, hi)
    vlo = v["vmin"]
    v["vmax"] = vlo if edge == "low" else 9 if edge == "high" else rng.randint(vlo, 9)
    if "g0" in v:
        glo = max(4, v["g0"] + 1)
        v["gstar"] = glo if edge == "low" else c["gamma_star"] if edge == "high" else rng.randint(glo, c["gamma_star"])
    ignored = {"m": (0, (1 << 17) - 1), "umax": (0, 63), "g0": (0, 15), "gstar": (0, 15), "k": (0, 15),
               "r": (0, (1 << 13) - 1)}
    for n, (lo, hi) in ignored.items():
        if n not in v:
            v[n] = rng.randint(lo, hi)
    return tuple(v[n] for n in PARAM_NAMES)


def runtime_params_sequence(c, n=RUNTIME_IMAGES):
    """Images of the runtime parameter sequence (TC-CO-59): the dimensions of runtime_sequence and per image the
    runtime parameters, the first two images with every parameter at the high and at the low bound of its range,
    the others random. Each entry is (driven dimensions, taken dimensions, driven parameters, taken parameters)."""
    rng = random.Random(8000 + c["seed"])
    out = []
    for k, dims in enumerate(runtime_sequence(c, n)):
        edge = "high" if k == 0 else "low" if k == 1 else None
        p = random_params(c, dims[2], rng, edge)
        out.append((dims, dims, p, runtime_params_limit(c, dims[2], p)))
    return out


def runtime_params_queue_sequence(c):
    """Images of the queue test with runtime parameters (TC-CO-61): the images of runtime_queue_sequence, each with
    its own random runtime parameters."""
    rng = random.Random(8500 + c["seed"])
    out = []
    for driven, taken in runtime_queue_sequence(c):
        p = random_params(c, taken[2], rng)
        out.append((driven, taken, p, runtime_params_limit(c, taken[2], p)))
    return out


def runtime_params_range_sequence(c):
    """Images of the range test of the runtime parameters (TC-CO-60): parameters outside their ranges alone and
    together, between images with valid values, among them M above the NZ of an image whose NZ is limited itself.
    Each entry is (driven dimensions, taken dimensions, driven parameters, taken parameters)."""
    use = params_in_use(c)
    mx, my, mz = c["large_n_x"], c["large_n_y"], c["large_n_z"]
    fid = c["quantizer_fidelity_control_method"]
    a_ok = 1 if fid in (1, 3) else 0
    r_ok = 1 if fid in (2, 3) else 0
    ok_dims = (min(3, mx), min(2, my), mz, a_ok, r_ok)
    rng = random.Random(8800 + c["seed"])
    ok = random_params(c, mz, rng)
    names = PARAM_NAMES

    def with_(base, **kw):
        v = dict(zip(names, base))
        v.update(kw)
        return tuple(v[n] for n in names)

    g0hi = min(8, c["gamma_star"] - 1)
    cases = [with_(ok, tinc=3), with_(ok, tinc=12), with_(ok, tinc=15, vmin=-7, vmax=10), with_(ok, tinc=0),
             with_(ok, vmin=10, vmax=-16), with_(ok, vmin=-16, vmax=-7), with_(ok, vmin=5, vmax=4)]
    if use["adp"]:
        cases += [with_(ok, umax=7), with_(ok, umax=33), with_(ok, umax=63), with_(ok, g0=0),
                  with_(ok, g0=9), with_(ok, g0=15, gstar=15), with_(ok, g0=g0hi, gstar=g0hi),
                  with_(ok, gstar=3), with_(ok, gstar=c["gamma_star"] + 1), with_(ok, g0=0, gstar=0, umax=0)]
        if g0_min(c) > 1:
            cases.append(with_(ok, g0=g0_min(c) - 1))
    if use["k"]:
        cases += [with_(ok, k=min(c["large_d"] - 2, 14) + 1), with_(ok, k=15)]
    if use["r"]:
        cases += [with_(ok, r=0), with_(ok, r=c["r"] + 1), with_(ok, r=(1 << 13) - 1)]
    driven = []
    for p in cases:
        driven += [(ok_dims, ok), (ok_dims, p)]
    if use["m"]:
        driven += [(ok_dims, ok), (ok_dims, with_(ok, m=0)), (ok_dims, with_(ok, m=c["large_m"] + 1)),
                   (ok_dims, with_(ok, m=(1 << 17) - 1)), ((ok_dims[0], ok_dims[1], 1) + ok_dims[3:], with_(ok, m=2)),
                   ((ok_dims[0], ok_dims[1], mz + 5) + ok_dims[3:], with_(ok, m=mz + 1)),
                   ((ok_dims[0], ok_dims[1], 0) + ok_dims[3:], with_(ok, m=3))]
    driven.append((ok_dims, ok))
    out = []
    for dims, p in driven:
        taken = runtime_limit(c, *dims)
        out.append((dims, taken, p, runtime_params_limit(c, taken[2], p)))
    return out


# ------------------------------------------------------------------------------------------------
# Test images
# ------------------------------------------------------------------------------------------------
def sample_range(c):
    d = c["large_d"]
    if c["sample_type"]:
        return -(1 << (d - 1)), (1 << (d - 1)) - 1
    return 0, (1 << d) - 1


def make_image(c):
    """Returns img[z][y][x] for a configuration (deterministic)."""
    nx, ny, nz = c["large_n_x"], c["large_n_y"], c["large_n_z"]
    lo, hi = sample_range(c)
    span = hi - lo
    rng = random.Random(c["seed"])
    kind = c["image"]
    img = [[[0] * nx for _ in range(ny)] for _ in range(nz)]
    if kind == "noise":
        for z in range(nz):
            for y in range(ny):
                for x in range(nx):
                    img[z][y][x] = rng.randint(lo, hi)
        return img
    if kind == "constant":
        # Constant bands with rare full-range outliers: long runs of zero mapped quantizer indices
        for z in range(nz):
            for y in range(ny):
                for x in range(nx):
                    img[z][y][x] = lo + (span // 3 + 7 * z) % (span + 1)
                    if rng.random() < 0.002:
                        img[z][y][x] = rng.randint(lo, hi)
        return img
    if kind == "flat":
        # Every sample at the mid value: zero prediction residuals, the shortest codewords
        mid = lo + (span + 1) // 2
        return [[[mid] * nx for _ in range(ny)] for _ in range(nz)]
    if kind == "midnoise":
        # Uncorrelated noise of 1/64 of the range around the mid value
        mid = lo + (span + 1) // 2
        amp = span >> 6
        for z in range(nz):
            for y in range(ny):
                for x in range(nx):
                    img[z][y][x] = mid + rng.randint(-amp, amp)
        return img
    if kind == "spikes":
        # Constant bands at the mid value with spikes of moderate amplitude: a spike and its east neighbour give two
        # long mapped quantizer indices in a row; the spike in the last row follows constant rows
        mid = lo + (span + 1) // 2
        amp = max(1, span // 100)
        for z in range(nz):
            for y in range(ny):
                for x in range(nx):
                    img[z][y][x] = mid
        img[0][ny // 4][min(10, nx - 1)] = mid + amp
        img[0][ny // 4][min(31, nx - 1)] = mid - amp
        img[nz - 1][ny - 1][nx // 2 + min(8, nx // 2 - 1)] = mid + amp
        return img
    if kind == "mixed":
        # Scene in the even bands, uncorrelated noise in the odd bands
        scene = make_image(dict(c, image="scene"))
        for z in range(nz):
            for y in range(ny):
                for x in range(nx):
                    img[z][y][x] = scene[z][y][x] if z % 2 == 0 else rng.randint(lo, hi)
        return img
    # Scene of three materials with smooth spectra, spatial abundance fields, edges and sensor noise
    spectra = []
    for _ in range(3):
        a, b, ph = rng.uniform(0.2, 0.7), rng.uniform(0.05, 0.25), rng.uniform(0, 6.28)
        spectra.append([a + b * math.sin(ph + 3.0 * z / max(nz, 1)) for z in range(nz)])
    stripe = [rng.gauss(0, 0.01) for _ in range(nx)]
    noise = {"scene": 0.002, "stripes": 0.002, "flat": 0.0}[kind]
    for y in range(ny):
        for x in range(nx):
            u = 0.5 + 0.5 * math.sin(0.35 * x + 0.2 * y)
            v = 0.5 + 0.5 * math.cos(0.15 * x - 0.3 * y)
            if (x // 6 + y // 5) % 3 == 0:
                u, v = v, 1.0 - u
            w = max(0.0, 1.0 - u - v * 0.5)
            for z in range(nz):
                val = u * spectra[0][z] + v * spectra[1][z] + w * spectra[2][z]
                val = 0.08 + 0.55 * val
                if kind == "stripes":
                    val += stripe[x] * (1 + 0.1 * z)
                if kind == "flat":
                    val = 0.3 + 0.01 * ((x // 8 + y // 8 + z) % 2)
                    if rng.random() < 0.003:
                        val += 0.05
                val += rng.gauss(0, noise)
                img[z][y][x] = min(hi, max(lo, lo + int(round(val * span))))
    return img


def input_order(c, img):
    """Samples in the input order of the compressor (= entropy coder input order, 5.4.2)."""
    nx, ny, nz = c["large_n_x"], c["large_n_y"], c["large_n_z"]
    out = []
    if c["sample_encoding_order"] == 1:
        for z in range(nz):
            for y in range(ny):
                out += img[z][y]
        return out
    m = c["large_m"]
    for y in range(ny):
        for i in range((nz + m - 1) // m):
            for x in range(nx):
                for z in range(i * m, min((i + 1) * m, nz)):
                    out.append(img[z][y][x])
    return out


def error_limit_updates(c):
    """Periodic error limit values (entropy coder order) of a configuration with periodic updating."""
    if not (c["quantizer_fidelity_control_method"] and c["periodic_updating_flag"]):
        return []
    rng = random.Random(1000 + c["seed"])
    nz = c["large_n_z"]
    vals = []
    for _ in range(0, c["large_n_y"], 1 << c["u"]):
        if c["quantizer_fidelity_control_method"] in (1, 3):
            n = nz if c["absolute_error_limit_assignment_method"] else 1
            vals += [rng.randint(0, (1 << c["large_d_large_a"]) - 1) for _ in range(n)]
        if c["quantizer_fidelity_control_method"] in (2, 3):
            n = nz if c["relative_error_limit_assignment_method"] else 1
            vals += [rng.randint(0, (1 << c["large_d_large_r"]) - 1) for _ in range(n)]
    return vals


def sample_bytes(c):
    """Bytes per sample of the raw image files (8, 16 or 32-bit containers)."""
    d = c["large_d"]
    return 1 if d <= 8 else 2 if d <= 16 else 4
