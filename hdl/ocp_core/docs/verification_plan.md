# ocp_core: Verification Plan

## 1. Overview

The testbench compresses the test image of a configuration twice in a row and compares both compressed images, byte by
byte and including the last-word marker and the valid bytes of the last word, with the compressed image of the CNES
reference software (`tb/golden/<configuration>/compressed.bin`). The configurations are the 30 configurations that cover
the options of the standard, four configurations with small images for the error injection and the reset tests, two
configurations for rare paths of the speculative weight loop and of the block-adaptive coder (c35 to c37), one
configuration at the bounds of the header fields (c38) and 24 random
configurations (`r01_random` to `r24_random`, all parameters drawn in the ranges of the standard,
`tools/ocp_configs.py`). Locally the testbench also runs a selection of the CCSDS test data set
(`tools/ocp_testvectors.py`): compressed images of randomly chosen configurations whose golden data does not come from
the CNES reference software.

Two further tests run on a selection of configurations: `test_ecc` injects a single and a double bit error into every
memory of the configuration (`ErrInj_Channel`) and checks that a corrected error leaves the compressed image unchanged
and that a double error is signalled; `test_reset` resets the core at random times of an image (header, body, tail)
and checks the next image. The testbench of the bit packer (`ocp_bit_packer_tb`) packs random codewords of random
images and checks every word (`test_random`), and packs an image of numbered bytes to show the position of every byte in
the interface word (`test_byte_order`). The core testbench checks the byte order as well: byte n of a word in bits
8n + 7 to 8n, the valid bytes contiguous from byte 0 and all bytes valid except in the last word of an image. The
interface width changes from configuration to
configuration (8, 16, 32 and 64 bits in turn; 32 bits for the throughput configurations).

Every configuration of `test_golden`, `test_ecc` and `test_reset` runs twice: without the image framing, with random
values on `In_Last`, and with `UseInLast_g` and `In_Last` on the last sample of every image (suffix `_last`).
`test_framing` follows a plan of images with early and missing `In_Last` between correct images: an aborted image
must be its complete header and a prefix of the compressed image of the reference, cut at a codeword, followed by zero
fill bits up to a multiple of B, and every correct image before and after an error must equal the reference. The error
limit values of
periodic updating come from the same file as for the CNES encoder. After the second image the output must stay idle
and no memory error may be signalled. For the throughput configurations the testbench compares the cycles between the
first and the last accepted sample of both images with the throughput model (`tools/ocp_throughput.py`).

## 2. Test configuration

| Testbench | DUT and environment |
| --- | --- |
| `ocp_core_tb` | `ocp_core` at 100 MHz with the generics of a configuration of `tools/ocp_configs.py`; file-based source of the samples and of the error limits, sink with optional random stalls; the test sequencer runs jobs of one or several images, each image with its framing (correct, `In_Last` early at a given sample, `In_Last` missing with a given number of samples to discard), a reset aborts a job; the size of the header (`HeaderBytes_g`, from `tools/ocp_model.py`) for the checks of an aborted image |
| `ocp_bit_packer_tb` | `ocp_bit_packer` with a random source of codewords (lengths 0 to 96 bits) and a sink that builds the expected words from the same random sequence; in `test_byte_order` a source of 8-bit codewords with the values 1, 2, 3, ... |

