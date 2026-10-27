# OpenCompact: Code Coverage

## 1. Method

The code coverage of the OpenCompact sources is measured with QuestaSim (Questa Pro Microchip Edition 2024.3, time
resolution 1 fs) over the complete regression of `run.py`, the same test set that GHDL runs in CI:

```shell
python run.py --questa --coverage -p 1
```

The sources of `hdl/<module>/src` are compiled with `+cover=sbcef`: statements, branches, conditions, expressions
(focused expression coverage) and state machines. Open Logic, UVVM and the testbenches are not instrumented; Open Logic
is verified by its own regression. `run.py` merges the coverage of all tests into `coverage/coverage.ucdb` and writes
the reports `coverage/coverage_report.txt` (details per instance) and `coverage/coverage_byfile.txt`; a design unit
is covered when any of its instances in any test covers it.

Closure rules:

- Statements, branches, state machine states and transitions: every item is covered by a test or listed with its
  justification in section 4.
- Conditions and expressions: every miss is reviewed for untested behaviour (section 3); a remaining miss is listed
  with its justification in section 4.
- The design contains no coverage exclusions (`coverage off` pragmas).

## 2. Results

Run on 2026-10-26 and 2026-10-27 with Open Logic 4.7.0-ft.9: 613 tests (the testbenches of the predictor and its
image-start sequencer, the entropy coders, the bit packer and the core with all configurations of
`tools/ocp_configs.py`, the runtime configurations and the runtime parameter configurations, the core configurations
also with the image framing and the aborted images at every abort position, and the testbenches of the input adapter,
the MIB and the channel), all passed in QuestaSim as in GHDL, with code coverage and in the optimised run without it.
The regression ran in twelve parts by testbench; the tests added by the review of this coverage (section 3) ran in
both modes; `vcover merge` combines the coverage databases of all parts. Numbers are covered/total bins per file; bold
marks a metric with misses.

| File | Statements | Branches | Conditions | Expressions | FSM States | FSM Transitions |
| --- | --- | --- | --- | --- | --- | --- |
| `ocp_pkg.vhd` | **101 / 114 (88.6 %)** | **46 / 51 (90.2 %)** | **1 / 2 (50.0 %)** | **16 / 33 (48.5 %)** | | |
| `ocp_predictor.vhd` | **766 / 769 (99.6 %)** | **366 / 367 (99.7 %)** | **85 / 108 (78.7 %)** | **70 / 75 (93.3 %)** | | |
| `ocp_sample_adaptive_coder.vhd` | 123 / 123 | 45 / 45 | 9 / 9 | 14 / 14 | | |
| `ocp_hybrid_coder.vhd` | **220 / 221 (99.5 %)** | **69 / 71 (97.2 %)** | **24 / 25 (96.0 %)** | 16 / 16 | 3 / 3 | 4 / 4 |
| `ocp_block_adaptive_coder.vhd` | 218 / 218 | 101 / 101 | **15 / 18 (83.3 %)** | 12 / 12 | | |
| `ocp_cw_buffer.vhd` | 33 / 33 | 13 / 13 | 9 / 9 | 6 / 6 | | |
| `ocp_header.vhd` | 212 / 212 | 78 / 78 | 8 / 8 | | | |
| `ocp_bit_packer.vhd` | 105 / 105 | 31 / 31 | 2 / 2 | | | |
| `ocp_image_framer.vhd` | **73 / 74 (98.6 %)** | **39 / 40 (97.5 %)** | 9 / 9 | 8 / 8 | 2 / 2 | 2 / 2 |
| `ocp_core.vhd` | 205 / 205 | 111 / 111 | 23 / 23 | 9 / 9 | | |
| `ocp_input_adapter.vhd` | **47 / 48 (97.9 %)** | **19 / 20 (95.0 %)** | 11 / 11 | 12 / 12 | 2 / 2 | 2 / 2 |
| `ocp_mib.vhd` | 218 / 218 | **122 / 123 (99.2 %)** | **25 / 27 (92.6 %)** | 42 / 42 | | |
| `ocp_channel.vhd` | 14 / 14 | 5 / 5 | 3 / 3 | **8 / 10 (80.0 %)** | | |
| `ocp_image_start.vhd` | **53 / 54 (98.1 %)** | **31 / 32 (96.9 %)** | | 11 / 11 | 3 / 3 | **3 / 4 (75.0 %)** |
| Total | 2388 / 2408 (99.2 %) | 1076 / 1088 (98.9 %) | 224 / 254 (88.2 %) | 224 / 248 (90.3 %) | 10 / 10 (100.0 %) | 11 / 12 (91.7 %) |

Every statement and branch that runs in simulation is covered except six items (the recovery branches of the state
machines of the tail, the image framer, the input adapter and the image-start sequencer, the wait of the flush words
of the tail, and the implicit `else` of the register decoder of the runtime parameters of the MIB, which no caller
reaches), and every condition and expression term whose value can change in a simulation is covered (the saturation of
a 32-bit counter of the MIB needs 2^32 - 1 events); section 4 lists all misses. The predictor and the
sample-adaptive and block-adaptive coders are pipelines without state machines; the tail of the hybrid coder, the
image framer, the input adapter and the image-start sequencer are the state machines, and all their states and
transitions are reached except the recovery transition of the sequencer.

