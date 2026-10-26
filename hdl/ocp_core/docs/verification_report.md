# ocp_core: Verification Report

## 1. Test results

Run on 2026-10-25 with GHDL (mcode, in the CI of the repository), VUnit 5.0.0.dev7, UVVM (commit 4f1e13b), Open Logic
4.7.0-ft.9: `python run.py "*ocp_core*" "*ocp_bit_packer*"`. The same tests pass in QuestaSim (Questa Pro Microchip
Edition 2024.3, time resolution 1 fs, 2026-10-24 and 2026-10-25), with code coverage and in the optimised run without
it; the code coverage is in [coverage.md](../../../docs/coverage.md). The tests of the CCSDS test data set ran in GHDL
6.0.0 on 2026-10-24 (`OCP_TESTVECTORS`, selection of `tools/ocp_testvectors.py`).

| Testbench | Tests | Passed |
| --- | --- | --- |
| `ocp_core_tb` `test_golden` | 72 (62 configurations, every third random configuration with back pressure; 4 configurations also with back pressure; 3 sequences of 10 to 100 small images; 3 sequences of 6 to 20 hybrid images without back pressure, `_rate`, run with GHDL 6.0.0 on 2026-10-22), each also with `UseInLast_g` (`_last`) | 144 |
| `ocp_core_tb` `test_ecc` | 4 (every memory of the core), each also with `UseInLast_g` | 8 |
| `ocp_core_tb` `test_reset` | 5, each also with `UseInLast_g` | 10 |
| `ocp_core_tb` `test_framing` | 16 (eleven images with four early and two missing image end markers; aborted images back to back at every abort position of the configuration; eight images with `In_Error`; eight resets during the error handling) | 16 |
| `ocp_core_tb` `test_runtime` (TC-CO-52, TC-CO-54) | 7 (rc01 to rc05, sequences of 20 images; rc02 and rc04 also with back pressure), each also with `UseInLast_g` | 14 |
| `ocp_core_tb` `test_runtime_timing` (TC-CO-53) | 2 (rc01, rc04), each also with `UseInLast_g` | 4 |
| `ocp_core_tb` `test_runtime_range` (TC-CO-57) | 2 (rc04, rc05), each also with `UseInLast_g` | 4 |
| `ocp_core_tb` `test_runtime_queue` (TC-CO-58) | 3 (rc03, rc05 and rq06, rc05 with 128 bands, a configuration of this test only), each also with `UseInLast_g` | 6 |
| `ocp_core_tb` `test_runtime` (TC-CO-59) | 6 (rp01 to rp03, sequences of 21 images with their own runtime parameters, each also with back pressure), each also with `UseInLast_g` | 12 |
| `ocp_core_tb` `test_runtime_range` (TC-CO-60) | 3 (rp01 to rp03, 46, 44 and 21 images), each also with `UseInLast_g` | 6 |
| `ocp_core_tb` `test_runtime_queue` (TC-CO-61) | 5 (rp01 to rp03; rp01 and rp03 also with the output held after the header of a larger first image, `_hold`), each also with `UseInLast_g` | 10 |
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

With the image framing (`UseInLast_g`) every configuration produces the same compressed images, without `Out_Error` and
without `Ev_ImageError` (TC-CO-46); without it `In_Last` carries random values and changes nothing. In `test_framing`
(TC-CO-47) every image with an early `In_Last` equals byte by byte the compressed image of the samples taken
(`ocp_model.compress_aborted`, `tb/golden/<config>/aborted_<n>.bin`) at every abort position, also back to back, with
input gaps and output stalls, in BSQ, BIL, BIP and BI order with sub-frames and in the stride order with the three
coders, and carries `Out_Error` on its last word; every image with a missing `In_Last` equals the reference and carries
`Out_Error`; the samples after it up to the next `In_Last` are taken in the cycle they are offered; every correct image
before and after an error, also back to back and after a reset during the error handling, equals the reference, and
`Ev_ImageError` pulses once per image with an error. An image ended with `In_Last` and `In_Error` on its last sample
equals the reference and carries `Out_Error`; with an early `In_Last` it is aborted as without `In_Error`; `In_Error`
without `In_Last` or on discarded samples changes nothing (CO-FR-08). In the periodic configurations the error limit
source drops the remaining values of an aborted image, and the next image takes its own values. Every requirement of the
specification is covered. All 62 configurations synthesize with GHDL without errors and without latches, with and
without the image framing (`python lint/synth_check.py [--in-last]`); so do rc01 to rc05 with `RuntimeConfig_g` true,
also with the maxima NX = 65536 and NZ = M = 65536, and each of the nine combinations that CO-CF-04 excludes stops the
elaboration with its message (TC-CO-56).

