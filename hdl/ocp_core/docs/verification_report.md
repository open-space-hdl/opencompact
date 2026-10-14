# ocp_core: Verification Report

## 1. Test results

Run on 2026-10-14 with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit 4f1e13b):
`python run.py "*ocp_core*" "*ocp_bit_packer*"`.
The same tests pass in QuestaSim (Questa Pro Microchip Edition 2024.3); the code coverage is in
[coverage.md](../../../docs/coverage.md). The tests of the CCSDS test data set ran in GHDL on 2026-10-14
(`OCP_TESTVECTORS`, selection of `tools/ocp_testvectors.py`).

| Testbench | Tests | Passed |
| --- | --- | --- |
| `ocp_core_tb` `test_golden` | 68 (61 configurations, every third random configuration with back pressure; 4 configurations also with back pressure; 3 sequences of 10 to 100 small images), each also with `UseInLast_g` (`_last`) | 136 |
| `ocp_core_tb` `test_ecc` | 4 (every memory of the core), each also with `UseInLast_g` | 8 |
| `ocp_core_tb` `test_reset` | 5, each also with `UseInLast_g` | 10 |
| `ocp_core_tb` `test_framing` | 12 (eleven images with four early and two missing image end markers, eight resets during the error handling) | 12 |
| `ocp_bit_packer_tb` `test_random` | 30 | 30 |
| `ocp_bit_packer_tb` `test_byte_order` | 5 | 5 |
| `ocp_core_tb` `test_golden` with the CCSDS test data set | 300 (75 of them with back pressure), each also with `UseInLast_g` | 600 |

## 2. Summary

Every compressed image equals the compressed image of the CNES reference software byte by byte, for two consecutive
images per test (10 to 100 in the sequences), with and without back pressure, at interface widths of 8, 16, 32 and
64 bits; the compressed images of the 300 vectors of the CCSDS test data set are reproduced as well. Every word
carries byte n in bits 8n + 7 to 8n, with the valid bytes of the last word contiguous from byte 0 and all bytes valid
in the other words; the numbered bytes of TC-CO-45 show the order directly (32 bits: x"04030201", x"00070605" with
`Out_Keep` "0111"). The
configurations TC-CO-25 to TC-CO-28 take one sample per clock cycle over both images, including the header of the
second image. A single bit error injected into any memory leaves the compressed image unchanged and is signalled on
`Ecc_Sec`, a double bit error is signalled on `Ecc_Ded` (TC-CO-37); after every reset at a random time the next image
is correct (TC-CO-38).

With the image framing (`UseInLast_g`) every configuration produces the same compressed images, without `Out_Error`
and without `Ev_ImageError` (TC-CO-46); without it `In_Last` carries random values and changes nothing. In
`test_framing` (TC-CO-47) every image with an early `In_Last` ends with its complete header, a prefix of the compressed
image of the reference cut at a codeword, at least one zero fill bit and a size that is a multiple of B, and carries
`Out_Error` on its last word; every image with a missing `In_Last` equals the reference and carries `Out_Error`; the
samples after it up to the next `In_Last` are taken in the cycle they are offered; every correct image before and
after an error, also back to back and after a reset during the error handling, equals the reference, and
`Ev_ImageError` pulses once per image with an error. In the periodic configurations the error limit source drops the
remaining values of an aborted image, and the next image takes its own values. Every requirement of the
specification is covered. All 61 configurations synthesize with GHDL without errors and without latches, with and
without the image framing (`python lint/synth_check.py [--in-last]`).

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
| Image framer: a range-limited counter failed a GHDL bound check on a transient value between two clock edges (TC-CO-47) | Counters of the framer as `unsigned` |
| Image framer, first design with an empty last codeword for an aborted image: when the words of the aborted image had already left the bit packer (header only, ending at a word boundary), the end produced a word without valid bytes that took the first bytes of the next image; in another timing the read position passed the write position and a stale word left (TC-CO-47) | The aborted image ends with a codeword of one zero bit, so the bit packer ends it like any image; the last codeword of an image is never empty |
| Synthesis (Libero, c01 with `UseInLast_g`): the 16 error flags of the framer were mapped to a uSRAM without ECC | Synthesis attributes keep them in registers (93 LUTs, 49 flip-flops for the framer) |
| Coverage: the count of error flags was updated in an `if` / `elsif` on the write and the read of a flag; the condition rows for a write and a read in the same clock cycle were not reached by any test | The count is the difference of the write and the read pointer (one bit wider than the index), with no condition left |
| Coverage: no reset arrived while the framer waited for the image before an aborted one (transition Drain to Run) | TC-CO-47 resets the core with the error event of an image that follows a correct image back to back |
