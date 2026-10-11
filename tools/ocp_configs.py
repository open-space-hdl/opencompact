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
}


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
                    img[z][y][x] = lo + span // 3 + 7 * z
                    if rng.random() < 0.002:
                        img[z][y][x] = rng.randint(lo, hi)
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