With the runtime configuration (`RuntimeConfig_g` true) every image of the sequences of 20 images of rc01 to rc05
equals byte by byte the compressed image of `ocp_model` for the dimensions and error limit values of that image, also
with input gaps and output stalls (rc02, rc04) and with the image framing, and its header, decoded by the header
parser of `ocp_model`, carries them; `Cfg_Taken` pulses once per image and the `Act_` outputs show the values of the
image (TC-CO-52). Without back pressure the first sample of every image is accepted exactly in the cycle of the
throughput model with the runtime dimensions, the image-start cycles and the tail of the hybrid coder (TC-CO-54, all
five configurations). With configuration values that change two cycles before, in and two cycles after the acceptance
of the first sample of an image and in the middle of an image, every image uses the values of the cycle in which its
first sample is accepted; aborted images and discarded samples keep their configuration, and the next image takes the
new values (TC-CO-53). Values outside their ranges are taken as the nearest valid values, and the next valid image is
compressed normally (TC-CO-57). With the output held, the core holds back the first sample of the next image while 16
configurations wait, behind the header pointer (rc03, rc05) or behind the pointer of the hybrid coder tail (rq06,
whose first image has a tail longer than the codeword buffers), and no image or configuration is lost (TC-CO-58). With
`RuntimeConfig_g` false every existing test passes on the unchanged golden data (TC-CO-55; resources in section 5).

With the runtime parameters (`RuntimeParams_g` true) every image of the sequences of 21 images of rp01 to rp03 equals
byte by byte the compressed image of `ocp_model` for its dimensions, error limit values and runtime parameters, the
first image with every parameter at the high bound of its range, the second at the low bound, also with input gaps
and output stalls and with the image framing, and the last image with vmin = vmax = -6 reaches the clip of the weight
update scaling exponent at the vmax of the image; its header, decoded by the header parser of `ocp_model`, carries the
parameters, and the `Act_` outputs show them; without back pressure the first sample of every image is accepted in
the cycle of the throughput model with the M of the image (TC-CO-59). Parameters outside their ranges, alone and
together, are taken as the values limited in the order of CO-RP-02, among them gamma0 = 1 in rp02, below the lower
bound 2 that its initial accumulators set (TC-CO-60). With the output held, every image keeps its parameters while
16 configurations wait (TC-CO-61): behind the tail pointer of the hybrid coder (rp02), and, with the output held only
after the header of a larger first image, behind the read pointer of the sample-adaptive (rp01) and the
block-adaptive coder (rp03), where exactly 16 images are taken before the stall. In rp03 constant bands give runs of
all-zeros blocks, which end at the reference sample interval r of the image. With `RuntimeParams_g` false the tests
of rc01 to rc05 pass on their unchanged golden data, and the netlists keep the registers and the logic of version
0.2.0 (TC-CO-62, section 7).
rp01 to rp03 synthesize, and `RuntimeParams_g` without `RuntimeConfig_g` and a hybrid configuration without a valid
gamma0 stop the elaboration with their message (TC-CO-64). The elaboration checks for every value of every parameter
range that decoding its header field encoding gives the value back (TC-CO-63; a mutation of the decoding stops every
elaboration, section 8).

