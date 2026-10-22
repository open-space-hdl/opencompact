# ocp_predictor: Verification Plan

## 1. Overview

The testbench feeds the test image of a configuration in the input order (and with periodic updating the error limit
values) and compares every item of the entropy coder input sequence with the sequence of the reference model
(`tb/golden/<configuration>/delta.txt`): kind, value, band, first-sample, init and last flags. The reference model
produces the same compressed images as the CNES reference software for every configuration (`tools/golden.py`).
Without back pressure the testbench also counts the cycles between the first and the last accepted sample and, in
stride order, between the first and the last output item, and compares them with the throughput model
(`tools/ocp_throughput.py`).

## 2. Test configuration

| Testbench | DUT and environment |
| --- | --- |
| `ocp_predictor_tb` | `ocp_predictor` at 100 MHz with the generics of a configuration of `tools/ocp_configs.py`; file-based source of the samples and of the error limits, sink with optional random gaps and stalls |
| `ocp_image_start_tb` | The image-start sequencer of the predictor with the dimensions and M as inputs; the reference is the function from which the elaboration computes the conditions of the dependency checks for constant generics |

Every configuration is a VUnit configuration of the test `test_golden`; three configurations also run with 30 % input
gaps and 40 % output stalls (suffix `_bp`). Simulator: GHDL.

## 3. Test cases

