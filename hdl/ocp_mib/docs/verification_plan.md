# ocp_mib: Verification Plan

## 1. Overview

The testbench `ocp_mib_tb` accesses the registers through the AXI-Lite VVC of UVVM and drives the event inputs
directly. The expected values of the registers ID to BLOCK come from `tools/ocp_mib_words.json`, which
`tools/ocp_mib_words.py` writes from the field definitions of `ocp_regs.yml` and the generics of every configuration of
`tools/ocp_configs.py` with the widths of a channel. The testbench compares the registers with that file, so the file
is verified by simulation; a system that computes the words itself compares with the same file.

Simulators: GHDL (regression, CI) and QuestaSim (code coverage); VUnit with UVVM, test end `ocpTestEnd`.

## 2. Test cases

| Test | Description | Requirements |
| --- | --- | --- |
| `test_config` (TC-MB-01) | For each of the 62 configurations: ID to BLOCK equal the words of `tools/ocp_mib_words.json` (the ID also equals `RegMapId_c` of `ocp_regs_pkg`); every unused address reads zero; writes of the inverted values to ID to BLOCK and of ones to unused addresses change nothing and leave the counters at zero; the VVC requires the response OKAY for every access | MB-IF-01, MB-ID-01, MB-GN-01 |
| `test_counters` (TC-MB-02) | Pulses on every event input, with gaps and back to back, increment their own counter only; a write clears one counter and no other; back-to-back pulses during one clearing write: the counter equals the pulses from the cycle in which the slave writes (the cycle in which `BValid` rises) on, so the pulse of that cycle counts | MB-IF-02, MB-CN-01, MB-CN-02 |
| `test_reset` (TC-MB-03) | A reset clears every counter | MB-RS-01 |
| TC-MB-04 (`python tools/regmap.py --check`, `python tools/ocp_mib_words.py --check`, CI) | The VHDL package, the register map and the C header, and the expected words, match their sources | MB-RG-01 |
| `test_runtime_config` (TC-MB-05) | `RuntimeConfig_g` true: NEXT_X to NEXT_LIMITS read their reset values and back what is written; a valid COMMIT sets CFG_PENDING, which `Cfg_Taken` clears; the active registers read the `Act_` inputs (SUB_FRAME_DEPTH = min(`SubFrameDepth_g`, IMAGE_Z)); for every field the values 0, 1, maximum and maximum + 1 (limits 2^DA - 1 and 2^DA) and NX = 1 with full prediction: an invalid value sets CFG_ERROR and leaves the outputs unchanged, a write of '1' clears CFG_ERROR; NX = NY = NZ = 1 where width 1 is allowed; the error limit value of a method not in use (2^16 - 1) is not checked and the COMMIT is valid; writes of CONTROL with byte lane 0 disabled or with COMMIT = '0' commit nothing, writes of STATUS with byte lane 0 disabled or with CFG_ERROR = '0' leave CFG_ERROR set; GENERICS.RUNTIME_CONFIG reads '1' | MB-RC-01, MB-RC-02, MB-RC-03, MB-RC-04 |
| `test_config` with `RuntimeConfig_g` false (TC-MB-06) | NEXT_X to NEXT_LIMITS, CONTROL and STATUS read zero and writes to them change nothing (configuration outputs, active registers); LIMITS reads the error limit values of the generics | MB-RC-05 |
| `test_runtime_commit` (TC-MB-07) | `RuntimeConfig_g` true, the bench in place of the core: the five configuration outputs are compared with the previous and the committed values in every clock cycle around valid COMMITs that change every field (all previous values, then all new values from one clock cycle on, never a mix); valid COMMITs whose write lands one clock cycle before, in and one clock cycle after a `Cfg_Taken` pulse: in the cycle of `Cfg_Taken` the outputs still carry the previous values, after the COMMIT in that cycle CFG_PENDING stays '1' and the next `Cfg_Taken` clears it | MB-RC-02, MB-RC-03 |

## 3. Requirement coverage

| Requirement | Test cases |
| --- | --- |
| MB-IF-01 | TC-MB-01 |
| MB-IF-02 | TC-MB-02 |
| MB-ID-01, MB-GN-01 | TC-MB-01 |
| MB-CN-01, MB-CN-02 | TC-MB-02; saturation at 2^32 - 1 by inspection (section 4) |
| MB-RS-01 | TC-MB-03 |
| MB-RG-01 | TC-MB-04 |
| MB-RC-01 | TC-MB-05 |
| MB-RC-02, MB-RC-03 | TC-MB-05, TC-MB-07 |
| MB-RC-04 | TC-MB-05 |
| MB-RC-05 | TC-MB-06 |

## 4. Not simulated

The saturation of a counter needs 2^32 - 1 events, which no simulation reaches. The function is a comparison with all
ones, the same for all six counters; the code coverage report justifies the uncovered branch.