In the 12 configurations of TC-CO-50 (every coder without and with the stride order, from one sample per cycle to
25 cycles per sample, periodic error limit updating) the first sample of the second image is accepted exactly
`image_period` cycles after the first sample of the first image, also with the image framing (24 of 24 tests); in
stride order this is up to about 15 times the input span of the image (c33: 1739 cycles for 120 samples). Every
compressed image of the regression and of the CCSDS test data set is at most `max_image_bytes` long (TC-CO-51, 362
images, the largest ratio 1.00 for small images of the test data set); for incompressible images the bound is reached
to 99 %
(block-adaptive coder, c18), 70 % (sample-adaptive coder, c15) and 35 % (hybrid coder, c20).

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
| Review of the image framing: the bytes of an aborted image depended on the timing (input gaps, `Out_Ready`, the image before it), and a hybrid or block-adaptive prefix is not decodable without the end of the image | The image ends with its last sample taken through the predictor and the entropy coder; the aborted image is the compressed image of the samples taken (CO-FR-03, CO-FR-09); Drain, Close, `Flush` and the end codeword of one zero bit are removed |
| Hybrid coder, image that ends before every band has its first coded sample (t = 1): the tail took the final accumulators of the bands without statistics from the memory, which still held the values of the image before (found by `ocp_channel_tb` `test_errors`, r17_random) | The coder counts the bands initialised in the image (they come in increasing band order in every input order) and outputs the initial accumulator of the other bands (EC-HY-04); TC-CO-47 covers it in BSQ, BIL, BIP and stride order after an image with other accumulators. The hybrid configuration r01_random of TC-CO-47 could not show the defect: the final accumulators of its complete images equal its initial accumulators, so the stale values were the expected ones |
| `Out_Data` and `Out_Keep` changed one delta cycle before `Out_Valid` and `Out_Last`; an Open Logic width converter behind the core checks the byte enables of every valid word in simulation and stopped on that glitch (`ocp_channel`) | The four ports are assigned together |
| GHDL command of a simulation: VUnit 5.0.0.dev7 appends the generics of a test to the list of the option `ghdl.sim_flags` in place, and configurations added after the option is set share that list, so a simulation would also run with the generics of a configuration started before it. `run.py` sets the option after adding the configurations, so every configuration had its own list; QuestaSim is not affected | `run.py` copies the list per simulation and stops when a GHDL command does not carry exactly the generics of its configuration; all configurations pass with this check |
| Review of the generic ranges: `BlockSize_g` other than 8, 16, 32 and 64 elaborated; the header carries the block size code of 64 while the block-adaptive coder codes blocks of the given size, so the compressed image cannot be decompressed (all earlier versions) | The elaboration stops (CO-CF-02); TC-CO-49 checks it |
| Review of the generic ranges: M above NZ, restricted code options with D above 4, rescaling counter sizes below max(4, gamma0 + 1) and accumulator initialisation values above min(D - 2, 14) elaborated, although the standard does not allow them | The elaboration stops (CO-CF-01 to CO-CF-03); TC-CO-49 checks every case |
| Review of the generic ranges: `Speculation_g` = false, `RamStyle_g` other than "auto", the bounds of `UserData_g`, `SupTableCount_g`, `UpdatePeriodExp_g`, `AbsBitDepth_g` and `RelBitDepth_g`, the interface widths other than 32 bits and image dimensions of 65536 were neither simulated nor synthesised | c38_header_bounds (TC-CO-48, TC-PR-38), the configurations without the speculative weight loop (TC-PR-39), and the bounds of TC-CO-49 |
| Runtime parameters, first simulation: before the first write of an entry, the decoding of a field of the parameter queue at time 0 gave 0 for the value 2^bits ('U' bits compare unequal to 0, but convert to 0), a value outside the range of the decoded parameter | The decoding converts the field first and compares the integer |
| Runtime parameters, first netlist comparison with 0.2.0 (TC-CO-62): with `RuntimeParams_g` false the fields that carry the parameters through the pipelines of the predictor and the sample-adaptive coder, and the r of the blocks of the block-adaptive coder, were registers without loads (rc01 452 bits); a range of 1 to 1 took one bit per field | Without the generic these fields have the range 0 to 0 (no bits), the initial accumulator of the sample-adaptive coder is computed in a process of a generate block, and the queue-full condition without the coder read pointer is assigned as in 0.2.0 |
| Throughput model (all versions up to 0.1.1): with the hybrid coder the tail of every image (19 + NZ clock cycles without an item) holds back the next image once the output FIFO of the predictor is full; the model took the samples of consecutive images in the cycles of the predictor alone. TC-CO-50 checked only the first two images, for which the FIFO absorbs the tail. Found with the runtime configuration (sequences of small hybrid images) | `coder_cycles` of `tools/ocp_throughput.py` models the output of the predictor cycle by cycle (CO-TP-01); the sequences `_rate` of TC-CO-50 check the first sample of every image: measured and model are equal in every image (c22 from image 7 on 31 cycles per image instead of 6, c20 from image 2 five cycles more per image, c26 from image 3); the previous model would fail at image 7, 2 and 3. The core is unchanged |

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
| `RuntimeConfig_g` | Boolean; true excludes periodic updating, band-dependent error limits, the header tables whose length depends on NZ and supplementary information tables | Type; `ocp_core` (CO-CF-04) | Both values (true in rc01 to rc05, with NX, NY and NZ per image from 1 to the maxima) | Both values (true in rc01 to rc05, with NX = 65536 and with NZ = M = 65536); each of the nine excluded combinations stops |
| `RuntimeParams_g` | Boolean; true only with `RuntimeConfig_g`; with the hybrid coder some gamma0 up to min(8, `RescaleCounterSize_g` - 1) keeps every initial accumulator below 2^(D + gamma0) | Type; `ocp_core` (CO-CF-05) | Both values (true in rp01 to rp03, with every runtime parameter per image at the bounds of its range of CO-RP-02 and beyond them) | Both values (true in rp01 to rp03); without `RuntimeConfig_g` and without a valid gamma0 stops |

