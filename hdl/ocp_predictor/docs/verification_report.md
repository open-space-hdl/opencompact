# ocp_predictor: Verification Report

## 1. Test results

Run on 2026-10-23 with GHDL (mcode, in the CI of the repository), VUnit 5.0.0.dev7, UVVM (commit 4f1e13b), Open Logic
4.7.0-ft.9: `python run.py "*predictor*" "*image_start*"`. The tests of version 0.1.1 pass in QuestaSim (Questa Pro
Microchip Edition 2024.3, time resolution 1 fs, 2026-10-19), with code coverage and in the optimised run without it;
the code coverage of that version is in [coverage.md](../../../docs/coverage.md). The tests of the runtime
configuration run in QuestaSim with the next release. The tests of the CCSDS test data set ran in GHDL 6.0.0 on
2026-10-18 (`OCP_TESTVECTORS`, selection of `tools/ocp_testvectors.py`), before the runtime configuration.

| Testbench | Tests | Passed |
| --- | --- | --- |
| `ocp_predictor_tb` | 75 (62 configurations, 5 of them also with back pressure, 3 also with strong output stalls, 5 also without the speculative weight loop) | 75 |
| `ocp_predictor_tb` `test_runtime` (TC-PR-41) | 10 (rc01 to rc05, sequences of 20 images, each also with back pressure) | 10 |
| `ocp_image_start_tb` `test_sweep` (TC-PR-40) | 10 (the latencies and flags of rc01 to rc05 and of c03, c04, c05, c28 and c30, which cover the other combinations of order, sample representatives and local sums) | 10 |
| `ocp_predictor_tb` with the CCSDS test data set | 375 (300 test vectors, 75 of them also with back pressure) | 375 |

## 2. Summary

All test cases pass: the entropy coder input sequence of every configuration equals the sequence of the reference model,
item by item, and the predictor takes and outputs the samples of every configuration without back pressure in exactly
the clock cycles that the throughput model `tools/ocp_throughput.py` computes. Every requirement of the specification is
covered by a test case; the error injection into the memories of the predictor (PR-FT-01, PR-FT-02) runs in the core
testbench (TC-CO-37).

With the runtime configuration the entropy coder input sequence of every image of the sequences of rc01 to rc05 equals
that of the reference model, and without back pressure the input cycles and the image-start cycles equal the throughput
model with the dimensions of every image (TC-PR-41); rc02 runs without the stride order. For BI and BSQ order and every
combination of NX from 1 to 64, M from 1 to the maximum NZ and NY of 1, 2, 3 and 64, and at nine further points up to
65536 in every dimension (the maxima and the saturation of the factors), the image-start sequencer computes the same
issue conditions as the elaboration function for constant generics and needs the same number of cycles for every input
(TC-PR-40). Two mutations of the runtime path (NX not taken, issue distance 0) each make their test fail
([ocp_core verification report](../../ocp_core/docs/verification_report.md), section 6).

Findings:

| Finding | Resolution |
| --- | --- |
| Weight increments larger than the increment register were truncated instead of saturated for non-negative exponents (uncorrelated noise, TC-PR-15) | Saturation of the increment for both exponent signs before the clipping of the weight |
| D = 32: the remainder of the division was sliced beyond its width (TC-PR-11) | Remainder resized to the width of the quantizer operands |
| GHDL synthesis stopped with an internal error on a slice with variable bounds (weight exponent offsets) | Offsets stored as an array indexed by the component |
| Pipeline: the weights were read one stage before the band of the sample was known, so the first sample of a new band used the weights of the previous band (TC-PR-01) | Weight memory addressed by the band of stage 2 |
| Threshold error sign: the thresholds overflowed the integer range for D = 32 (TC-PR-11) | Thresholds as signed vectors of the width of the local sum |
| Stride order: the context of a band was overwritten by the next column of the same band when the stride S exceeds the number of bands M (TC-PR-04, TC-PR-06) | One context entry per band and column slot of the stride period |
| Images of a few samples (CCSDS test data set, for example 2 x 1 x 15): the address of the memory of local differences of the stride order took more bits from the pixel index than the index has (simulation overflow; the memory exists in the stride order only) | Number of entries per band 1 outside the stride order; pixel index resized instead of sliced |
| Lossless compression with damping (Theta > 0, phi_z > 0; random configurations and the CCSDS test data set): the predictor took the samples as sample representatives, but with damping the representative depends on the high-resolution predicted sample also when m_z = 0 (CCSDS 4.9.2) | The shortcut applies to lossless compression without damping only; with damping the path of near-lossless compression runs with m_z = 0 |
| Speculative weight loop with gaps in the input (BIL with three columns, CCSDS test data set, and back pressure from the block-adaptive coder): a cycle without a sample keeps the fields of the previous item, so after the first sample of a run (x = 0) or after t = 1 it reloaded the weights of the band instead of passing the candidates on | A cycle without a sample always passes the candidates on; the speculative configurations also run with back pressure |
| Memory error flags were raised for reads in cycles without an item: a stale word with an error (left by the error injection, or an upset) was reported again in the next image (TC-CO-37) | A flag counts only in a cycle in which an item takes the read data |
| GHDL command of a simulation: VUnit 5.0.0.dev7 appends the generics of a test to the list of the option `ghdl.sim_flags` in place, and configurations added after the option is set share that list, so a simulation would also run with the generics of a configuration started before it. `run.py` sets the option after adding the configurations, so every configuration had its own list; QuestaSim is not affected | `run.py` copies the list per simulation and stops when a GHDL command does not carry exactly the generics of its configuration; all configurations pass with this check |
| `test_runtime` rc05: the expected input cycles included the tail of the hybrid coder, which the throughput model counts since CO-TP-01 but which the predictor testbench, without an entropy coder, does not have (1604 instead of 1371 cycles) | The predictor testbench uses the throughput model without the coder tail; the expected cycles of rc01 to rc05 equal those of the model before CO-TP-01 |
