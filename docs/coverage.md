# OpenCompact: Code Coverage

## 1. Method

The code coverage of the OpenCompact sources is measured with QuestaSim (Questa Pro Microchip Edition 2024.3) over the
complete regression of `run.py`, the same test set that GHDL runs in CI:

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

Run on 2026-10-16 with Open Logic 4.7.0-ft.6: 342 tests (the testbenches of the predictor, the entropy coders, the
bit packer and the core with all configurations of `tools/ocp_configs.py`, the core configurations also with the image
framing), all passed in QuestaSim as in GHDL, with code coverage and in the optimised run without it. The regression
ran in seven parts by testbench; `vcover merge` combines the coverage databases of the parts. Numbers are
covered/total bins per file; bold marks a metric with misses.

| File | Statements | Branches | Conditions | Expressions | FSM States | FSM Transitions |
| --- | --- | --- | --- | --- | --- | --- |
| `ocp_pkg.vhd` | **30 / 41 (73.2 %)** | **27 / 32 (84.4 %)** | **1 / 2 (50.0 %)** | | | |
| `ocp_predictor.vhd` | **674 / 677 (99.6 %)** | **323 / 324 (99.7 %)** | **76 / 96 (79.2 %)** | **56 / 60 (93.3 %)** | | |
| `ocp_sample_adaptive_coder.vhd` | 97 / 97 | 30 / 30 | 9 / 9 | 14 / 14 | | |
| `ocp_hybrid_coder.vhd` | **200 / 201 (99.5 %)** | **59 / 61 (96.7 %)** | **21 / 22 (95.5 %)** | 14 / 14 | 3 / 3 | 4 / 4 |
| `ocp_block_adaptive_coder.vhd` | **210 / 211 (99.5 %)** | **96 / 97 (99.0 %)** | **17 / 20 (85.0 %)** | 5 / 5 | | |
| `ocp_cw_buffer.vhd` | 33 / 33 | 13 / 13 | 9 / 9 | 6 / 6 | | |
| `ocp_header.vhd` | 167 / 167 | 60 / 60 | 2 / 2 | | | |
| `ocp_bit_packer.vhd` | 105 / 105 | 31 / 31 | 2 / 2 | | | |
| `ocp_image_framer.vhd` | **51 / 52 (98.1 %)** | **31 / 32 (96.9 %)** | 13 / 13 | 3 / 3 | 4 / 4 | 6 / 6 |
| `ocp_core.vhd` | 33 / 33 | 30 / 30 | 9 / 9 | 15 / 15 | | |
| Total | 1600 / 1617 (98.9 %) | 700 / 710 (98.6 %) | 159 / 184 (86.4 %) | 113 / 117 (96.6 %) | 7 / 7 (100.0 %) | 10 / 10 (100.0 %) |

Every statement and branch that runs in simulation is covered except four items (the recovery branches of the tail
state machine and of the image framer, the wait of the flush words of the tail and the saturation of a second
extension symbol), and every condition and expression term whose value can change is covered; section 4 lists all
misses. The predictor and the sample-adaptive and block-adaptive coders are pipelines without state machines; the tail
of the hybrid coder and the image framer are the state machines, and all their states and transitions are reached.

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
| Image framer: a reset while the framer waits for the image before an aborted one | TC-CO-47 resets the core with the error event of an image that follows a correct image back to back |
| Image framer: the write and the read of an error flag in the same clock cycle (condition rows of the flag count) | The count is the difference of the write and the read pointer; no condition is left |

## 4. Remaining misses

| Location | Item not covered | Justification |
| --- | --- | --- |
| `ocp_pkg.vhd` | The `failure` reports of the decoding of invalid string generics (statements and the implicit `else` branches); `bandTableStart` called from `bandsUsed` | Run during elaboration only (QuestaSim does not count elaboration); an invalid generic stops the elaboration |
| `ocp_predictor.vhd` | The function `anyNonZero` | Runs during elaboration only (a constant of the generics) |
| `ocp_hybrid_coder.vhd` | `when others` of the tail state machine | Recovery from an illegal state; needs an upset in the state register |
| `ocp_image_framer.vhd` | `when others` of the framer state machine | Recovery from an illegal state; needs an upset in the state register |
| `ocp_hybrid_coder.vhd` | Flush words of the tail waiting for room in the codeword buffer | The buffer has at least two free entries when the last item of an image enters the coder, and the short flush words join in the held codeword: the wait needs flush words that fill more than one codeword while the output takes none, which the regression does not produce |
| `ocp_block_adaptive_coder.vhd` | Saturation of a second extension symbol above 8191 | Requires a pair of values with a sum of 127; such a symbol never gives the shortest option |
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

## 5. Reproduction

```shell
python run.py --questa --coverage -p 1
vcover report -byfile -details -output coverage/coverage_details.txt coverage/coverage.ucdb
```

The second command lists the coverage per file, merged over all instances, with every item that is not covered.