Every configuration is a VUnit configuration of the test `test_golden`; four configurations also run with 30 % input
gaps and 60 % output stalls (suffix `_bp`), as does every third random configuration. `test_ecc` and `test_reset` run
on the configurations of `ECC` and `RESET` in `hdl/ocp_core/tb/vunit_config.py`; together the configurations of `ECC`
have all 14 memories of the core. The test vectors of the CCSDS test data set run when `OCP_TESTVECTORS` names a
directory prepared by `tools/ocp_testvectors.py` (not in CI). Simulators: GHDL and QuestaSim.

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
| `test_golden` c25_tp_bsq_lossless (TC-CO-25) | Throughput: BSQ with the sample-adaptive coder, one sample per cycle over two images | CO-TP-01, EC-TP-01 |
| `test_golden` c26_tp_bil_near_abs (TC-CO-26) | Throughput: BIL with the hybrid coder, one sample per cycle over two images including the tail | CO-TP-01, EC-TP-01, EC-HY-04 |
| `test_golden` c27_tp_bip_full (TC-CO-27) | Throughput: BIP with the block-adaptive coder (J = 16), one sample per cycle over two images | CO-TP-01, EC-TP-01, EC-BA-03 |
| `test_golden` c28_tp_bsq_near_abs (TC-CO-28) | Throughput: BSQ near-lossless with the sample-adaptive coder, one sample per cycle over two images | CO-TP-01, EC-TP-01 |
| `test_golden` c29_tp_bip_near_stride (TC-CO-29) | Stride order of the predictor with the sample-adaptive coder, two images | CO-PK-03, EC-SA-01 |
| `test_golden` c30_tp_bip_both_stride (TC-CO-30) | Stride order with absolute and relative error limits and the hybrid coder, two images | CO-HD-05, EC-HY-01, EC-HY-04 |
| `test_golden` c01_lossless_bip_bp (TC-CO-31) | As TC-CO-01 with input gaps and output stalls | CO-IF-01, CO-IF-02, CO-PK-03 |
| `test_golden` c04_near_abs_hybrid_bp (TC-CO-32) | As TC-CO-04 with input gaps and output stalls | CO-IF-02, CO-PK-03 |
| `test_golden` c06_near_both_block_bp (TC-CO-33) | As TC-CO-06 with input gaps and output stalls | CO-IF-02, CO-PK-03 |
| `test_golden` c10_periodic_limits_bp (TC-CO-34) | As TC-CO-10 with input gaps and output stalls | CO-IF-01, CO-IF-02, CO-PK-03, EC-IF-02 |
| `test_golden` r01_random to r24_random (TC-CO-35) | Random configurations: images of 1 to 480 samples (also NX, NY or NZ of 1), D from 2 to 32, signed and unsigned, BSQ and BI with random M, B from 1 to 8, P from 0 to 15, both prediction modes, all local sums, Omega from 4 to 19, R from its minimum to 64, weight exponent offsets and custom weights in or outside the header, all fidelity modes with band-dependent or band-independent limits and periodic updating, sample representatives with damping and offset tables, all coders with random parameters, supplementary information tables of all types; every third with back pressure | CO-IF-01, CO-IF-02, CO-HD-01 to CO-HD-07, CO-PK-01 to CO-PK-03, EC-IF-01, EC-IF-02, EC-SA-01 to EC-SA-03, EC-HY-01 to EC-HY-04, EC-BA-01 to EC-BA-03 |
| `test_golden` tv_<number> (TC-CO-36) | CCSDS test data set (local): 300 test vectors of up to 4096 samples, selected to cover the parameter values of the data set (`tools/ocp_testvectors.py`), every fourth with back pressure | CO-IF-01, CO-IF-02, CO-HD-01 to CO-HD-07, CO-PK-01 to CO-PK-03, EC-IF-01, EC-SA-01 to EC-SA-03, EC-HY-01 to EC-HY-04, EC-BA-01 to EC-BA-03 |
| `test_ecc` c31, c32, c33, c34 (TC-CO-37) | For every memory of the configuration: a single bit error injected into its first write leaves the compressed image unchanged and is signalled on `Ecc_Sec`; a double bit error is signalled on `Ecc_Ded`; after a reset the next image is correct and free of errors | CO-IF-03, CO-IF-04, CO-RS-01, PR-FT-01, PR-FT-02, EC-FT-01, EC-FT-02 |
| `test_reset` c22, c31, c32, c33, c34 (TC-CO-38) | Eight resets at random times of an image (header, body, tail of the hybrid coder, end of the image), each followed by a correct image; 10 % input gaps and 20 % output stalls | CO-RS-01, CO-PK-03 |
| `test_random` ocp_bit_packer_tb w8_b1 to w64_b8 (TC-CO-39) | Bit packer with interface widths of 8, 16, 32 and 64 bits and output word sizes from 1 to 8 bytes: 50 random images of up to 40 codewords of 0 to 96 bits; data, valid bytes and last flag of every word | CO-IF-02, CO-PK-02, CO-TP-01 |
| `test_random` ocp_bit_packer_tb w8_b1_bp to w64_b8_bp (TC-CO-40) | As TC-CO-39 with 20 % source gaps and 50 % sink stalls | CO-IF-02, CO-PK-02 |
| `test_random` ocp_bit_packer_tb w8_b1_small to w64_b8_small (TC-CO-41) | 200 images of up to three codewords with 80 % sink stalls: several image ends queued in the packer | CO-IF-02, CO-PK-02, CO-PK-03 |
| `test_golden` c31_small_bi_periodic_abs to c34_small_bsq_lossless (TC-CO-42) | Small images of 120 to 144 samples: BI order with M = 2 and periodic band-dependent absolute limits (sample-adaptive coder), BIP with periodic band-dependent relative limits (hybrid coder), stride order (block-adaptive coder), BSQ lossless with full prediction | CO-IF-01, CO-HD-05, CO-PK-02, EC-IF-02 |
| `test_golden` c22_single_pixel_hybrid_seq, c31_small_bi_periodic_abs_seq, c34_small_bsq_lossless_seq (TC-CO-43) | Ten images in a row with 70 % output stalls: several images wait for their header while the bit packer takes the body of an earlier image, and an image starts in the cycle in which the header of a waiting image starts | CO-IF-01, CO-PK-03 |
| `test_golden` c35_small_bil_periodic_spec, c36_block_j64_spikes, c37_block_d32_custom (TC-CO-44) | BIL order with periodic updating of band-dependent absolute error limits every row and reduced prediction with narrow neighbour-oriented local sums: the error limit values pass the speculative weight loop; block-adaptive coder with J = 64 on constant bands with spikes: two fundamental sequence codewords that do not fit into one codeword together, a run of all-zeros blocks before the last block of the image; block-adaptive coder with D = 32 on noise: split-sample options with k >= 25, custom weight initialization with Q = Omega + 3 | CO-IF-01, CO-HD-04, CO-HD-05, EC-BA-01, EC-BA-03 |
| `test_byte_order` ocp_bit_packer_tb w8_b1, w16_b1, w32_b1, w64_b1, w32_b3 (TC-CO-45) | One image of 2 `OutWidth_g` / 8 - 1 numbered bytes (1, 2, 3, ...) as 8-bit codewords, at every interface width; with B = 3 the last word holds a fill byte only: byte n of every word in `Out_Data` bits 8n + 7 to 8n (for 32 bits the words x"04030201", x"00070605"), `Out_Keep` contiguous from byte 0 in the last word, all bytes valid in the others | CO-IF-02, CO-PK-02 |
| `test_golden`, `test_ecc`, `test_reset` with the suffix `_last` (TC-CO-46) | Every configuration of TC-CO-01 to TC-CO-44 and TC-CO-48 again with `UseInLast_g` and `In_Last` on the last sample of every image: the same compressed images, `Out_Error` '0' on every word and no `Ev_ImageError`; without `UseInLast_g` the source drives random values on `In_Last` | CO-FR-01, CO-FR-02, CO-FR-05, CO-FR-06 |
| `test_framing` (TC-CO-47) | Eleven images back to back: correct images and images with `In_Last` on the first sample, in the middle of the image, on the last sample but one and on a random sample (aborted: complete header, a prefix of the compressed image cut at a codeword, at least one zero fill bit up to a multiple of B, `Out_Error` on the last word), and with `In_Last` missing (complete compressed image with `Out_Error`, then a random number of samples or one sample up to the next `In_Last`, each taken in the cycle it is offered); every correct image before and after an error equals the compressed image of the CNES reference software; one `Ev_ImageError` per image with an error. The error limit source drops the values of an aborted image. Then eight resets at random times of an image with an error (during the abort, the discarded samples or the next image) and one reset with the error event of an image that follows a correct image back to back (the abort still waits for the image before), each followed by a correct image. Twelve small configurations: BSQ, BIL, BIP and BI order with sub-frames, the stride order, the speculative weight loop, periodic error limits, the three coders, B from 1 to 8, interface widths of 8 to 64 bits, four of them with input gaps and output stalls | CO-FR-02, CO-FR-03, CO-FR-04, CO-FR-05, CO-FR-06, CO-FR-07, CO-RS-01, CO-PK-02, CO-PK-03 |
| `test_golden` c38_header_bounds (TC-CO-48) | Bounds of the header fields: user-defined data 255, 15 supplementary information tables, error limit update period 2^9, DA = DR = 16 (encoded as 0) with D = 20, K = min(D - 2, 14) = 14, gamma* = gamma0 + 1 = 8, Umax = 32 | CO-HD-02, CO-HD-03, CO-HD-05, CO-HD-07 |
| TC-CO-49 (`lint/synth_check.py`) | GHDL synthesis of `ocp_core` with every configuration of the regression at the interface width of its test, without and with `UseInLast_g`; the bounds that no configuration of the regression reaches: NX, NY, NZ and M of 65536 (the other dimensions 1 or 2), `Speculation_g` false, `RamStyle_g` "block"; eleven configurations outside the ranges of the standard (M above NZ, J = 12, restricted code options with D = 5, gamma* below gamma0 + 1, K above D - 2 as a constant and as band-varying values with fewer values than bands, `OutWidth_g` = 12, width 1 with full prediction, R below D + Omega + 2, vmin above vmax, periodic updating in BSQ order) stop the elaboration with their message | CO-CF-01, CO-CF-02, CO-CF-03, CO-IF-02 |

## 4. Requirement coverage

| Requirement | Test cases |
| --- | --- |
| CO-IF-01, CO-IF-02 | TC-CO-01, TC-CO-10, TC-CO-19 to TC-CO-36, TC-CO-39 to TC-CO-41, TC-CO-45 (byte order); interface widths of 8, 16, 32 and 64 bits |
| CO-IF-03, CO-IF-04 | TC-CO-37 (no error in all other test cases) |
| CO-HD-01 to CO-HD-07 | TC-CO-01 to TC-CO-24, TC-CO-35, TC-CO-36, TC-CO-48 (bounds of the header fields) |
| CO-PK-01 to CO-PK-03 | all (two images per test), TC-CO-39 to TC-CO-41, TC-CO-43 (ten images per test) |
| CO-TP-01 | TC-CO-25 to TC-CO-28, TC-CO-39 |
| CO-RS-01 | TC-CO-37, TC-CO-38, TC-CO-47 |
| CO-FR-01 | TC-CO-01 to TC-CO-44, TC-CO-48 (random `In_Last` without `UseInLast_g`) |
| CO-CF-01 to CO-CF-03 | TC-CO-49 |
| CO-FR-02 to CO-FR-07 | TC-CO-46, TC-CO-47 |