## 4. Mutations of the early end of an image

Each mutation was applied to the RTL once, outside the repository, and the named test was run; every one makes the
test fail. A mutation that stops the image (no further transfer) ends through the watchdog of the testbench, which
fails a job without a transfer for 20000 clock cycles.

| Mutation | Test | Result |
| --- | --- | --- |
| Stride order: the slot of the end sample is skipped as well (`>=` for `>`) | `test_framing` c33_small_bip_stride_block | Fails: no transfer for 20000 cycles |
| Stride order: the image ends one issued sample early | `test_framing` c33_small_bip_stride_block | Fails: no transfer for 20000 cycles |
| Stride order: the output buffer marks the sample before the end sample as the last item | `test_framing` c33_small_bip_stride_block | Fails: byte mismatch of the aborted image |
| Input order: the band position is not reset at the early end | `test_framing` c31_small_bi_periodic_abs | Fails: byte mismatch of the next image |
| Input order: the error limit state is not reset at the early end | `test_framing` c31_small_bi_periodic_abs | Fails: byte mismatch of the next image |
| Hybrid coder: the count of initialised bands is one too low | `test_framing` r21_random | Fails: byte mismatch already in a complete image |
| Hybrid coder: the count of initialised bands is not used (the tail reads every band from the memory) | `test_framing` r21_random | Fails: byte mismatch of the aborted image |

## 5. Resources with `RuntimeConfig_g` false (TC-CO-55)

The GHDL synthesis (GHDL 6.0.0, raw netlist) of the synthesis top level of every configuration of
`lint/synth_check.py` with `RuntimeConfig_g` false (the 62 configurations and the bounds b01 to b06) was compared
module by module with the synthesis of the same top level on the RTL of version 0.1.1, both with Open Logic
4.7.0-ft.9: the register bits (the width of every flip-flop cell) and the number of cells of every type.

- No module other than `ocp_predictor` and `ocp_hybrid_coder` differs in a register bit or in a cell, in any
  configuration.
- `ocp_predictor`: GHDL implements the register record of the two-process pattern as one flip-flop cell, so the
  fields added for the runtime configuration are part of it, although nothing reads them with the generic false
  (every read is in a branch of `RuntimeConfig_g`). These fields are the state of the image start (the hold register
  of the first sample, the dimensions and M of the image, the issue distances, the speculative run across rows) and
  three fields of every pipeline item (NX, the last column, the speculative run). The record of 0.1.1 is unchanged
  otherwise, so the added bits are exactly the width of these fields: 84 to 402 bits. 3 to 15 cells change with them
  (the multiplexers that write the fields).
- `ocp_hybrid_coder` (the 17 configurations with the hybrid coder): the output `Cfg_Done` (two `mux2` cells and one
  `pmux` cell), which `ocp_core` reads only with the runtime configuration, and the band of the tail, now computed once
  instead of three times (`smod` -2, `strunc` +1): a refactoring with the same function.

FPGA synthesis tools remove registers and logic without loads, so the utilisation after synthesis is expected to
equal that of version 0.1.1. CO-RC-06 is verified by this netlist analysis; the equality after synthesis is open
until the out-of-context flow of Vivado (`lint/vivado_ooc.py` c01) shows the same utilisation before and after the
runtime configuration.

