# ocp_entropy_coder: Verification Plan

## 1. Overview

The unit testbench `ocp_entropy_coder_tb` drives the entropy coder input sequence of the reference model
(`tb/golden/<configuration>/delta.txt`: mapped quantizer indices with band, t = 0 and t = 1 flags, and the error limit
values of periodic updating) into the coder of a configuration, joins the codewords into a bit stream and compares it
byte by byte with the body of the image compressed by the CNES reference software, including the tail and the fill
bits. It runs every configuration of `tools/ocp_configs.py` (the 38 configurations and the 24 random configurations),
two images in a row, every second configuration with 20 % source gaps and 50 % sink stalls.

The coders are also verified in `ocp_core` (G integration level): the core compresses the test image of every
configuration and its output is compared byte by byte with the compressed image of the CNES reference software; the
error injection into the statistics memories and the codeword buffers runs there (`test_ecc`).

## 2. Test cases

| Test ID | Description | Requirements |
| --- | --- | --- |
| `test_golden` sample-adaptive configurations of ocp_entropy_coder_tb (TC-EC-01) | Sample-adaptive coder on the input sequences of all configurations with this coder | EC-IF-01, EC-IF-02, EC-SA-01, EC-SA-02, EC-SA-03 |
| `test_golden` hybrid configurations of ocp_entropy_coder_tb (TC-EC-02) | Hybrid coder on the input sequences of all configurations with this coder, including the tail | EC-IF-01, EC-IF-02, EC-HY-01, EC-HY-02, EC-HY-03, EC-HY-04 |
| `test_golden` block-adaptive configurations of ocp_entropy_coder_tb (TC-EC-03) | Block-adaptive coder on the input sequences of all configurations with this coder | EC-IF-01, EC-BA-01, EC-BA-02, EC-BA-03 |
| `test_golden` configurations of ocp_entropy_coder_tb with back pressure (TC-EC-04) | Every second configuration with source gaps and sink stalls | EC-IF-01, EC-TP-01 |
| `test_golden` c20_hybrid_d28_stall, c30_tp_bip_both_stride_stall (TC-EC-05) | Hybrid coder with 90 % sink stalls: the codeword FIFO fills during the samples (high-entropy codes with D = 28) and during the tail (48 bands) | EC-IF-01, EC-HY-04, EC-TP-01 |

The test cases of the [verification plan of ocp_core](../../ocp_core/docs/verification_plan.md) cover the coders as
well:

| Test cases | Coder and options | Requirements |
| --- | --- | --- |
| TC-CO-01, TC-CO-02, TC-CO-03, TC-CO-09, TC-CO-11, TC-CO-12, TC-CO-14, TC-CO-15, TC-CO-21, TC-CO-23, TC-CO-25, TC-CO-28, TC-CO-29, TC-CO-31, TC-CO-48 | Sample-adaptive coder: error limit values in the body (TC-CO-21), K constant and band-dependent k''_z, K = min(D - 2, 14) and the smallest rescaling counter size (TC-CO-48), Umax from 8 to 32, gamma\* from 4 to 11, gamma0 from 1 to 8, D from 8 to 32, escape codewords on noise (TC-CO-15) | EC-IF-01, EC-SA-01, EC-SA-02, EC-SA-03, EC-TP-01, EC-FT-01 |
| TC-CO-04, TC-CO-05, TC-CO-10, TC-CO-13, TC-CO-16, TC-CO-20, TC-CO-22, TC-CO-26, TC-CO-30, TC-CO-32, TC-CO-34 | Hybrid coder: images of a single pixel (TC-CO-22), band-dependent initial accumulators up to 2^33 - 1 (TC-CO-20), rescaling, high- and low-entropy indexes, all 16 low-entropy codes with escape symbols (TC-CO-16), tail; periodic error limits in the body (TC-CO-10) | EC-IF-01, EC-IF-02, EC-HY-01, EC-HY-02, EC-HY-03, EC-HY-04, EC-TP-01, EC-FT-01 |
| TC-CO-06, TC-CO-07, TC-CO-08, TC-CO-17, TC-CO-18, TC-CO-19, TC-CO-24, TC-CO-27, TC-CO-33 | Block-adaptive coder: J = 8, 16, 32, 64, reference intervals 4, 8, 70 and 4096, zero-block runs up to a full segment and remainder of segment (TC-CO-17), restricted set of code options with D = 4 and D = 2 (TC-CO-08, TC-CO-19), second extension, split samples up to k = 22 and no compression with 5-bit identifiers (TC-CO-18), error limits in the input (TC-CO-19) | EC-IF-01, EC-BA-01, EC-BA-02, EC-BA-03, EC-TP-01 |

## 3. Requirement coverage

| Requirement | Test cases |
| --- | --- |
| EC-IF-01 | TC-EC-01 to TC-EC-05, all core test cases |
| EC-IF-02 | TC-CO-10, TC-CO-19, TC-CO-21, TC-CO-34 |
| EC-SA-01 to EC-SA-03 | TC-CO-01 to TC-CO-03, TC-CO-09, TC-CO-11, TC-CO-12, TC-CO-14, TC-CO-15, TC-CO-21, TC-CO-23, TC-CO-25, TC-CO-28, TC-CO-29, TC-CO-31, TC-CO-48 |
| EC-HY-01 to EC-HY-04 | TC-CO-04, TC-CO-05, TC-CO-10, TC-CO-13, TC-CO-16, TC-CO-20, TC-CO-22, TC-CO-26, TC-CO-30, TC-CO-32, TC-CO-34; TC-CO-47 (tail of images that end before every band has its first coded sample, after an image that left other accumulators in the memory: BSQ r21_random, BIL c26_tp_bil_near_abs, BIP c32_small_bip_periodic_rel, stride c30_tp_bip_both_stride) |
| EC-BA-01 to EC-BA-03 | TC-CO-06 to TC-CO-08, TC-CO-17 to TC-CO-19, TC-CO-24, TC-CO-27, TC-CO-33 |
| EC-TP-01 | TC-CO-25 to TC-CO-28 (one item per cycle over two images), TC-EC-04, TC-EC-05 |
| EC-FT-01, EC-FT-02 | TC-CO-37 (error injection into the statistics memory and the codeword buffer) |
| EC-RC-01 | TC-CO-52 (runtime NZ with the sample-adaptive and the hybrid coder, NX = NY = 1 among the drawn dimensions) |
| EC-RP-01 | TC-CO-59 (rp01 sample-adaptive, rp02 hybrid: Umax, gamma0, gamma\*, K per image, every bound among the drawn values), TC-CO-60 (limited values), TC-CO-61 (parameters of queued images) |
| EC-RP-02 | TC-CO-59, TC-CO-60 (rp03 block-adaptive: r per image) |
