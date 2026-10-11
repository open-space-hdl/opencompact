# ocp_core: Verification Report

## 1. Test results

Run on 2026-10-10 with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit 4f1e13b): `python run.py "*ocp_core*"`.
The same tests pass in QuestaSim (Questa Pro Microchip Edition 2024.3); the code coverage is in
[coverage.md](../../../docs/coverage.md).

| Testbench | Tests | Passed |
| --- | --- | --- |
| `ocp_core_tb` | 28 (24 configurations, 4 of them also with back pressure) | 28 |

## 2. Summary

Every compressed image equals the compressed image of the CNES reference software byte by byte, for two consecutive
images per test, with and without back pressure. Every requirement of the specification is covered; the error
injection into the memories is not yet tested. All 24 configurations synthesize with GHDL without errors and without
latches (`python lint/synth_check.py`).

Findings:

| Finding | Resolution |
| --- | --- |
| After the end of an image the bit packer took codewords of the next image before its header (hybrid coder, second image) | The image ends when the last codeword is taken; the header of the next image follows the fill bits |
| The header of a further image was output without an image | The header starts with the first sample or error limit value of the image |