| Configuration | Register bits of `ocp_predictor` | Added | Changed cells of `ocp_predictor` | Changed cells of `ocp_hybrid_coder` |
| --- | --- | --- | --- | --- |
| c01_lossless_bip | 27817 to 28004 | 187 | 14 | none |
| c02_lossless_bil_column | 22990 to 23153 | 163 | 14 | none |
| c03_lossless_bsq_narrow | 19120 to 19279 | 159 | 11 | none |
| c04_near_abs_hybrid | 62774 to 63067 | 293 | 3 | mux2 +2, pmux +1, smod -2, strunc +1 |
| c05_near_rel_bi4_signed | 58874 to 59165 | 291 | 14 | mux2 +2, pmux +1, smod -2, strunc +1 |
| c06_near_both_block | 70836 to 71129 | 293 | 3 | none |
| c07_lossless_block_bsq | 18863 to 19039 | 176 | 11 | none |
| c08_restricted_d4 | 16403 to 16559 | 156 | 14 | none |
| c09_custom_weights | 31906 to 32073 | 167 | 14 | none |
| c10_periodic_limits | 59792 to 60085 | 293 | 15 | mux2 +2, pmux +1, uextend -1 |
| c11_wide_d32 | 89940 to 90115 | 175 | 14 | none |
| c12_single_column | 17502 to 17601 | 99 | 14 | none |
| c13_single_band_hybrid | 24649 to 24814 | 165 | 14 | mux2 +2, pmux +1 |
| c14_supplementary_tables | 25219 to 25366 | 147 | 14 | none |
| c15_noise_escape | 21125 to 21292 | 167 | 14 | none |
| c16_hybrid_low_entropy | 48554 to 48882 | 328 | 3 | mux2 +2, pmux +1, uextend -1 |
| c17_block_zero_runs | 19392 to 19570 | 178 | 11 | none |
| c18_block_d24_mixed | 30281 to 30456 | 175 | 14 | none |
| c19_block_restricted_d2 | 31823 to 32100 | 277 | 15 | none |
| c20_hybrid_d28 | 36492 to 36651 | 159 | 14 | mux2 +2, pmux +1, smod -2, strunc +1 |
| c21_sample_periodic | 38334 to 38615 | 281 | 15 | none |
| c22_single_pixel_hybrid | 16419 to 16509 | 90 | 14 | mux2 +2, pmux +1, smod -1, strunc +1 |
| c23_extreme_weights | 21599 to 21750 | 151 | 14 | none |
| c24_reduced_p0 | 12999 to 13147 | 148 | 14 | none |
| c25_tp_bsq_lossless | 33081 to 33254 | 173 | 11 | none |
| c26_tp_bil_near_abs | 75093 to 75410 | 317 | 14 | mux2 +2, pmux +1, smod -2, strunc +1 |
| c27_tp_bip_full | 31978 to 32148 | 170 | 14 | none |
| c28_tp_bsq_near_abs | 54281 to 54593 | 312 | 11 | none |
| c29_tp_bip_near_stride | 58108 to 58367 | 259 | 3 | none |
| c30_tp_bip_both_stride | 42090 to 42347 | 257 | 3 | mux2 +2, pmux +1, smod -2, strunc +1, utrunc -1 |
| c31_small_bi_periodic_abs | 50009 to 50224 | 215 | 15 | none |
| c32_small_bip_periodic_rel | 42580 to 42792 | 212 | 15 | mux2 +2, pmux +1, smod -2, strunc +1 |
| c33_small_bip_stride_block | 55974 to 56193 | 219 | 3 | none |
| c34_small_bsq_lossless | 20715 to 20855 | 140 | 11 | none |
| c35_small_bil_periodic_spec | 50801 to 51113 | 312 | 15 | none |
| c36_block_j64_spikes | 13777 to 13959 | 182 | 11 | none |
| c37_block_d32_custom | 34992 to 35151 | 159 | 11 | none |
| c38_header_bounds | 52617 to 52851 | 234 | 15 | none |
| r01_random | 81720 to 82018 | 298 | 14 | mux2 +2, pmux +1, smod -2, strunc +1 |
| r02_random | 39936 to 40173 | 237 | 14 | mux2 +2, pmux +1 |
| r03_random | 117431 to 117833 | 402 | 11 | none |
| r04_random | 40846 to 41052 | 206 | 15 | none |
| r05_random | 24620 to 24704 | 84 | 14 | mux2 +2, pmux +1, smod -2, strunc +1 |
| r06_random | 101172 to 101377 | 205 | 14 | none |
| r07_random | 68032 to 68173 | 141 | 11 | mux2 +2, pmux +1 |
| r08_random | 124161 to 124408 | 247 | 11 | none |
| r09_random | 51507 to 51650 | 143 | 14 | none |
| r10_random | 41943 to 42042 | 99 | 14 | none |
| r11_random | 18686 to 18808 | 122 | 14 | none |
| r12_random | 44696 to 44858 | 162 | 14 | none |
| r13_random | 63404 to 63680 | 276 | 14 | none |
| r14_random | 29955 to 30084 | 129 | 11 | mux2 +2, pmux +1 |
| r15_random | 74669 to 74841 | 172 | 11 | none |
| r16_random | 100111 to 100361 | 250 | 14 | none |
| r17_random | 24804 to 24967 | 163 | 14 | mux2 +2, pmux +1 |
| r18_random | 48089 to 48240 | 151 | 14 | none |
| r19_random | 39154 to 39285 | 131 | 14 | none |
| r20_random | 148380 to 148638 | 258 | 14 | none |
| r21_random | 25453 to 25554 | 101 | 11 | mux2 +2, pmux +1, smod -2, strunc +1 |
| r22_random | 16516 to 16635 | 119 | 3 | none |
| r23_random | 31277 to 31410 | 133 | 14 | none |
| r24_random | 25847 to 25972 | 125 | 14 | none |
| b01_x_65536 | 29347 to 29680 | 333 | 14 | none |
| b02_y_65536 | 15469 to 15561 | 92 | 14 | none |
| b03_z_m_65536 | 19942 to 20066 | 124 | 14 | none |
| b04_bsq_z_65536 | 29553 to 29678 | 125 | 11 | none |
| b05_no_speculation | 22215 to 22388 | 173 | 11 | none |
| b06_ram_style_block | 27817 to 28004 | 187 | 14 | none |

