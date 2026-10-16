# ocp_predictor: Verification Report

## 1. Test results

Run on 2026-10-15 with GHDL (mcode, in the CI of the repository), VUnit 5.0.0.dev7, UVVM (commit 4f1e13b),
Open Logic 4.7.0-ft.6: `python run.py "*predictor*"`.
The same tests pass in QuestaSim (Questa Pro Microchip Edition 2024.3, 2026-10-16), with code coverage and in
the optimised run without it; the code coverage is in [coverage.md](../../../docs/coverage.md). The tests of the
CCSDS test data set ran in GHDL 6.0.0 on 2026-10-15 and 2026-10-16 (`OCP_TESTVECTORS`, selection of
`tools/ocp_testvectors.py`).

| Testbench | Tests | Passed |
| --- | --- | --- |
| `ocp_predictor_tb` | 75 (62 configurations, 5 of them also with back pressure, 3 also with strong output stalls, 5 also without the speculative weight loop) | 75 |
| `ocp_predictor_tb` with the CCSDS test data set | 375 (300 test vectors, 75 of them also with back pressure) | 375 |

## 2. Summary

All test cases pass: the entropy coder input sequence of every configuration equals the sequence of the reference model,
item by item, and the predictor takes and outputs the samples of every configuration without back pressure in exactly
the clock cycles that the throughput model `tools/ocp_throughput.py` computes. Every requirement of the specification is
covered by a test case; the error injection into the memories of the predictor (PR-FT-01, PR-FT-02) runs in the core
testbench (TC-CO-37).

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