| Test ID | Description | Requirements |
| --- | --- | --- |
| `test_golden` c01_lossless_bip (TC-PR-01) | Lossless, BIP, full prediction, wide neighbor-oriented local sums, P = 3 | PR-IF-01, PR-IF-02, PR-IF-03, PR-LS-01, PR-LS-02, PR-LS-03, PR-LS-04, PR-PD-01, PR-PD-02, PR-PD-03, PR-QU-01, PR-QU-02, PR-WU-01, PR-WU-02, PR-MP-01, PR-FT-01 |
| `test_golden` c02_lossless_bil_column (TC-PR-02) | BIL, reduced prediction, wide column-oriented local sums, P = 5, D = 12 | PR-IF-02, PR-LS-01, PR-LS-02, PR-LS-03, PR-PD-03, PR-LS-04, PR-MP-01 |
| `test_golden` c03_lossless_bsq_narrow (TC-PR-03) | BSQ, narrow neighbor-oriented local sums, D = 8, weight exponent offsets | PR-IF-02, PR-LS-03, PR-WU-02, PR-LS-04, PR-MP-01 |
| `test_golden` c04_near_abs_hybrid (TC-PR-04) | Band-independent absolute error limit, sample representatives with damping and offset | PR-QU-01, PR-QU-02, PR-QU-03, PR-SR-01, PR-MP-01 |
| `test_golden` c05_near_rel_bi4_signed (TC-PR-05) | Signed samples, BI with M = 4, band-dependent relative error limits, narrow column-oriented local sums, reduced prediction with weight exponent offsets | PR-IF-01, PR-IF-02, PR-LS-03, PR-QU-02, PR-QU-03, PR-LS-04, PR-MP-01 |
| `test_golden` c06_near_both_block (TC-PR-06) | Absolute and relative error limits, band-dependent absolute limits, band-varying damping and offset | PR-QU-02, PR-QU-03, PR-SR-01, PR-MP-01 |
| `test_golden` c07_lossless_block_bsq (TC-PR-07) | BSQ with P = 1, low-entropy image | PR-IF-02, PR-LS-01 |
| `test_golden` c08_restricted_d4 (TC-PR-08) | D = 4, BIL | PR-IF-01, PR-IF-02 |
| `test_golden` c09_custom_weights (TC-PR-09) | Custom weight initialisation (Q = 10), weight exponent offsets | PR-PD-02, PR-WU-02 |
| `test_golden` c10_periodic_limits (TC-PR-10) | Periodic error limit updating every two frames, BI with M = 2 | PR-IF-04, PR-QU-02, PR-QU-03 |
| `test_golden` c11_wide_d32 (TC-PR-11) | D = 32, P = 15, Omega = 19, R = 64, vmin = -6, vmax = 9 | PR-IF-01, PR-LS-01, PR-PD-01, PR-PD-03, PR-WU-01, PR-MP-01 |
| `test_golden` c12_single_column (TC-PR-12) | NX = 1, reduced prediction, narrow column-oriented local sums | PR-IF-01, PR-LS-02, PR-LS-03, PR-LS-04 |
| `test_golden` c13_single_band_hybrid (TC-PR-13) | NZ = 1, P = 0 | PR-IF-01, PR-LS-01 |
| `test_golden` c14_supplementary_tables (TC-PR-14) | Small image with P = 2 | PR-IF-03 |
| `test_golden` c15_noise_escape (TC-PR-15) | Uncorrelated noise: wrap to R bits, clipping of the prediction, saturated weight increments | PR-PD-03, PR-WU-02 |
| `test_golden` c16_hybrid_low_entropy (TC-PR-16) | Band-dependent absolute error limits from 0 to 255 (DA = 8) | PR-QU-01, PR-QU-02, PR-QU-03, PR-MP-01 |
| `test_golden` c17_block_zero_runs (TC-PR-17) | BSQ, constant bands with outliers | PR-IF-02, PR-PD-03 |
| `test_golden` c18_block_d24_mixed (TC-PR-18) | D = 24 signed, noise in every second band | PR-IF-01, PR-PD-03, PR-WU-02 |
| `test_golden` c19_block_restricted_d2 (TC-PR-19) | D = 2, periodic band-dependent absolute error limits of one bit every four frames, vmax = 9 with Omega = 4: vanishing weight increments | PR-IF-01, PR-IF-04, PR-QU-03, PR-MP-01 |
| `test_golden` c20_hybrid_d28 (TC-PR-20) | D = 28, P = 3, Omega = 14, R = 50 | PR-IF-01, PR-PD-03, PR-MP-01 |
| `test_golden` c21_sample_periodic (TC-PR-21) | Periodic updating every frame with band-independent absolute and band-dependent relative error limits, BIL, reduced prediction | PR-IF-04, PR-QU-02, PR-QU-03, PR-MP-01 |
| `test_golden` c22_single_pixel_hybrid (TC-PR-22) | Image of one pixel per band: only samples with t = 0 | PR-IF-01, PR-IF-03, PR-MP-01 |
| `test_golden` c23_extreme_weights (TC-PR-23) | D = 3, Omega = 19, vmin = vmax = -6, weight exponent offsets -6: weight increments beyond the weight range | PR-PD-01, PR-WU-01, PR-WU-02 |
| `test_golden` c24_reduced_p0 (TC-PR-24) | Reduced prediction with P = 0: no local differences, prediction from the local sum | PR-LS-01, PR-LS-02, PR-PD-03 |
| `test_golden` c25_tp_bsq_lossless (TC-PR-25) | BSQ, lossless, reduced prediction with P = 3, narrow local sums, D = 16, Omega = 19, R = 48: one sample per cycle with the speculative weight loop | PR-IF-02, PR-TP-01, PR-TP-02 |
| `test_golden` c26_tp_bil_near_abs (TC-PR-26) | BIL, absolute error limit with sample representatives, reduced prediction with P = 3, narrow column-oriented local sums: one sample per cycle with the speculative weight loop | PR-QU-02, PR-SR-01, PR-TP-01, PR-TP-02 |
| `test_golden` c27_tp_bip_full (TC-PR-27) | BIP with 24 bands, full prediction with P = 3, Omega = 19, R = 64: one sample per cycle | PR-TP-01 |
| `test_golden` c28_tp_bsq_near_abs (TC-PR-28) | BSQ, absolute error limit, reduced prediction with P = 2, narrow neighbor-oriented local sums: one sample per cycle with the speculative weight loop | PR-QU-02, PR-TP-01, PR-TP-02 |
| `test_golden` c29_tp_bip_near_stride (TC-PR-29) | BIP with 40 bands, absolute error limit with sample representatives, full prediction with P = 3: stride order (S = 37) | PR-SR-01, PR-TP-01, PR-TP-03 |
| `test_golden` c30_tp_bip_both_stride (TC-PR-30) | BIP with 48 bands, absolute and relative error limits, reduced prediction with P = 2, narrow column-oriented local sums: stride order with relative error limits | PR-QU-02, PR-TP-01, PR-TP-03 |
| `test_golden` c01_lossless_bip_bp (TC-PR-31) | As TC-PR-01 with input gaps and output stalls | PR-IF-03, PR-IF-05 |
| `test_golden` c05_near_rel_bi4_signed_bp (TC-PR-32) | As TC-PR-05 with input gaps and output stalls | PR-IF-03 |
| `test_golden` c10_periodic_limits_bp (TC-PR-33) | As TC-PR-10 with input gaps and output stalls | PR-IF-03, PR-IF-04 |
| `test_golden` r01_random to r24_random (TC-PR-34) | Random configurations of `tools/ocp_configs.py` (also lossless compression with damping and NX, NY or NZ of 1); the samples are accepted in the cycles of the throughput model | PR-IF-01, PR-IF-02, PR-IF-03, PR-IF-04, PR-LS-01 to PR-LS-04, PR-PD-01 to PR-PD-03, PR-QU-01 to PR-QU-03, PR-SR-01, PR-WU-01, PR-WU-02, PR-MP-01, PR-TP-01 to PR-TP-03 |
| `test_golden` c31_small_bi_periodic_abs to c34_small_bsq_lossless (TC-PR-35) | Small images: BI order with M = 2 and periodic band-dependent absolute limits, BIP with periodic band-dependent relative limits, stride order, BSQ lossless with full prediction | PR-IF-04, PR-QU-03, PR-TP-03 |
| `test_golden` c35_small_bil_periodic_spec, c36_block_j64_spikes, c37_block_d32_custom (TC-PR-36) | BIL order with periodic updating of band-dependent absolute error limits every row, reduced prediction with P = 2 and narrow neighbour-oriented local sums: the error limit values pass the speculative weight loop at one sample per clock cycle; BSQ order with P = 0 on constant bands with spikes; D = 32 with custom weight initialization, Q = Omega + 3 | PR-IF-04, PR-PD-02, PR-TP-02, PR-WU-02 |
| `test_golden` c29_tp_bip_near_stride_stall, c30_tp_bip_both_stride_stall, c35_small_bil_periodic_spec_stall (TC-PR-37) | 80 % output stalls: the output buffer and the output FIFO of the stride order fill and stop the issue of samples; the output FIFO is full when the error limit values of an update period are due | PR-IF-03, PR-IF-04, PR-TP-03 |
| `test_golden` c38_header_bounds (TC-PR-38) | BI order with M = 2, periodic updating every 2^9 frames of band-dependent absolute and relative error limits with DA = DR = 16 (D = 20) | PR-IF-04, PR-QU-02, PR-QU-03 |
| `test_golden` c13_single_band_hybrid_nospec, c25_tp_bsq_lossless_nospec, c26_tp_bil_near_abs_nospec, c28_tp_bsq_near_abs_nospec, c35_small_bil_periodic_spec_nospec (TC-PR-39) | The configurations of the speculative weight loop with `Speculation_g` = false: the same mapped quantizer indices, and the samples are accepted in the cycles of the throughput model without the loop | PR-TP-01, PR-TP-02, PR-WU-02 |
| TC-PR-40 (`test_sweep` of `ocp_image_start_tb`) | For BI and BSQ order and every combination of NX from 1 to 64, every M from 1 to the maximum NZ and NY in {1, 2, 3, 64}, and in addition the maxima of rc01 to rc05: the conditions computed by the sequencer equal the elaboration function for the same values, and the sequencer needs the same number of cycles for every input | PR-RC-03 |
| TC-PR-41 (`test_runtime` of `ocp_predictor_tb`, rc01 to rc05) | The entropy coder input sequence of every image of the seeded sequence of TC-CO-52 equals `ocp_model`, and the cycles of the input and the image-start cycles equal the throughput model with the runtime dimensions; rc02 runs without stride order | PR-RC-01, PR-RC-02, PR-RC-03, PR-RC-04 |