## 6. Mutations of the runtime configuration

Each mutation was applied to the RTL once, outside the repository, and the named test was run; before the mutations
the nine tests passed on the unchanged RTL. Every mutation makes its test fail with the check named.

| Mutation | Test | Result |
| --- | --- | --- |
| `ocp_predictor`: NX of the configuration not taken (the image keeps the NX of the image before) | `ocp_predictor_tb` rc01 `test_runtime` | Fails: mapped quantizer index of an item differs from the reference model |
| `ocp_predictor`: issue distance within a band 0 | `ocp_predictor_tb` rc04 `test_runtime` | Fails: mapped quantizer index of an item differs from the reference model |
| `ocp_core`: NX = 1 not raised to 2 where full prediction needs NX >= 2 (CO-RC-07) | `ocp_core_tb` rc04 `test_runtime_range` | Fails: `Act_XSize` of the image |
| `ocp_core`: the header read pointer of the configuration queue moves on at the start of a header instead of its end | `ocp_core_tb` rc01 `test_runtime` | Fails: byte mismatch of the compressed image |
| `ocp_header`: the sub-frame interleaving depth of the maxima in BI order | `ocp_core_tb` rc02 `test_runtime` | Fails: byte mismatch in the header |
| `ocp_hybrid_coder`: the tail covers the bands of the maximum NZ | `ocp_core_tb` rc05 `test_runtime` | Fails: byte mismatch of the compressed image |
| `ocp_image_framer`: the dimensions of an image not taken at its first sample | `ocp_core_tb` rc01 `test_runtime` with `UseInLast_g` | Fails: error flag on the last word of a correct image |
| `ocp_mib`: a COMMIT in the cycle of `Cfg_Taken` does not leave CFG_PENDING set | `ocp_mib_tb` rc04 `test_runtime_commit` | Fails: STATUS after the COMMIT |
| `ocp_mib`: NX of a COMMIT reaches the configuration output one clock cycle after the other fields | `ocp_mib_tb` rc04 `test_runtime_commit` | Fails: the values taken with a COMMIT before `Cfg_Taken` |
| `ocp_mib`: no range check of NZ | `ocp_mib_tb` rc04 `test_runtime_config` | Fails: STATUS (CFG_ERROR) after NZ = 0 |

## 7. Netlist without the runtime parameters (TC-CO-62)

The GHDL synthesis (GHDL 6.0.0) of the synthesis top level of rc01 to rc05 with `RuntimeConfig_g` true and
`RuntimeParams_g` false was compared with the synthesis of the same top level on the RTL of version 0.2.0, each tree
with its own compiled libraries: the register bits (the width of every signal assigned in a clocked process) and the
statements of every source file with their operators.

