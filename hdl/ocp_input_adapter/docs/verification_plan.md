# ocp_input_adapter: Verification Plan

## 1. Overview

The testbench `ocp_input_adapter_tb` sends SDUs of random samples to the adapter and checks every sample at its
output against a reference model in the source. The source builds every SDU from random sample values in big-endian
containers of ceil(D/8) bytes (the bits above D random as well, so that the adapter must ignore them), places byte k
of the SDU in lane k mod (`InWidth_g` / 8) of beat k / (`InWidth_g` / 8) and sets `In_Keep` for the valid bytes of the
last beat. The user signal is the one of the OpenSPP receive port (22 bits: the end mark is the CPTP User Application
value 1 in bits 21:14, bit 12 the Data Loss Indicator, bit 13 the receive buffer error) or, with `UserWidth_g` = 1,
the default masks (every SDU ends an image). On every beat but the last the user signal is random, also in the fault
bits, as the receive port only guarantees the error bit with `TLast`.

The reference model predicts for every forwarded sample its value (the D least significant bits of the container, the
missing bytes of an incomplete last container as zero), `Out_Last` and `Out_Error`, and it counts the faulty and the
discarded SDUs; it follows the discard state of the adapter. The sink compares every sample; at the end of every
sequence the event counts must equal the model. Input gaps and output stalls run in every second configuration.

Simulators: GHDL (regression, CI) and QuestaSim (code coverage); VUnit with UVVM, test end `ocpTestEnd`.

## 2. Configurations

| `InWidth_g` | `DynamicRange_g` | Converter | Back pressure |
| --- | --- | --- | --- |
| 128 | 8, 12, 16, 20, 32 | 128 to 8, 16, 24 (non-integer ratio) and 32 bits | 12, 20 |
| 64 | 16, 20 | 64 to 16 and 24 bits | 16 |
| 32 | 32, 20, 12 | none (one container per beat); 32 to 24 and 16 bits | 20 |
| 16 | 16, 12, 24 | none for D 16 and 12; 16 to 24 bits (upsizing) | 16, 24 |
| 8 | 8, 20, 32 | none for D 8; 8 to 24 and 32 bits (upsizing) | 8, 32 |
| 128, 16 (`UserWidth_g` 1) | 16 | 128 to 16 bits; none | 16 (width 16) |

Every value of `InWidth_g` and every container size (1 to 4 bytes) is simulated, each with and without converter where
both exist.

## 3. Test cases

| Test | Description | Requirements |
| --- | --- | --- |
| `test_samples` (TC-IA-01) | 60 SDUs of 1 to 40 samples with random end marks (one in four), no fault, then an SDU with the end mark; every sample, `Out_Last` on the last sample of every SDU with the end mark and nowhere else, `Out_Error` '0'; no event | IA-IF-01, IA-IF-02, IA-FN-01, IA-FN-02, IA-FN-03, IA-FN-04 |
| `test_faults` (TC-IA-02) | A directed sequence: a faulty SDU (bit 12) without end mark followed by an SDU, a faulty SDU (bit 13, discarded, its fault not counted) and an SDU with the end mark (all three discarded); a faulty SDU with the end mark (nothing discarded); an incomplete last container without end mark (the next single-sample SDU and a faulty SDU with the end mark discarded) and with end mark; SDUs of one sample and of one byte with and without end mark. Then 80 random SDUs with random faults (bit 12, bit 13, incomplete container) and end marks. Every sample, flag and event count against the model | IA-IF-02, IA-IF-03, IA-FN-03, IA-ER-01, IA-ER-02, IA-ER-03 |
| `test_reset` (TC-IA-03) | Six resets: after an SDU whose samples are still in the converter or stalled at the output, and in the discard state after a faulty SDU; each followed by random SDUs that must be correct (no discard after the reset) | IA-ER-04 |
| `test_rate` (TC-IA-04) | 20 SDUs of 11 to 30 samples without back pressure: the cycles from the first to the last sample are at most max(samples, bytes / (`InWidth_g` / 8)) + SDUs + 2 | IA-FN-05 |
| TC-IA-05 (`lint/synth_check.py`) | GHDL synthesis of the adapter for every configuration of section 2; `InWidth_g` = 24 and an end mark value outside its mask stop the elaboration with their message | IA-CF-01 |

## 4. Requirement coverage

| Requirement | Test cases |
| --- | --- |
| IA-IF-01, IA-IF-02 | TC-IA-01, TC-IA-02 (all configurations) |
| IA-IF-03 | TC-IA-02 |
| IA-FN-01, IA-FN-02, IA-FN-04 | TC-IA-01, TC-IA-02 |
| IA-FN-03 | TC-IA-01, TC-IA-02 (random user signal on every beat but the last) |
| IA-FN-05 | TC-IA-04 |
| IA-ER-01 to IA-ER-03 | TC-IA-02 |
| IA-ER-04 | TC-IA-03 |
| IA-CF-01 | TC-IA-05 |

## 5. Negative tests

Every error path is provoked from the source: the fault bits 12 and 13, an incomplete last container, a faulty SDU
while SDUs are discarded and faults on beats other than the last (which must not count). A check that is weakened
in the RTL (for example the length check or the discard state) makes the model and the DUT disagree on the samples or
on the event counts and fails the test.
