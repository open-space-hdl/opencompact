# OpenCompact: Code Coverage

## 1. Method

The code coverage of the OpenCompact sources is measured with QuestaSim (Questa Pro Microchip Edition 2024.3) over the
complete regression of `run.py`, the same test set that GHDL runs:

```shell
python run.py --questa --coverage -p 1
```

The sources of `hdl/<module>/src` are compiled with `+cover=sbcef`: statements, branches, conditions, expressions
(focused expression coverage) and state machines. Open Logic, UVVM and the testbenches are not instrumented. `run.py`
merges the coverage of all tests into `coverage/coverage.ucdb` and writes the reports
`coverage/coverage_report.txt` and `coverage/coverage_byfile.txt`.

## 2. Results

Run on 2026-10-11: 67 tests (30 configurations in `ocp_predictor_tb` and in `ocp_core_tb`, 7 runs with back
pressure), all passed in QuestaSim as in GHDL.

| File | Statements | Branches | Conditions | Expressions | FSM states | FSM transitions |
| --- | --- | --- | --- | --- | --- | --- |
| `ocp_pkg.vhd` | 26 / 38 (68.4 %) | 24 / 30 (80.0 %) | | | | |
| `ocp_predictor.vhd` | 654 / 655 (99.8 %) | 317 / 320 (99.1 %) | 72 / 95 (75.8 %) | 46 / 53 (86.8 %) | | |
| `ocp_sample_adaptive_coder.vhd` | 95 / 95 | 30 / 30 | 9 / 9 | 3 / 3 | | |
| `ocp_hybrid_coder.vhd` | 197 / 198 (99.5 %) | 59 / 61 (96.7 %) | 19 / 22 (86.4 %) | 3 / 3 | 3 / 3 | 3 / 4 (75.0 %) |
| `ocp_block_adaptive_coder.vhd` | 208 / 209 (99.5 %) | 93 / 95 (97.9 %) | 16 / 20 (80.0 %) | 4 / 5 (80.0 %) | | |
| `ocp_cw_buffer.vhd` | 30 / 30 | 13 / 13 | 9 / 9 | | | |
| `ocp_header.vhd` | 161 / 167 (96.4 %) | 60 / 60 | 2 / 2 | | | |
| `ocp_bit_packer.vhd` | 92 / 94 (97.9 %) | 27 / 29 (93.1 %) | 2 / 2 | | | |
| `ocp_core.vhd` | 20 / 20 | 24 / 24 | 8 / 10 (80.0 %) | 2 / 6 (33.3 %) | | |
| Total | 1483 / 1506 (98.5 %) | 647 / 662 (97.7 %) | 137 / 169 (81.1 %) | 58 / 70 (82.9 %) | 3 / 3 | 3 / 4 (75.0 %) |

The predictor and the sample-adaptive and block-adaptive coders are pipelines without state machines; the tail of
the hybrid coder is the only state machine, and all its states are reached.

## 3. Remaining statements and branches

| File | Items | Reason |
| --- | --- | --- |
| `ocp_pkg.vhd` | The `failure` reports of the decoding of invalid string generics; `bandsUsed`, `bandTableStart` | Run during elaboration only (QuestaSim does not count elaboration); an invalid generic stops the elaboration |
| `ocp_header.vhd` | The procedure `put` | Runs during elaboration only: the header is a constant |
| `ocp_predictor.vhd` | Stride order: dependency check against the previous band | Unreachable by construction: the stride S is at least the distance L_cross, and the samples are started in slot order, so the sample of the previous band at the same column started at least S cycles earlier; the check is kept as a safeguard |
| `ocp_predictor.vhd` | Initial weights with Q = Omega + 3 (no fill bits) | Elaboration-time function; no configuration uses Q = Omega + 3 |
| `ocp_predictor.vhd` | Output FIFO full when the error limit values of a period are due | Needs output back pressure exactly at the start of an update period |
| `ocp_hybrid_coder.vhd` | `when others` of the tail state machine | Recovery from an illegal state; needs fault injection into the state register |
| `ocp_hybrid_coder.vhd` | Codeword buffer full during the flush words of the tail | Needs output back pressure exactly at the end of an image |
| `ocp_block_adaptive_coder.vhd` | Saturation of a second extension symbol above 8191 | Requires a pair of values with a sum of 127; such a symbol never gives the shortest option |
| `ocp_block_adaptive_coder.vhd` | Fewer than four sets of split bits per codeword | Needs a split-sample option with k >= 25, which only a block-adaptive configuration with D > 24 selects |
| `ocp_bit_packer.vhd` | Queue of two image ends | Needs an image that is completely written into the packer while the last word of the previous image waits at the output: small images with output back pressure |

## 4. Status

Coverage is not closed; closure is a step to TRL 3 ([roadmap](roadmap.md)). Open groups besides the items of
section 3:

| Group | Next step |
| --- | --- |
| State machine transitions: transitions to the reset state | Reset tests during the tail of the hybrid coder |
| Conditions and expressions: back pressure at the end of an image and at the start of an update period, small images with output back pressure, the error flags of the memories | Unit testbenches of the bit packer and of the entropy coders; configurations with back pressure for small images; error injection into the memories |