| Configuration | Register bits (0.2.0, this version) | Statements | Difference |
| --- | --- | --- | --- |
| rc01_bi_m1_sample | 29793, 29793 | 35352, 35374 | 22 constant wires in `ocp_core` |
| rc02_bi_mnz_hybrid_abs | 71064, 71064 | 39501, 39522 | 21 constant wires in `ocp_core` |
| rc03_bsq_block_rel | 59945, 59945 | 34230, 34249 | 19 constant wires in `ocp_core` |
| rc04_bi_m4_sample_both | 71535, 71535 | 44329, 44351 | 22 constant wires in `ocp_core` |
| rc05_bsq_column_hybrid | 30081, 30081 | 27069, 27090 | 21 constant wires in `ocp_core` |

The register bits are equal, and no source file has a different number of operators. The additional statements are
slices of constant signals: the runtime parameters of the generics (and the entry of a queue without parameter
fields) on the new inputs of the predictor, the header generator and the entropy coder, which these units do not read
with the generic false, and one truncation of the constant read pointer of the coders. They carry no logic.

## 8. Mutations of the runtime parameters

One mutation per new decision path of the runtime parameters, each applied once to the RTL in a separate worktree;
before the mutations the tests of every group passed on the unchanged RTL. Every mutation makes its test fail with
the check named. 46 mutations were caught by the tests of the first version of this change; the other five (the
queue-full condition of the coder read pointer, vmax of the image, the M < NZ flag of the sequencer and both r
mutations of the block-adaptive coder) were missed and are caught by the tests added for them: the queue test with
the output held after the header of a larger first image, the last image of every parameter sequence (vmin = vmax =
-6, log2 t_inc 4, r = 2), rp03 with constant bands and small r, and the sweep of c01 with every M.

