# ocp_mib: Verification Report

## 1. Test results

Run on 2026-10-18 with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit 4f1e13b) with the AXI-Lite VVC, Open Logic
4.7.0-ft.6: `python run.py "*ocp_mib*"`. The same tests pass in QuestaSim (Questa Pro Microchip Edition 2024.3, time
resolution 1 fs, 2026-10-19), with code coverage and in the optimised run without it; the code coverage is in
[coverage.md](../../../docs/coverage.md).

| Test | Configurations | Passed |
| --- | --- | --- |
| `test_config` (TC-MB-01) | 62 (every configuration of `tools/ocp_configs.py`) | 62 |
| `test_counters` (TC-MB-02) | 1 | 1 |
| `test_reset` (TC-MB-03) | 1 | 1 |
| `tools/regmap.py --check`, `tools/ocp_mib_words.py --check` (TC-MB-04) | | up to date |

## 2. Summary

For every configuration the registers ID to BLOCK read the words of `tools/ocp_mib_words.json`, which follow from the
generics with the field positions of `ocp_regs.yml`; the file is therefore verified by simulation. Unused addresses
read zero, writes to read-only registers and unused addresses change nothing, and every access is answered with OKAY.
Every event input increments its own counter, also back to back; a write clears one counter, and a pulse in the cycle
of the clearing write counts (the counter equals the pulses from the write cycle of the slave on). A reset clears the
counters. The saturation at 2^32 - 1 is not reached in simulation (verification plan, section 4).

Findings:

| Finding | Resolution |
| --- | --- |
| `test_runtime_commit` (TC-MB-07): the calibration COMMIT wrote the error limit values of the first checked COMMIT, so that COMMIT changed only NX, NY and NZ, and the atomicity check counted one clock cycle with a partial change | The calibration COMMIT writes other error limit values, so every checked COMMIT changes all five outputs; the check thereby showed that it detects a partial change |

## 3. Generic ranges

The generics of `ocp_mib` are those of the channel; their values come from the 62 configurations of
`tools/ocp_configs.py` (every enumeration value of order, coder, fidelity and local sum, D from 2 to 32, the bounds of
the weight and coder parameters of c38_header_bounds) with the stream widths 128 and the core width 64. The other stream
and core widths only change the constant GENERICS word (`ocp_channel` verification).
