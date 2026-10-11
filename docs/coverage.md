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

Run on 2026-10-10: 55 tests (24 configurations in `ocp_predictor_tb` and in `ocp_core_tb`, 7 runs with back
pressure), all passed in QuestaSim as in GHDL.

| File | Statements | Branches | Conditions | Expressions | FSM states | FSM transitions |
| --- | --- | --- | --- | --- | --- | --- |
| `ocp_pkg.vhd` | 26 / 38 (68.4 %) | 24 / 30 (80.0 %) | | | | |
| `ocp_predictor.vhd` | 376 / 377 (99.7 %) | 225 / 227 (99.1 %) | 33 / 40 (82.5 %) | 10 / 10 | 17 / 17 | 23 / 37 (62.2 %) |
| `ocp_sample_adaptive_coder.vhd` | 72 / 73 (98.6 %) | 33 / 34 (97.1 %) | 4 / 4 | | 5 / 5 | 5 / 8 (62.5 %) |
| `ocp_hybrid_coder.vhd` | 148 / 149 (99.3 %) | 66 / 68 (97.1 %) | 2 / 2 | 2 / 2 | 13 / 13 | 17 / 27 (63.0 %) |
| `ocp_block_adaptive_coder.vhd` | 153 / 155 (98.7 %) | 97 / 102 (95.1 %) | 13 / 13 | 5 / 5 | 11 / 11 | 18 / 41 (43.9 %) |
| `ocp_header.vhd` | 151 / 157 (96.2 %) | 59 / 60 (98.3 %) | 2 / 2 | | | |
| `ocp_bit_packer.vhd` | 37 / 37 | 21 / 21 | 7 / 8 (87.5 %) | | | |
| `ocp_core.vhd` | 19 / 19 | 21 / 21 | 6 / 6 | 2 / 7 (28.6 %) | | |
| Total | 982 / 1005 (97.7 %) | 546 / 563 (97.0 %) | 67 / 75 (89.3 %) | 19 / 24 (79.2 %) | 46 / 46 | 63 / 113 (55.8 %) |

Every state of every state machine is reached.

## 3. Remaining statements and branches

| File | Items | Reason |
| --- | --- | --- |
| `ocp_pkg.vhd` | The `failure` reports of the decoding of invalid string generics; `bandsUsed`, `bandTableSize` | Run during elaboration only (QuestaSim does not count elaboration); an invalid generic stops the elaboration |
| `ocp_header.vhd` | The procedure `put` | Runs during elaboration only: the header is a constant |
| `ocp_predictor.vhd`, `ocp_sample_adaptive_coder.vhd`, `ocp_hybrid_coder.vhd`, `ocp_block_adaptive_coder.vhd` | `when others` of the state machine | Recovery from an illegal state; needs fault injection into the state registers |
| `ocp_block_adaptive_coder.vhd` | Saturation of a second extension symbol above 8191 | Requires a pair of values with a sum of 127; such a symbol never gives the shortest option |

## 4. Status

Coverage is not closed; closure is a step to TRL 3 ([roadmap](roadmap.md)). Open groups besides the items of
section 3:

| Group | Next step |
| --- | --- |
| State machine transitions: transitions to the reset state from every state | Reset tests in every state |
| Conditions and expressions: back pressure of the bit packer at the end of an image, start of the header while the previous image ends, the error flags of the memories | Unit testbenches of the bit packer and of the image sequencer; error injection into the memories |