| Unit | Mutation | Test | Result |
| --- | --- | --- | --- |
| `ocp_core` | Lower bound of log2 t_inc 5 instead of 4 | rp01 `test_runtime_range` | `Act_WeightInterval` of the image |
| `ocp_core` | Lower bound of vmin -5 instead of -6 | rp01 `test_runtime_range` | `Act_WeightVmin` |
| `ocp_core` | vmax limited against -6 instead of the limited vmin | rp01 `test_runtime_range` | `Act_WeightVmax` |
| `ocp_core` | Upper bound of Umax 31 instead of 32 | rp01 `test_runtime_range` | `Act_UnaryLimit` |
| `ocp_core` | Upper bound of gamma0 min(7, ...) instead of min(8, ...) | rp01 `test_runtime_range` | `Act_InitCountExp` |
| `ocp_core` | Lower bound of gamma0 1 instead of the bound from the initial accumulators | rp02 `test_runtime_range` | `Act_InitCountExp` (1 instead of 2) |
| `ocp_core` | gamma\* limited against the driven instead of the limited gamma0 | rp01 `test_runtime_range` | `Act_RescaleSize` |
| `ocp_core` | Upper bound of gamma\* one below `RescaleCounterSize_g` | rp01 `test_runtime_range` | `Act_RescaleSize` |
| `ocp_core` | Upper bound of K 13 instead of min(D - 2, 14) | rp01 `test_runtime_range` | `Act_AccuInit` |
| `ocp_core` | Upper bound of r one below `RefInterval_g` | rp03 `test_runtime_range` | `Act_RefInterval` |
| `ocp_core` | Lower bound of M 2 instead of 1 | rp01 `test_runtime_range` | `Act_M` |
| `ocp_core` | M limited against the driven instead of the limited NZ | rp01 `test_runtime_range` | Range of M exceeded (GHDL bound check) |
| `ocp_core` | Coder read pointer never moves on | rp01 `test_runtime` | Byte mismatch of the second image |
| `ocp_core` | Queue full one entry later for the coder read pointer | rp01, rp03 `test_runtime_queue` `_hold` | 17 images taken before the stall instead of 16 |
| `ocp_core` | Active parameters not taken | rp01 `test_runtime` | `Act_UserData` |
| `ocp_pkg` | Decoding of the value 2^bits gives 2^bits - 1 | rp03 `test_runtime` (every elaboration) | Elaboration assertion of CO-RP-05 |
| `ocp_header` | User-defined data not placed | rp01 `test_runtime` | Header byte 0 |
| `ocp_header` | M not placed | rp01 `test_runtime` | Header byte 9 |
| `ocp_header` | vmax not placed | rp01 `test_runtime` | Header byte 15 |
| `ocp_header` | gamma\* not placed | rp02 `test_runtime` | Header byte 23 |
| `ocp_header` | K not placed | rp01 `test_runtime` | Header byte 24 |
| `ocp_header` | r not placed | rp03 `test_runtime` | Header byte 20 |
| `ocp_predictor` | log2 t_inc of the generic instead of the item | rp01 `test_runtime` | Byte mismatch in the body |
| `ocp_predictor` | vmin of the generic instead of the item | rp01 `test_runtime` | Byte mismatch in the body |
| `ocp_predictor` | vmax of the generic instead of the item in the clip | rp01 `test_runtime` | Byte mismatch in the body of the last image |
| `ocp_predictor` | No memory of the local differences of the previous sub-frame without M < `ZSize_g` | rp02 `test_runtime` | Byte mismatch in the body |
| `ocp_image_start` | M of the image not taken (min(`SubFrameDepth_g`, NZ)) | rp01, rp02 `test_sweep` | Out_M |
| `ocp_image_start` | M < NZ replaced by NZ > `SubFrameDepth_g` | c01 `test_sweep` with every M | Distance to the previous band |
| Sample-adaptive coder | Initial accumulator of the generics | rp01 `test_runtime` | Byte mismatch in the body |
| Sample-adaptive coder | Initial count of the generic gamma0 | rp01 `test_runtime` | Byte mismatch in the body |
| Sample-adaptive coder | Rescaling threshold of the generic gamma\* | rp01 `test_runtime` | Byte mismatch in the body |
| Sample-adaptive coder | Umax of the generic | rp01 `test_runtime` | Byte mismatch in the body |
| Sample-adaptive coder | First factor of the initial accumulator of K = 4 for every K | rp01 `test_runtime` | Byte mismatch in the body |
| Hybrid coder | Umax of the generic | rp02 `test_runtime` | Byte mismatch in the body |
| Hybrid coder | Initial count of the generic gamma0 | rp02 `test_runtime` | Byte mismatch in the body |
| Hybrid coder | Rescaling threshold of the generic gamma\* | rp02 `test_runtime` | Byte mismatch in the body |
| Hybrid coder | Final accumulators of the tail with the width of the generic gamma\* | rp02 `test_runtime` | Byte mismatch in the tail |
| Block-adaptive coder | Reference sample interval of the generic instead of the block | rp03 `test_runtime` | Byte mismatch in the body |
| Block-adaptive coder | r of the item not taken | rp03 `test_runtime` | Byte mismatch in the body |
| `ocp_mib` | Upper bound of log2 t_inc 12 | rp01 to rp03 `test_runtime_params` | STATUS after log2 t_inc 12 |
| `ocp_mib` | vmax checked against -6 instead of the pending vmin | rp01 to rp03 `test_runtime_params` | STATUS after vmax below vmin |
| `ocp_mib` | M not checked against the pending NZ | rp01 to rp03 `test_runtime_params` | STATUS after M 2 with NZ 1 |
| `ocp_mib` | Upper bound of Umax 33 | rp01 to rp03 `test_runtime_params` | STATUS after Umax 33 |
| `ocp_mib` | Lower bound of gamma0 1 instead of the bound from the initial accumulators | rp01 to rp03 `test_runtime_params` | STATUS after gamma0 below its lower bound (rp02) |
| `ocp_mib` | gamma\* not checked against the pending gamma0 | rp01 to rp03 `test_runtime_params` | STATUS after gamma\* = gamma0 |
| `ocp_mib` | Upper bound of K 15 | rp01 to rp03 `test_runtime_params` | STATUS after K above min(D - 2, 14) |
| `ocp_mib` | Lower bound of r not checked | rp01 to rp03 `test_runtime_params` | STATUS after r 0 |
| `ocp_mib` | COMMIT without the check of the parameters | rp01 to rp03 `test_runtime_params` | STATUS after vmin -7 |
| `ocp_mib` | M written in BSQ order | rp01 to rp03 `test_runtime_params` | Readback of NEXT_ORDER in rp03 |
| `ocp_mib` | Parameters not committed | rp01 to rp03 `test_runtime_params` | `Cfg_UserData` after a valid COMMIT |
| `ocp_mib` | SAMPLES.USER_DATA not read from `Act_UserData` | rp01 to rp03 `test_runtime_params` | SAMPLES |
