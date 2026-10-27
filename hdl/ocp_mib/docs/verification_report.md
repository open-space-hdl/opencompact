# ocp_mib: Verification Report

## 1. Test results

Run on 2026-10-27 with GHDL 6.0.0 (mcode, in the CI of the repository), VUnit 5.0.0.dev7, UVVM (commit 4f1e13b) with
the AXI-Lite VVC, Open Logic 4.7.0-ft.9: `python run.py "*ocp_mib*"`. The same tests pass in QuestaSim (Questa Pro
Microchip Edition 2024.3, time resolution 1 fs, 2026-10-26 and 2026-10-27), with code coverage and in the optimised
run without it; the code coverage is in [coverage.md](../../../docs/coverage.md).

| Test | Configurations | Passed |
| --- | --- | --- |
| `test_config` (TC-MB-01, TC-MB-06) | 62 (every configuration of `tools/ocp_configs.py`) | 62 |
| `test_counters` (TC-MB-02) | 1 | 1 |
| `test_reset` (TC-MB-03) | 1 | 1 |
| `test_runtime_config` (TC-MB-05, TC-MB-10) | 5 (rc01 to rc05) | 5 |
| `test_runtime_commit` (TC-MB-07, TC-MB-09) | 6 (rc01 to rc05, rp01 with the runtime parameters) | 6 |
| `test_runtime_params` (TC-MB-08) | 3 (rp01 to rp03) | 3 |
| `tools/regmap.py --check`, `tools/ocp_mib_words.py --check` (TC-MB-04) | | up to date |

## 2. Summary

For every configuration the registers ID to BLOCK read the words of `tools/ocp_mib_words.json`, which follow from the
generics with the field positions of `ocp_regs.yml`; the file is therefore verified by simulation. Unused addresses
read zero, writes to read-only registers and unused addresses change nothing, and every access is answered with OKAY.
Every event input increments its own counter, also back to back; a write clears one counter, and a pulse in the cycle
of the clearing write counts (the counter equals the pulses from the write cycle of the slave on). A reset clears the
counters. The saturation at 2^32 - 1 is not reached in simulation (verification plan, section 4).

With `RuntimeConfig_g` true (rc01 to rc05) NEXT_X to NEXT_LIMITS read back what is written; a valid COMMIT sets
CFG_PENDING, which `Cfg_Taken` clears; for every field 0, 1, the maximum and the maximum + 1 are written, and every
invalid value sets CFG_ERROR and leaves the configuration outputs unchanged; the error limit value of a method not in
use is not checked; the active registers read the `Act_` inputs; writes of CONTROL and STATUS with byte lane 0
disabled or with the bit '0', and writes to an unused address or to LIMITS, change nothing, and a write of a pending
register with byte lanes disabled changes only the enabled bytes (TC-MB-05). In every clock cycle around a COMMIT the
five configuration outputs carry either all previous or all new values, never a mix; a COMMIT one clock cycle before
`Cfg_Taken` gives the new values to the image that starts, a COMMIT in the cycle of `Cfg_Taken` or one cycle after it
leaves the previous values for that image and keeps CFG_PENDING set until the next `Cfg_Taken` (TC-MB-07). With the
generic false the registers of the runtime configuration read zero and ignore writes, and LIMITS reads the error limit
values of the generics (TC-MB-06). Three mutations of the runtime registers (pending flag, a delayed output field, the
range check) each make their test fail ([ocp_core verification report](../../ocp_core/docs/verification_report.md),
section 6).

With `RuntimeParams_g` true (rp01 to rp03, register map version 3, ID 0x4F435003, GENERICS.RUNTIME_PARAMS '1')
NEXT_SAMPLES to NEXT_BLOCK read the values of the generics after a reset and back what is written in the fields of the
options in use; every other bit reads zero, also after a write of all ones, and a write with one byte lane changes
that byte only. For every parameter in use its bounds commit, and one value beyond each sets CFG_ERROR and leaves
every configuration output unchanged; the dependent ranges are checked against the pending values (vmax below vmin,
gamma\* below max(4, gamma0 + 1), M above NZ of NEXT_Z), in rp02 gamma0 = 1 is rejected and gamma0 = 2 accepted (the
lower bound from its initial accumulators); an invalid dimension with valid parameters commits nothing. The parameter
fields of SAMPLES to BLOCK read the `Act_` inputs (TC-MB-08). Around every COMMIT of rp01 all configuration outputs,
the dimensions, the error limit values and the nine runtime parameters in use, change in the same clock cycle
(TC-MB-09). Without the runtime parameters NEXT_SAMPLES to NEXT_BLOCK read zero and ignore writes, a valid COMMIT
leaves the parameter outputs at zero, and SAMPLES to BLOCK read the words of the file with all ones on the `Act_`
inputs of the parameters (TC-MB-10).

Findings:

| Finding | Resolution |
| --- | --- |
| Register map version 3, first simulation: GENERICS.RUNTIME_PARAMS read '0' with `RuntimeParams_g` true (the field was added to the register map, not to the constant word of GENERICS) | The word of GENERICS takes the field; `test_runtime_params` compares GENERICS with the file |
| `test_runtime_commit` (TC-MB-07): the calibration COMMIT wrote the error limit values of the first checked COMMIT, so that COMMIT changed only NX, NY and NZ, and the atomicity check counted one clock cycle with a partial change | The calibration COMMIT writes other error limit values, so every checked COMMIT changes all five outputs; the check thereby showed that it detects a partial change |

## 3. Generic ranges

The generics of `ocp_mib` are those of the channel; their values come from the 62 configurations of
`tools/ocp_configs.py` (every enumeration value of order, coder, fidelity and local sum, D from 2 to 32, the bounds of
the weight and coder parameters of c38_header_bounds) with the stream widths 128 and the core width 64. The other stream
and core widths only change the constant GENERICS word (`ocp_channel` verification). `RuntimeConfig_g` is simulated
with both values: false in the 62 configurations, true in rc01 to rc05.
