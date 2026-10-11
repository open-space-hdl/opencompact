# ocp_core: Verification Report

## 1. Test results

Run on 2026-10-11 with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit 4f1e13b): `python run.py "*ocp_core*"`.
The same tests pass in QuestaSim (Questa Pro Microchip Edition 2024.3); the code coverage is in
[coverage.md](../../../docs/coverage.md).

| Testbench | Tests | Passed |
| --- | --- | --- |
| `ocp_core_tb` | 34 (30 configurations, 4 of them also with back pressure) | 34 |

## 2. Summary

Every compressed image equals the compressed image of the CNES reference software byte by byte, for two consecutive
images per test, with and without back pressure, at interface widths of 8, 16, 32 and 64 bits. The configurations
TC-CO-25 to TC-CO-28 take one sample per clock cycle over both images, including the header of the second image.
Every requirement of the specification is covered; the error injection into the memories is not yet tested. All 30
configurations synthesize with GHDL without errors and without latches (`python lint/synth_check.py`).

Findings:

| Finding | Resolution |
| --- | --- |
| After the end of an image the bit packer took codewords of the next image before its header (hybrid coder, second image) | The image ends when the last codeword is taken; the header of the next image follows the fill bits |
| The header of a further image was output without an image | The header starts with the first sample or error limit value of the image |
| The header of the next image waited for an input sample while the predictor had already taken all samples of a small image (TC-CO-22) | The predictor marks the first item of every image; the core counts the started images |
| At one sample per cycle the codewords that queued during the header of the second image never drained (TC-CO-25) | Codeword buffer that joins short codewords before the coder output FIFO |
| Bit packer: the last word of an image was followed by stale bits when the image ended inside a word | The fill bits are written up to the next interface word |
| Synthesis: Synplify rejected a `while` loop in the bit packer; GHDL synthesis stopped with an internal error on a slice with variable bounds | `mod` operator and a word multiplexer |
| Timing (place and route at 100 MHz): the SECDED correction of the predictor output FIFO and the first stage of the entropy coder formed one path | Register stage at the output of the predictor |