## 3. Gaps found and closed

The review of the coverage found behaviour that no test exercised. Each gap was closed by a new configuration or a
new test variant; no gap needed a change of the design.

| Gap | Resolution |
| --- | --- |
| Memory errors: the error flags of the memories and their effect on the compressed image | Error injection port of the core; TC-CO-37 injects a single and a double bit error into every memory |
| Reset during an image (header, body, tail of the hybrid coder) | TC-CO-38: resets at random times |
| Bit packer: two image ends in the queue | Unit testbench of the bit packer with small images under sink stalls (TC-CO-41) |
| Image sequencing: an image starts in the cycle in which the header of a waiting image starts | Sequences of 10 to 100 small images with input gaps and output stalls (TC-CO-43) |
| Error limit values of periodic updating in the speculative weight loop (BIL order, reduced prediction with narrow local sums) | c35_small_bil_periodic_spec (TC-PR-36, TC-CO-44) |
| Output FIFO of the predictor full when the error limit values of an update period are due | c35_small_bil_periodic_spec at one sample per clock cycle with 80 % output stalls (TC-PR-37) |
| Stride order: output buffer and output FIFO full | c29 and c30 with 80 % output stalls (TC-PR-37) |
| Hybrid coder: codeword buffer full during the samples and during the final accumulators of the tail | c20 and c30 with 90 % sink stalls in the unit testbench (TC-EC-05) |
| Block-adaptive coder: two fundamental sequence codewords that do not fit into one codeword together; a run of all-zeros blocks before the last block of an image | c36_block_j64_spikes: J = 64, constant bands with spikes (TC-CO-44) |
| Block-adaptive coder: split-sample options with k >= 25 (fewer than four sets of split bits per codeword) | c37_block_d32_custom: D = 32 with noise of 1/64 of the range (TC-CO-44) |
| Custom weight initialization with Q = Omega + 3 (no fill bits) | c37_block_d32_custom (TC-PR-36) |
| Image framer: the write and the read of an error flag in the same clock cycle (condition rows of the flag count) | The count is the difference of the write and the read pointer; no condition is left |
| Runtime configuration: the configuration queue full (16 configurations waiting), the core holds back the first sample of the next image | TC-CO-58: images of the smallest size with the output held low, rc03 and rc05 (the queue pointer of the hybrid coder tail) |
| MIB: writes of CONTROL and STATUS with byte lane 0 disabled or with the bit '0' | TC-MB-05: such writes commit nothing and leave CFG_ERROR set |
| Image-start sequencer without prediction bands (P = 0) | A sweep configuration with P = 0 (TC-PR-40) |
| Block-adaptive coder: saturation of the length of a second extension symbol above 8191 (a miss of version 0.1.1) | Reached by the regression of version 0.2.0: the length of every code option is computed for every block, also of the options that are not selected |
| Runtime parameters: the configuration queue full behind the tail pointer of the hybrid coder (the header pointer has room) | rp04 in TC-CO-61: rq06 with the runtime parameters, a first image of 128 bands whose tail is longer than the codeword buffers |
| Runtime parameters: the end of a segment of 64 blocks within the reference sample interval of an image (block-adaptive coder) | rp05 in TC-CO-59: blocks of 8 samples, images of 75 blocks with r = 4096 |
| Runtime parameters: the K field of the header with band-varying accumulator initialisation values | rp06 in TC-CO-59: the sample-adaptive coder with band-varying values; the header carries 15 |
| MIB: reads of the addresses after NEXT_BLOCK with the runtime parameters | TC-MB-08 reads every unused address |

## 4. Remaining misses

