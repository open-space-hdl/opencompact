# ocp_core: Verification Report

## 1. Test results

Run on 2026-10-14 with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit 4f1e13b):
`python run.py "*ocp_core*" "*ocp_bit_packer*"`.
The same tests up to TC-CO-47 pass in QuestaSim (Questa Pro Microchip Edition 2024.3), with code coverage and in
the optimised run without it; the code coverage is in [coverage.md](../../../docs/coverage.md). The QuestaSim runs of
c38_header_bounds (TC-CO-48) follow. The tests of the CCSDS test data set
ran in GHDL on 2026-10-14 (`OCP_TESTVECTORS`, selection of `tools/ocp_testvectors.py`).

| Testbench | Tests | Passed |
| --- | --- | --- |
| `ocp_core_tb` `test_golden` | 69 (62 configurations, every third random configuration with back pressure; 4 configurations also with back pressure; 3 sequences of 10 to 100 small images), each also with `UseInLast_g` (`_last`) | 138 |
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
specification is covered. All 62 configurations synthesize with GHDL without errors and without latches, with and
without the image framing (`python lint/synth_check.py [--in-last]`).

Golden data of c38_header_bounds (TC-CO-48): the supplementary tables encoder of the CNES reference software stops
for more than 13 tables, so `tools/golden.py` encodes the table elements of the 15 tables in two groups and joins
them bit by bit. This gives the header of the standard. The table count is a field of the Essential subpart
(CCSDS 5.3.2.2, table 5-3), which the header tool writes with the full count of 15. The Supplementary Information
Tables subpart is the sequence of the tables (5.3.2.3.1.2); every table consists of its 16-bit description (table
5-4) and a Table Data subblock with only its own bit depths and elements, ending with fill bits to the next byte
boundary (5.3.2.3.2.2, 5.3.2.3.2.3). No field of a table depends on another table, and every table starts on a byte
boundary, so the element sequences of a group are those of its tables, and the header tool adds the description and
the fill bits of every table. Three checks confirm it: with 12 tables a single call and groups of 5 and of 1 table
give the same compressed image; the reference model, which writes the header from the clauses of the standard,
produces the same compressed image as the CNES software for all 15 tables; and the supplementary tables decoder of
the CNES software decodes each of the 15 tables from the compressed image to its values (`tools/golden.py` checks
this for every configuration with tables).

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
| GHDL command of a simulation: VUnit 5.0.0.dev7 appends the generics of a test to the list of the option `ghdl.sim_flags` in place, and configurations added after the option is set share that list, so a simulation would also run with the generics of a configuration started before it. `run.py` sets the option after adding the configurations, so every configuration had its own list; QuestaSim is not affected | `run.py` copies the list per simulation and stops when a GHDL command does not carry exactly the generics of its configuration; all configurations pass with this check |
| Review of the generic ranges: `BlockSize_g` other than 8, 16, 32 and 64 elaborated; the header carries the block size code of 64 while the block-adaptive coder codes blocks of the given size, so the compressed image cannot be decompressed (all earlier versions) | The elaboration stops (CO-CF-02); TC-CO-49 checks it |
| Review of the generic ranges: M above NZ, restricted code options with D above 4, rescaling counter sizes below max(4, gamma0 + 1) and accumulator initialisation values above min(D - 2, 14) elaborated, although the standard does not allow them | The elaboration stops (CO-CF-01 to CO-CF-03); TC-CO-49 checks every case |
| Review of the generic ranges: `Speculation_g` = false, `RamStyle_g` other than "auto", the bounds of `UserData_g`, `SupTableCount_g`, `UpdatePeriodExp_g`, `AbsBitDepth_g` and `RelBitDepth_g`, the interface widths other than 32 bits and image dimensions of 65536 were neither simulated nor synthesised | c38_header_bounds (TC-CO-48, TC-PR-38), the configurations without the speculative weight loop (TC-PR-39), and the bounds of TC-CO-49 |

## 3. Generic ranges

Generics of `ocp_core` (simulated: in a test of the regression or of the CCSDS test data set; synthesised: by
`lint/synth_check.py`, TC-CO-49). "Stops" names a value outside the range whose elaboration stops with its message.

