# ocp_core: Verification Report

## 1. Test results

Run on 2026-10-12 with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit 4f1e13b):
`python run.py "*ocp_core*" "*ocp_bit_packer*"`.
The same tests pass in QuestaSim (Questa Pro Microchip Edition 2024.3); the code coverage is in
[coverage.md](../../../docs/coverage.md). The tests of the CCSDS test data set ran in GHDL on 2026-10-12
(`OCP_TESTVECTORS`, selection of `tools/ocp_testvectors.py`).

| Testbench | Tests | Passed |
| --- | --- | --- |
| `ocp_core_tb` `test_golden` | 68 (61 configurations, every third random configuration with back pressure; 4 configurations also with back pressure; 3 sequences of 10 to 100 small images) | 68 |
| `ocp_core_tb` `test_ecc` | 4 (every memory of the core) | 4 |
| `ocp_core_tb` `test_reset` | 5 | 5 |
| `ocp_bit_packer_tb` `test_random` | 30 | 30 |
| `ocp_core_tb` `test_golden` with the CCSDS test data set | 300 (75 of them with back pressure) | 300 |

## 2. Summary

Every compressed image equals the compressed image of the CNES reference software byte by byte, for two consecutive
images per test (10 to 100 in the sequences), with and without back pressure, at interface widths of 8, 16, 32 and
64 bits; the compressed images of the 300 vectors of the CCSDS test data set are reproduced as well. The
configurations TC-CO-25 to TC-CO-28 take one sample per clock cycle over both images, including the header of the
second image. A single bit error injected into any memory leaves the compressed image unchanged and is signalled on
`Ecc_Sec`, a double bit error is signalled on `Ecc_Ded` (TC-CO-37); after every reset at a random time the next image
is correct (TC-CO-38). Every requirement of the specification is covered. All 61 configurations synthesize with GHDL
without errors and without latches (`python lint/synth_check.py`).

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
| Bit packer: when the output took the end of one image in the same cycle in which the fill bits of the next image were allocated, the end of the next image was lost (small images with output stalls, TC-CO-41) | The end of an image enters the queue of image ends after the output stage |
| Error flags of the codeword FIFO were raised in every cycle in which a word with an error waited at the output (TC-CO-37) | One flag per word, with the handshake at the output of the FIFO |
