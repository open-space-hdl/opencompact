# ocp_channel: Verification Plan

## 1. Overview

The testbench `ocp_channel_tb` is the integration test of the input adapter, the core, the output adapter and the
status interface (phase G). The source cuts the test image of a configuration (`tb/golden/<configuration>/image.raw`)
into SDUs of random length (1 to 40 samples, one in ten of a single sample) in big-endian containers of ceil(D/8)
bytes, with the user signal of the OpenSPP receive port: the CPTP User Application value 1 marks the last SDU of an
image, bit 12 is the Data Loss Indicator, bit 13 the receive buffer error; on every beat but the last the user signal
is random. The sink compares every packet of the output stream with the image compressed by the CNES reference
software (`compressed.bin`), byte by byte, with the valid bytes of every beat and `Out_Error` on the last beat. The
counters are read through the AXI4-Lite slave with the AXI-Lite VVC of UVVM and compared with a model of the input
adapter and of the expected packets in the source.

Expected packets: a reference image (`Out_Error` '0' or '1'); an aborted image (its header, a prefix of the reference
cut at a codeword, zero fill bits up to a multiple of B, `Out_Error`); an image of other samples than the reference
after a lost SDU or an incomplete container (its header, a multiple of B bytes, `Out_Error`); no packet for an image
that the adapter discards or the core swallows after a missing end mark.

Simulators: GHDL (regression, CI) and QuestaSim (code coverage); VUnit with UVVM, test end `ocpTestEnd`.

## 2. Configurations

| Configuration | D, coder | `InStreamWidth_g` | `OutWidth_g` | `OutStreamWidth_g` | Back pressure |
| --- | --- | --- | --- | --- | --- |
| r08_random | 8, sample-adaptive, BSQ | 8 (no converter) | 8 | 128 | no |
| c36_block_j64_spikes | 12, block-adaptive, BSQ | 128 (to 16 bits) | 64 | 128 | no |
| r09_random | 16, sample-adaptive, BI | 16 (no converter) | 32 | 32 (no converter) | yes |
| r17_random | 20, hybrid, BI | 64 (to 24 bits) | 16 | 64 | no |
| c37_block_d32_custom | 32, block-adaptive, BSQ | 32 (no converter) | 64 | 64 (no converter) | yes |
| c33_small_bip_stride_block | 16, block-adaptive, stride order | 128 (to 16 bits) | 8 | 16 | yes |
| c32_small_bip_periodic_rel | 14, hybrid, periodic error limits | 32 (to 16 bits) | 16 | 128 | yes |
| r24_random | 18, sample-adaptive, BI | 128 (to 24 bits) | 32 | 8 (from 32 bits) | yes |

## 3. Test cases

| Test | Description | Requirements |
| --- | --- | --- |
| `test_golden` (TC-CH-01) | Three images one after the other; the ID register reads 0x4F435002; every packet equals the reference with `Out_Error` '0', all bytes valid except in the last beat; IMAGES_DONE = 3, the other counters zero, no `Ev_ImageError`. c32 feeds the error limit values through `Lim_*` | CH-IF-01, CH-IF-02, CH-IF-03, CH-IF-04, CH-IF-05, CH-FN-01, CH-FN-03 |
| `test_errors` (TC-CH-02) | 17 images (all configurations without periodic updating): correct; faulty SDU inside (aborted, rest discarded); correct; faulty last SDU (reference with `Out_Error`); lost SDU inside with the Data Loss Indicator on the next SDU; correct; lost last SDU with the Data Loss Indicator on the first SDU of the next image (no packet of that image); incomplete last container inside; early end mark (aborted image and a second aborted image of the rest); correct; missing end mark (reference with `Out_Error`, the next image swallowed by the core); faulty SDU inside with the last SDU lost (the discard runs through the next image); correct. Every packet, every error flag, IMAGES_DONE, IMAGES_ABORTED, SDU_ERRORS and SDUS_DISCARDED against the model, one `Ev_ImageError` per image with an error; every correct image after an error equals the reference | CH-FN-02, CH-FN-03, CH-IF-03, IA-ER-01, IA-ER-02, CO-FR-03, CO-FR-04, CO-FR-08 |
| `test_ecc` (TC-CH-03) | A single bit error injected through `ErrInj_*` into two memories of the core: ECC_CORRECTED counts, ECC_UNCORRECTABLE stays zero, the image equals the reference; a double bit error: ECC_UNCORRECTABLE counts | CH-IF-05, CH-FN-03 |
| `test_reset` (TC-CH-04) | A reset in the middle of an image clears the counters; the next image equals the reference and is counted | CH-RS-01 |
| TC-CH-05 (`lint/synth_check.py`) | GHDL synthesis of the channel with every configuration of section 2; `OutStreamWidth_g` = 24 stops the elaboration with its message | CH-CF-01 |
| TC-CH-06 (every test) | With `OutStreamWidth_g` at least `OutWidth_g`, the throughput of the core is kept: the channel takes part in the image period checks of `ocp_core` through the same core; the output adapter takes a word in every cycle while the sink is ready (no output stall in the configurations without back pressure, checked by the packet timing of the sink) | CH-TP-01 |
| `test_runtime` rc04 (TC-CH-07) | `RuntimeConfig_g` true through the AXI4-Lite VVC: configuration A committed, its image sent as SDUs; configuration B committed while the image of A is compressed, applies to the next image; an invalid configuration C is rejected (CFG_ERROR), the next image uses B; every packet equals `ocp_model` for its configuration; after every image the active registers show its configuration, CFG_PENDING is set after the image of A (B waits) and clear after the others | CH-RC-01, CH-IF-04 |
| TC-CH-08 (`test_runtime` of `ocp_channel_tb`, rp01) | `RuntimeParams_g` true: the sequence of TC-CH-07 with configurations that also differ in the runtime parameters (user-defined data, M, the weight update and the coder parameters), committed through the AXI4-Lite VVC; every packet equals `ocp_model` for the dimensions, limits and parameters of its image, and after every image the parameter fields of SAMPLES to ADAPTIVE show those of the image | CH-RP-01 |

## 4. Requirement coverage

| Requirement | Test cases |
| --- | --- |
| CH-IF-01 to CH-IF-04 | TC-CH-01, TC-CH-02 |
| CH-IF-05 | TC-CH-01 (error limits), TC-CH-03 (error injection, memory errors), TC-CH-02 (`Ev_ImageError`) |
| CH-FN-01 | TC-CH-01, TC-CH-02 |
| CH-FN-02 | TC-CH-02 |
| CH-FN-03 | TC-CH-01, TC-CH-02, TC-CH-03 |
| CH-TP-01 | TC-CH-06 |
| CH-RS-01 | TC-CH-04 |
| CH-CF-01 | TC-CH-05 |
| CH-RC-01 | TC-CH-07 |
| CH-RP-01 | TC-CH-08 |