Every test also checks that no memory error is signalled (PR-FT-01, no error injection) and that no item follows the
last one.

## 4. Requirement coverage

| Requirement | Test cases |
| --- | --- |
| PR-IF-01 | TC-PR-01, TC-PR-05, TC-PR-08, TC-PR-11 to TC-PR-13, TC-PR-18, TC-PR-19 |
| PR-IF-02 | TC-PR-01 to TC-PR-03, TC-PR-05, TC-PR-07, TC-PR-08, TC-PR-17 |
| PR-IF-03 | TC-PR-01, TC-PR-14, TC-PR-31 to TC-PR-33, TC-PR-37 |
| PR-IF-04 | TC-PR-10, TC-PR-19, TC-PR-21, TC-PR-33, TC-PR-35, TC-PR-36, TC-PR-38 |
| PR-IF-05 | TC-PR-31; in the core the header of every image (TC-CO-01 to TC-CO-34) |
| PR-LS-01 to PR-LS-04 | TC-PR-01 to TC-PR-03, TC-PR-05, TC-PR-07, TC-PR-11 to TC-PR-13 |
| PR-PD-01 to PR-PD-03 | TC-PR-01, TC-PR-02, TC-PR-09, TC-PR-11, TC-PR-15 |
| PR-QU-01 to PR-QU-03 | TC-PR-01, TC-PR-04 to TC-PR-06, TC-PR-10, TC-PR-16, TC-PR-19, TC-PR-38 |
| PR-SR-01 | TC-PR-04, TC-PR-06, TC-PR-34 |
| PR-WU-01, PR-WU-02 | TC-PR-01, TC-PR-03, TC-PR-09, TC-PR-11, TC-PR-15 |
| PR-MP-01 | TC-PR-01 to TC-PR-06, TC-PR-11, TC-PR-16, TC-PR-19 (all test cases check the mapped quantizer indices) |
| PR-TP-01 | all test cases without back pressure (cycles of the input against the throughput model), TC-PR-25 to TC-PR-30 |
| PR-TP-02 | TC-PR-13, TC-PR-25, TC-PR-26, TC-PR-28; without the loop (`Speculation_g` false) TC-PR-39 |
| PR-TP-03 | TC-PR-04, TC-PR-06, TC-PR-16, TC-PR-29, TC-PR-30 (cycles of the output against the throughput model) |
| PR-FT-01, PR-FT-02 | TC-CO-37 of `ocp_core` (error injection into every memory); no error in all other test cases |
| PR-RC-01, PR-RC-02 | TC-PR-41; in the core TC-CO-52 |
| PR-RC-03 | TC-PR-40, TC-PR-41; in the core TC-CO-54 |
| PR-RC-04 | TC-PR-41; in the core TC-CO-52 |
