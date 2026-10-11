# ocp_predictor: Verification Report

## 1. Test results

Run on 2026-10-11 with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit 4f1e13b): `python run.py "*predictor*"`.
The same tests pass in QuestaSim (Questa Pro Microchip Edition 2024.3); the code coverage is in
[coverage.md](../../../docs/coverage.md).

| Testbench | Tests | Passed |
| --- | --- | --- |
| `ocp_predictor_tb` | 33 (30 configurations, 3 of them also with back pressure) | 33 |

## 2. Summary

All test cases pass: the entropy coder input sequence of every configuration equals the sequence of the reference model,
item by item, and the predictor takes and outputs the samples of every configuration without back pressure in exactly
the clock cycles that the throughput model `tools/ocp_throughput.py` computes. Every requirement of the specification is
covered by a test case; the error injection into the memories (PR-FT-01) is not yet tested.

Findings:

| Finding | Resolution |
| --- | --- |
| Weight increments larger than the increment register were truncated instead of saturated for non-negative exponents (uncorrelated noise, TC-PR-15) | Saturation of the increment for both exponent signs before the clipping of the weight |
| D = 32: the remainder of the division was sliced beyond its width (TC-PR-11) | Remainder resized to the width of the quantizer operands |
| GHDL synthesis stopped with an internal error on a slice with variable bounds (weight exponent offsets) | Offsets stored as an array indexed by the component |
| Pipeline: the weights were read one stage before the band of the sample was known, so the first sample of a new band used the weights of the previous band (TC-PR-01) | Weight memory addressed by the band of stage 2 |
| Threshold error sign: the thresholds overflowed the integer range for D = 32 (TC-PR-11) | Thresholds as signed vectors of the width of the local sum |
| Stride order: the context of a band was overwritten by the next column of the same band when the stride S exceeds the number of bands M (TC-PR-04, TC-PR-06) | One context entry per band and column slot of the stride period |
