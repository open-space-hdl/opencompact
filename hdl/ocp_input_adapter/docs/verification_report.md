# ocp_input_adapter: Verification Report

## 1. Test results

Run on 2026-10-27 with GHDL 6.0.0 (mcode, in the CI of the repository), VUnit 5.0.0.dev7, UVVM (commit 4f1e13b), Open
Logic 4.7.0-ft.9: `python run.py "*ocp_input_adapter*"`. The same tests pass in QuestaSim (Questa Pro Microchip
Edition 2024.3, time resolution 1 fs, 2026-10-26 and 2026-10-27), with code coverage and in the optimised run without
it; the code coverage is in [coverage.md](../../../docs/coverage.md).

| Test | Configurations | Passed |
| --- | --- | --- |
| `test_samples` (TC-IA-01) | 18 | 18 |
| `test_faults` (TC-IA-02) | 18 | 18 |
| `test_reset` (TC-IA-03) | 18 | 18 |
| `test_rate` (TC-IA-04) | 18 | 18 |
| `lint/synth_check.py` (TC-IA-05) | 18 configurations synthesize, `InWidth_g` = 24 and an end mark value outside its mask stop the elaboration | 20 |

## 2. Summary

Every sample of every SDU arrives at the output with its value, its image end marker and its error flag as the
reference model predicts, at every width of the SDU stream (8 to 128 bits), with containers of 1 to 4 bytes, through
the width converter at integer and non-integer ratios and without it, with input gaps and output stalls. The user
signal counts only with the last beat. Every fault (bit 12, bit 13, incomplete last container) ends the image with an
error; the SDUs after a faulty SDU without end mark are discarded up to and including the next end mark, also faulty
and single-sample SDUs; the event counts equal the model. After a reset in the middle of an SDU in the converter or
during a discard, the next SDUs are forwarded. Without back pressure the samples leave at the byte rate of the source
with at most one idle cycle between two SDUs.

## 3. Generic ranges

| Generic | Declared range | Simulated | Synthesized |
| --- | --- | --- | --- |
| `InWidth_g` | 8, 16, 32, 64, 128 | all | all; 24 stops the elaboration |
| `DynamicRange_g` | 2 to 32 | 8, 12, 16, 20, 24, 32 (containers of 1 to 4 bytes) | the same |
| `UserWidth_g` | 1 to 64 | 1, 22 | 1, 22 |
| `UserLastMask_g`, `UserLastValue_g`, `UserErrorMask_g` | `UserWidth_g` bits | defaults, OpenSPP layout | the same; a value outside its mask stops the elaboration |

D below 8 uses the same container of one byte as D = 8 (the D least significant bits); `UserWidth_g` from 23 to 64
changes only the width of the user register and of the mask comparisons.

## 4. Findings

| Finding | Correction |
| --- | --- |
| The width converter checks the byte enables of every valid beat in simulation. Its valid came from the process of the SDU control, one delta cycle after the source changed `In_Last` and `In_Keep`; when the source dropped `In_Valid` and `In_Last` after the last beat of an SDU, the converter saw the old valid with the new `In_Last` and the old partial `In_Keep` and stopped the simulation | All inputs of the converter come from the same process, so they change in the same delta cycle |
| The rate bound of `test_rate` assumed whole beats over all bytes; an SDU whose last beat is partial costs a full beat | The bound sums the beats of every SDU |
