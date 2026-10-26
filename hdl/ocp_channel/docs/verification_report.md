# ocp_channel: Verification Report

## 1. Test results

Run on 2026-10-25 with GHDL 6.0.0 (mcode, in the CI of the repository), VUnit 5.0.0.dev7, UVVM (commit 4f1e13b) with
the AXI-Lite VVC, Open Logic 4.7.0-ft.9: `python run.py "*ocp_channel*"`. The same tests pass in QuestaSim (Questa Pro
Microchip Edition 2024.3, time resolution 1 fs, 2026-10-24), with code coverage and in the optimised run without it;
the code coverage is in [coverage.md](../../../docs/coverage.md).

| Test | Configurations | Passed |
| --- | --- | --- |
| `test_golden` (TC-CH-01) | 8 | 8 |
| `test_errors` (TC-CH-02) | 7 | 7 |
| `test_ecc` (TC-CH-03) | 1 (two memories) | 1 |
| `test_reset` (TC-CH-04) | 1 | 1 |
| `test_runtime` (TC-CH-07, TC-CH-08) | 2 (rc04; rp01 with the runtime parameters) | 2 |
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

With the runtime configuration (rc04, TC-CH-07) the configurations reach the core through the AXI4-Lite registers of
`ocp_mib`: a configuration committed while the image before it is compressed applies to the next image, an invalid
configuration is rejected with CFG_ERROR and the committed one stays, every packet equals the reference model for the
configuration of its image, and after every image the active registers show that configuration and CFG_PENDING shows
whether a committed configuration still waits. With the runtime parameters (rp01, TC-CH-08) the same sequence commits
the parameters of every image through NEXT_SAMPLES to NEXT_BLOCK with its dimensions: every packet equals the reference
model for the dimensions, limits and parameters of its image, and after every image the parameter fields of SAMPLES
to ADAPTIVE show those of the image.

## 3. Generic ranges

| Generic | Declared range | Simulated | Synthesized |
| --- | --- | --- | --- |
| `InStreamWidth_g` | 8, 16, 32, 64, 128 | all (8, 16 and 32 without converter) | all of the simulated configurations |
| `OutStreamWidth_g` | 8, 16, 32, 64, 128 | all (32 and 64 without converter, 8 below `OutWidth_g`) | the same; 24 stops the elaboration |
| `OutWidth_g` | 8, 16, 32, 64 | all | all |
| `UserWidth_g` and masks | | 22 (OpenSPP layout) | 22 |
| `RuntimeConfig_g` | Boolean | both (true in rc04) | false; `ocp_core` synthesizes with both values |

The generics of `ocp_core` keep the ranges and the verification of `ocp_core`; the input adapter verifies the other
user signal widths.

## 4. Findings

| Finding | Correction |
| --- | --- |
| The error flag register of the output converter drove `Out_Error` during the next packet until its last beat (found by `test_errors` in the configurations with an output converter) | `Out_Error` is the flag register gated by the last beat of the converter |
