# ocp_entropy_coder: Verification Plan

## 1. Overview

The entropy coders are verified in `ocp_core` (G integration level): the core compresses the test image of every
configuration and its output is compared byte by byte with the compressed image of the CNES reference software. A
codeword error of a coder changes the compressed image, so every configuration checks the coder it selects completely,
including the tail and the fill bits. Unit testbenches of the coders against codeword sequences of the reference model
are an open item of the roadmap.

## 2. Test cases

The test cases are those of the [verification plan of ocp_core](../../ocp_core/docs/verification_plan.md).

| Test cases | Coder and options | Requirements |
| --- | --- | --- |
| TC-CO-01, TC-CO-02, TC-CO-03, TC-CO-09, TC-CO-11, TC-CO-12, TC-CO-14, TC-CO-15, TC-CO-21, TC-CO-23, TC-CO-25 | Sample-adaptive coder: error limit values in the body (TC-CO-21), K constant and band-dependent k''_z, Umax from 8 to 32, gamma* from 4 to 11, gamma0 from 1 to 8, D from 8 to 32, escape codewords on noise (TC-CO-15) | EC-IF-01, EC-SA-01, EC-SA-02, EC-SA-03, EC-FT-01 |
| TC-CO-04, TC-CO-05, TC-CO-10, TC-CO-13, TC-CO-16, TC-CO-20, TC-CO-22, TC-CO-26, TC-CO-28 | Hybrid coder: images of a single pixel (TC-CO-22), band-dependent initial accumulators up to 2^33 - 1 (TC-CO-20), rescaling, high- and low-entropy indexes, all 16 low-entropy codes with escape symbols (TC-CO-16), tail; periodic error limits in the body (TC-CO-10) | EC-IF-01, EC-IF-02, EC-HY-01, EC-HY-02, EC-HY-03, EC-HY-04, EC-FT-01 |
| TC-CO-06, TC-CO-07, TC-CO-08, TC-CO-17, TC-CO-18, TC-CO-19, TC-CO-24, TC-CO-27 | Block-adaptive coder: J = 8, 16, 32, 64, reference intervals 4, 8, 70 and 4096, zero-block runs up to a full segment and remainder of segment (TC-CO-17), restricted set of code options with D = 4 and D = 2 (TC-CO-08, TC-CO-19), second extension, split samples up to k = 22 and no compression with 5-bit identifiers (TC-CO-18), error limits in the input (TC-CO-19) | EC-IF-01, EC-BA-01, EC-BA-02, EC-BA-03 |

## 3. Requirement coverage

| Requirement | Test cases |
| --- | --- |
| EC-IF-01 | all core test cases |
| EC-IF-02 | TC-CO-10, TC-CO-19, TC-CO-21, TC-CO-28 |
| EC-SA-01 to EC-SA-03 | TC-CO-01 to TC-CO-03, TC-CO-09, TC-CO-11, TC-CO-12, TC-CO-14, TC-CO-15, TC-CO-21, TC-CO-23, TC-CO-25 |
| EC-HY-01 to EC-HY-04 | TC-CO-04, TC-CO-05, TC-CO-10, TC-CO-13, TC-CO-16, TC-CO-20, TC-CO-22, TC-CO-26, TC-CO-28 |
| EC-BA-01 to EC-BA-03 | TC-CO-06 to TC-CO-08, TC-CO-17 to TC-CO-19, TC-CO-24, TC-CO-27 |
| EC-FT-01 | sample-adaptive and hybrid test cases (no error; error injection is an open item) |