| Generic | Declared range | Enforced by | Simulated values | Synthesised values |
| --- | --- | --- | --- | --- |
| `XSize_g`, `YSize_g`, `ZSize_g` | 1 to 65536; width 1 only with reduced prediction and column-oriented local sums | Type; `ocp_predictor` (width 1) | NX 1 to 64, NY 1 to 64, NZ 1 to 48; the test data set NX up to 66, NY up to 513, NZ up to 239 | The simulated values and 65536 for each, with the other dimensions at 1 or 2; width 1 with full prediction stops |
| `SubFrameDepth_g` | 1 to NZ (BI order) | Type; `ocp_core` (CO-CF-01) | 1 to 48; the test data set up to 32 | 1 to 48 and 65536; NZ + 1 stops |
| `DynamicRange_g` | 2 to 32 | Type | 2 to 32 (16 values) | 2 to 32 (16 values) |
| `SignedSamples_g`, `EncodingOrder_g`, `EntropyCoder_g`, `PredictionMode_g`, `LocalSum_g`, `Fidelity_g` | Boolean and the names of the standard's options | Type; `ocp_pkg` (string decoding) | Every value | Every value |
| `UserData_g` | 0 to 255 | Type | 0 to 255 (26 values) | 0 to 255 (26 values) |
| `OutputWordSize_g` | 1 to 8 | Type | 1 to 8 | 1 to 8 |
| `SupTableCount_g`, `SupTableData_g` | 0 to 15 tables | Type | 0 to 4 and 15 tables of 1 to 813 bytes; the test data set 10 and 11 tables | 0 to 4 and 15 tables |
| `PredictionBands_g` | 0 to 15 | Type | 0 to 15 (14 values) | 0 to 15 (14 values) |
| `RegisterSize_g` | max(32, D + Omega + 2) to 64 | Type; `ocp_predictor` (lower bound) | 32 to 64 (17 values) | 32 to 64 (17 values); 36 with D + Omega + 2 = 37 stops |
| `WeightResolution_g` | 4 to 19 | Type | 4 to 19 | 4 to 19 |
| `WeightUpdateInterval_g` | 4 to 11 | Type | 4 to 11 | 4 to 11 |
| `WeightUpdateVmin_g`, `WeightUpdateVmax_g` | -6 to 9, vmin <= vmax | Type; `ocp_predictor` (order) | -6 to 9 | -6 to 9; vmin 4 with vmax 3 stops |
| `WeightExpOffsetsUsed_g`, `WeightExpOffsetTable_g`, `WeightExpOffsets_g` | Flags; offsets -6 to 5 | Type of the flags | Both values of the flags; offsets -6 to 5 | Both values of the flags; offsets -6 to 5 |
| `CustomWeights_g`, `WeightInitTable_g`, `WeightInitResolution_g`, `WeightInitValues_g` | Flags; Q 0 to 22 | Type | Both values of the flags; Q 0, 4, 5, 6, 10, 11, 14, 22; the test data set Q 3, 7, 9 | Both values of the flags; Q 0, 4, 5, 6, 10, 11, 14, 22 |
| `PeriodicUpdate_g`, `UpdatePeriodExp_g` | Flag; u 0 to 9; not in BSQ order with near-lossless compression | Type; `ocp_predictor` (BSQ) | Both values; u 0, 1, 2, 9; the test data set u 3 to 8 | Both values; u 0, 1, 2, 9; periodic updating in BSQ order stops |
| `AbsBandDependent_g`, `RelBandDependent_g` | Flags | Type | Both values | Both values |
| `AbsBitDepth_g`, `RelBitDepth_g` | 1 to min(D - 1, 16) | Type (16) | DA and DR from 1 to 16 (9 values each) | DA and DR from 1 to 16 (9 values each) |
| `AbsErrorLimits_g`, `RelErrorLimits_g` | 0 to 2^DA - 1, 0 to 2^DR - 1 | User | Up to 255 and 7264; the test data set up to 65280 and 6412 | Up to 255 and 7264 |
| `SampleRepResolution_g` | 0 to 4 | Type | 0 to 4 | 0 to 4 |
| `DampingBandVarying_g`, `DampingTable_g`, `Damping_g`, `OffsetBandVarying_g`, `OffsetTable_g`, `Offset_g` | Flags; values 0 to 2^Theta - 1 | Type of the flags | Both values of the flags; values 0 to 15 | Both values of the flags; values 0 to 15 |
| `UnaryLimit_g` | 8 to 32 | Type | 8 to 32 (16 values) | 8 to 32 (16 values) |
| `RescaleCounterSize_g`, `InitialCountExp_g` | gamma\* max(4, gamma0 + 1) to 11, gamma0 1 to 8 | Type; `ocp_core` (CO-CF-03) | gamma\* 4 to 11, gamma0 1 to 8 | gamma\* 4 to 11, gamma0 1 to 8; gamma\* 4 with gamma0 4 stops |
| `AccuInitBandVarying_g`, `AccuInitTable_g`, `AccuInit_g` | Flags; 0 to min(D - 2, 14) | Type of the flags; `ocp_core` (CO-CF-03) | Both values of the flags; 0 to 14 | Both values of the flags; 0 to 14, also band-varying vectors shorter than NZ; 7 with D = 8 stops, as K and as a band-varying value |
| `HybridAccuInit_g`, `HybridAccuInitHigh_g` | 0 to 2^(D + gamma0) - 1 | User | Up to 2^33 - 1 | Up to 2^33 - 1 |
| `BlockSize_g` | 8, 16, 32, 64 | `ocp_core` (CO-CF-02) | 8, 16, 32, 64 | 8, 16, 32, 64; 12 stops |
| `RestrictedCodes_g` | Only with D <= 4 | `ocp_core` (CO-CF-02) | Both values | Both values; with D = 5 stops |
| `RefInterval_g` | 1 to 4096 | Type | 1 to 4096 (11 values) | 1 to 4096 (11 values) |
| `UseInLast_g` | Boolean | Type | Both values | Both values |
| `OutWidth_g` | 8, 16, 32, 64 | `ocp_core` | 8, 16, 32, 64 | 8, 16, 32, 64; 12 stops |
| `Speculation_g` | Boolean | Type | Both values (false in TC-PR-39) | Both values |
| `RamStyle_g` | Values of the synthesis tool | Open Logic (attribute value) | "auto" | "auto", "block" |
