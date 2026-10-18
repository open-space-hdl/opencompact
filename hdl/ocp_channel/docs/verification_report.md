# ocp_channel: Verification Report

## 1. Test results

Run on 2026-10-17 with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit 4f1e13b) with the AXI-Lite VVC, Open Logic
4.7.0-ft.6: `python run.py "*ocp_channel*"`. The same tests pass in QuestaSim (Questa Pro Microchip Edition 2024.3,
2026-10-18), with code coverage and in the optimised run without it; the code coverage is in
[coverage.md](../../../docs/coverage.md).

| Test | Configurations | Passed |
| --- | --- | --- |
| `test_golden` (TC-CH-01) | 8 | 8 |
| `test_errors` (TC-CH-02) | 7 | 7 |
| `test_ecc` (TC-CH-03) | 1 (two memories) | 1 |
| `test_reset` (TC-CH-04) | 1 | 1 |
| `lint/synth_check.py` (TC-CH-05) | 8 configurations synthesize, `OutStreamWidth_g` = 24 stops the elaboration | 9 |

## 2. Summary

Every compressed image leaves the channel as one packet whose bytes equal the image compressed by the CNES reference
software, for D from 8 to 32 and the three coders, through the input converter at integer and non-integer ratios and
without it, through the output converter (also to a narrower stream) and without it, with input gaps and output stalls,
and with the error limit values of periodic updating through `Lim_*`. All bytes of a packet are valid except in its last
beat, whose valid bytes are contiguous from byte 0. In the error scenarios every packet, its error flag and every
counter step of the specification hold: an aborted image equals the compressed image of the samples taken
(`aborted_<n>.bin`, the SDU with the fault or the end mark ends at that sample); an image ended by a faulty last SDU or
without its end mark equals the reference and carries `Out_Error`; the images discarded by the adapter or swallowed by
the core produce no packet; every correct image after an error equals the reference. Single and double bit errors
injected through `ErrInj_*` are counted in ECC_CORRECTED and ECC_UNCORRECTABLE. A reset clears the counters.

## 3. Generic ranges

| Generic | Declared range | Simulated | Synthesized |
| --- | --- | --- | --- |
| `InStreamWidth_g` | 8, 16, 32, 64, 128 | all (8, 16 and 32 without converter) | all of the simulated configurations |
| `OutStreamWidth_g` | 8, 16, 32, 64, 128 | all (32 and 64 without converter, 8 below `OutWidth_g`) | the same; 24 stops the elaboration |
| `OutWidth_g` | 8, 16, 32, 64 | all | all |
| `UserWidth_g` and masks | | 22 (OpenSPP layout) | 22 |

The generics of `ocp_core` keep the ranges and the verification of `ocp_core`; the input adapter verifies the other
user signal widths.

## 4. Findings

| Finding | Correction |
| --- | --- |
| The error flag register of the output converter drove `Out_Error` during the next packet until its last beat (found by `test_errors` in the configurations with an output converter) | `Out_Error` is the flag register gated by the last beat of the converter |