| Location | Item not covered | Justification |
| --- | --- | --- |
| `ocp_pkg.vhd` | The `failure` reports of the decoding of invalid string generics (statements and the implicit `else` branches); `bandTableStart` called from `bandsUsed`; `imageStartCycles` (a constant of the image-start testbench) | Run during elaboration only (QuestaSim does not count elaboration); an invalid generic stops the elaboration |
| `ocp_predictor.vhd` | The function `anyNonZero` | Runs during elaboration only (a constant of the generics) |
| `ocp_hybrid_coder.vhd` | `when others` of the tail state machine | Recovery from an illegal state; needs an upset in the state register |
| `ocp_image_framer.vhd` | `when others` of the framer state machine | Recovery from an illegal state; needs an upset in the state register |
| `ocp_input_adapter.vhd` | `when others` of the state machine | Recovery from an illegal state; needs an upset in the state register |
| `ocp_image_start.vhd` | `when others` of the sequencer state machine (statement, branch and transition) | Recovery from an illegal state; needs an upset in the state register |
| `ocp_predictor.vhd` | Expression rows with `RuntimeConfig_g` = false of `RuntimeConfig_g and SeqDone = '1'`, `RunRows_c or (RuntimeConfig_g and RunRows = '1')` and `not Periodic_c and not RuntimeConfig_g` | The rows need a value that the other term cannot take for that generic value: with `RuntimeConfig_g` false the image-start sequencer never signals done and the item field RunRows is never '1' (it is written only with the generic true); the condition of the two constants is static, and both of its branches are covered |
| `ocp_mib.vhd` | Condition term `r.Cnt(i) /= (others => '1')` false: an event at a saturated counter | A counter saturates after 2^32 - 1 events, which no simulation reaches; the saturation is verified by inspection ([MIB verification plan](../hdl/ocp_mib/docs/verification_plan.md), section 4) |
| `ocp_channel.vhd` | Expression terms `WordValid` = '0' and `WordLast` = '0' of the event of an aborted image (`WordValid and WordReady and WordLast and WordError`) | `Out_Error` of the core is '1' only with `Out_Valid` and `Out_Last` (CO-FR-05), so `WordError` = '1' implies both terms |
| `ocp_hybrid_coder.vhd` | Flush words of the tail waiting for room in the codeword buffer | The buffer has at least two free entries when the last item of an image enters the coder, and the short flush words join in the held codeword: the wait needs flush words that fill more than one codeword while the output takes none, which the regression does not produce |
| `ocp_block_adaptive_coder.vhd` | Condition terms `r.Idx /= J_c - 1` and `r.S2Valid = '0'` false while the selection stage holds a block | With three block buffers, a block in the selection stage moves on within one cycle: a held selection stage would need a fourth buffer |
| `ocp_hybrid_coder.vhd` | Condition term `I_v.Valid = '0'` false with no item in flight | An item at the output stage is counted in flight, so no item in flight implies no item at the output stage |
| `ocp_pkg.vhd` | Condition term `width > 1` of the error injection pattern | The codeword width of a SECDED memory is always larger than one bit |
| `ocp_predictor.vhd` | Condition terms `i.AAlways = '1'`, `i.BAlways = '1'` (error sign thresholds) | Always false: a sample lies between smin and smax, so the thresholds are never beyond the range of the high-resolution predicted sample |
| `ocp_predictor.vhd` | Condition term `Val_v < 0` false with `Sat_v` (weight increment) | `Sat_v` is set only for a value other than zero, and a positive value is handled by the branch before |
| `ocp_predictor.vhd` | Condition terms on constants of the generics (`Periodic_c`, `Narrow_c`, `P_c > 0`, `Cmax_c > 0`, `i < Lcross_c`, `j < Cmax_c`) | Constant in every configuration; with the constant evaluated first the other terms are not evaluated, so focused condition coverage cannot see their rows. Both values of every constant occur in the regression |
| `ocp_predictor.vhd` | Condition term `r.SubLow = 0` false at band 0 | The first band of the sub-frame of band 0 is band 0 |
| `ocp_predictor.vhd` | Condition terms of the dependency on the sample of the previous band at x - 1 (narrow local sums at y = 0), in BI order and in stride order | That sample is issued before the sample of the previous band at x, which the same check holds back for at least as long; the term cannot change the result |
| `ocp_predictor.vhd` | Condition terms `Kind = ItemSample_c` false: with t = 0 (`First`), at the end of an image (`Last`), in lossless compression and in stride order | Error limit values never carry these flags: they precede the samples of an update period, and periodic updating is used neither in lossless compression nor in stride order |
| `ocp_predictor.vhd` | Condition term `Par_v <= theta` false in the mapper | The branch runs only when the magnitude of the quantizer index is at most theta, and `Par_v` is plus or minus that magnitude |
| `ocp_pkg.vhd` | Expression rows with a false result of `paramCodingExact` (17 terms: the decoding of the encoding of every header field of the runtime parameters gives the value back) | The check of CO-RP-05 that every header field encoding is exact over its range; a false row needs an encoding that does not decode to its value, which the encodings never produce, and it would stop the elaboration |
| `ocp_pkg.vhd` | `return 9` of `hybridG0Min` (no gamma0 up to 8 keeps every initial accumulator below 2^(D + gamma0)) | Runs during elaboration only; such a configuration stops the elaboration (TC-CO-64) |
| `ocp_mib.vhd` | The implicit `else` of the decoder of the pending parameter registers (`parWord`) | The callers pass only the indices of NEXT_SAMPLES to NEXT_BLOCK: the read path checks the range first, the write path branches per register |
| `ocp_mib.vhd` | Condition row `RuntimeParams_g` = false of `RuntimeParams_g and RbWr = '1'` | With the generic false the condition is static and folded at elaboration, so no row is recorded; both branches of the statement are covered |

## 5. Reproduction

```shell
python run.py --questa --coverage -p 1
vcover report -byfile -details -output coverage/coverage_details.txt coverage/coverage.ucdb
```

The second command lists the coverage per file, merged over all instances, with every item that is not covered.
