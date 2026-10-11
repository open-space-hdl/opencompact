# ocp_core: Verification Plan

## 1. Overview

The testbench compresses the test image of a configuration twice in a row and compares both compressed images, byte by
byte and including the last-byte marker, with the compressed image of the CNES reference software
(`tb/golden/<configuration>/compressed.bin`). The error limit values of periodic updating come from the same file as
for the CNES encoder. After the second image the output must stay idle and no memory error may be signalled.

## 2. Test configuration

| Testbench | DUT and environment |
| --- | --- |
| `ocp_core_tb` | `ocp_core` at 100 MHz with the generics of a configuration of `tools/ocp_configs.py`; file-based source of the samples and of the error limits, sink with optional random stalls |

Every configuration is a VUnit configuration of the test `test_golden`; four configurations also run with 30 % input
gaps and 60 % output stalls (suffix `_bp`). Simulator: GHDL.

## 3. Test cases

| Test ID | Description | Requirements |
| --- | --- | --- |
| `test_golden` c01_lossless_bip (TC-CO-01) | Lossless, BIP, sample-adaptive coder, B = 4 | CO-IF-01, CO-IF-02, CO-IF-03, CO-HD-01, CO-HD-02, CO-HD-04, CO-HD-07, CO-PK-01, CO-PK-02, CO-PK-03, EC-IF-01, EC-SA-01, EC-SA-02, EC-SA-03, EC-FT-01 |
| `test_golden` c02_lossless_bil_column (TC-CO-02) | BIL, accumulator initialisation table in the header, B = 2 | CO-HD-02, CO-HD-07, CO-PK-02, EC-SA-02 |
| `test_golden` c03_lossless_bsq_narrow (TC-CO-03) | BSQ (no sub-frame depth), weight exponent offset table in the header, B = 1 | CO-HD-02, CO-HD-04, EC-SA-01 |
| `test_golden` c04_near_abs_hybrid (TC-CO-04) | Quantization subpart with a band-independent absolute limit, sample representative subpart with fixed damping and offset, hybrid coder metadata, B = 8 | CO-HD-05, CO-HD-06, CO-HD-07, CO-PK-02, EC-HY-01, EC-HY-02, EC-HY-03, EC-HY-04 |
| `test_golden` c05_near_rel_bi4_signed (TC-CO-05) | Signed samples, band-dependent relative limits in the header, hybrid coder, B = 3 | CO-HD-02, CO-HD-05, CO-PK-02, EC-HY-01, EC-HY-02, EC-HY-03, EC-HY-04 |
| `test_golden` c06_near_both_block (TC-CO-06) | Absolute and relative limit blocks, damping and offset tables, block-adaptive coder metadata, B = 2 | CO-HD-05, CO-HD-06, CO-HD-07, EC-BA-01, EC-BA-02, EC-BA-03 |
| `test_golden` c07_lossless_block_bsq (TC-CO-07) | Block-adaptive coder, J = 64, zero blocks, remainder of segment | EC-BA-01, EC-BA-02, EC-BA-03 |
| `test_golden` c08_restricted_d4 (TC-CO-08) | D = 4, restricted code options, J = 8 | CO-HD-07, EC-BA-01, EC-BA-03 |
| `test_golden` c09_custom_weights (TC-CO-09) | Weight initialisation table in the header, weight exponent offsets not in the header | CO-HD-04 |
| `test_golden` c10_periodic_limits (TC-CO-10) | Periodic error limit updating: error limit update period block, limit blocks without values, limits in the body | CO-IF-01, CO-HD-05, EC-IF-02 |
| `test_golden` c11_wide_d32 (TC-CO-11) | D = 32 (large dynamic range flag), B = 8 | CO-HD-02, CO-PK-02, EC-SA-01 |
| `test_golden` c12_single_column (TC-CO-12) | NX = 1 | CO-HD-02 |
| `test_golden` c13_single_band_hybrid (TC-CO-13) | NZ = 1, hybrid coder on a low-entropy image | EC-HY-03, EC-HY-04 |
| `test_golden` c14_supplementary_tables (TC-CO-14) | Four supplementary information tables, user-defined data | CO-HD-03 |
| `test_golden` c15_noise_escape (TC-CO-15) | Escape codewords of the sample-adaptive coder | EC-SA-01, EC-SA-03 |
| `test_golden` c16_hybrid_low_entropy (TC-CO-16) | Hybrid coder with all 16 low-entropy codes, escape symbols and flush words of many active prefixes | CO-HD-05, EC-HY-01, EC-HY-02, EC-HY-03, EC-HY-04 |
| `test_golden` c17_block_zero_runs (TC-CO-17) | Block-adaptive coder: runs of all-zeros blocks up to a full segment, remainder of segment, reference interval of 70 blocks | EC-BA-01, EC-BA-02, EC-BA-03 |
| `test_golden` c18_block_d24_mixed (TC-CO-18) | Block-adaptive coder with D = 24: 5-bit option identifiers, no-compression option, split-sample options up to k = 22, J = 32 | CO-HD-02, EC-BA-01, EC-BA-03 |
| `test_golden` c19_block_restricted_d2 (TC-CO-19) | D = 2, restricted set of code options (1-bit identifiers), periodic error limits in the block-adaptive coder input | CO-IF-01, CO-HD-05, EC-BA-01, EC-BA-03 |
| `test_golden` c20_hybrid_d28 (TC-CO-20) | Hybrid coder with D = 28 and gamma0 = 5: initial accumulators up to 2^33 - 1, 40-bit final accumulators in the tail, B = 5 | CO-HD-02, CO-PK-02, EC-HY-01, EC-HY-02, EC-HY-04 |
| `test_golden` c21_sample_periodic (TC-CO-21) | Sample-adaptive coder with periodic error limits in the body: error limit update period block, limit blocks without values | CO-IF-01, CO-HD-05, EC-IF-02, EC-SA-03 |
| `test_golden` c22_single_pixel_hybrid (TC-CO-22) | Image of one pixel per band with the hybrid coder: uncoded samples only, tail with the initial accumulators | CO-HD-02, CO-PK-02, EC-HY-02, EC-HY-04 |
| `test_golden` c23_extreme_weights (TC-CO-23) | D = 3, Omega = 19, weight exponent offset table with -6 | CO-HD-04, EC-SA-01, EC-SA-03 |
| `test_golden` c24_reduced_p0 (TC-CO-24) | Reduced prediction with P = 0, block-adaptive coder with J = 8 and r = 16 | CO-HD-04, EC-BA-01, EC-BA-03 |
| `test_golden` c01_lossless_bip_bp (TC-CO-25) | As TC-CO-01 with input gaps and output stalls | CO-IF-01, CO-IF-02, CO-PK-03 |
| `test_golden` c04_near_abs_hybrid_bp (TC-CO-26) | As TC-CO-04 with input gaps and output stalls | CO-IF-02, CO-PK-03 |
| `test_golden` c06_near_both_block_bp (TC-CO-27) | As TC-CO-06 with input gaps and output stalls | CO-IF-02, CO-PK-03 |
| `test_golden` c10_periodic_limits_bp (TC-CO-28) | As TC-CO-10 with input gaps and output stalls | CO-IF-01, CO-IF-02, CO-PK-03, EC-IF-02 |

## 4. Requirement coverage

| Requirement | Test cases |
| --- | --- |
| CO-IF-01, CO-IF-02 | TC-CO-01, TC-CO-10, TC-CO-19 to TC-CO-28 |
| CO-IF-03 | all (no error; error injection is an open item) |
| CO-HD-01 to CO-HD-07 | TC-CO-01 to TC-CO-24 |
| CO-PK-01 to CO-PK-03 | all (two images per test) |
