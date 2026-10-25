# ocp_channel: Specification

## 1. Overview

`ocp_channel` is one OpenCompact compression channel for a system: it takes the samples of the images as a byte
stream of SDUs (`ocp_input_adapter`), compresses them with `ocp_core` (image framing by the end mark of the SDUs), and
outputs every compressed image as one packet of a byte stream of up to 128 bits. An AXI4-Lite slave (`ocp_mib`)
reports the configuration and counts the images, the faulty and discarded SDUs and the memory errors.

## 2. Requirements

### 2.1 Interfaces

| ID | Requirement | CCSDS |
| --- | --- | --- |
| CH-IF-01 | The channel shall take SDUs as specified for `ocp_input_adapter` (IA-IF-01, IA-FN-01, section 2.4 of its specification). | 5.4.2 |
| CH-IF-02 | The channel shall output every compressed image as one packet of a valid / ready byte stream of `OutStreamWidth_g` bits (8, 16, 32, 64 or 128): byte n of a beat in bits 8n + 7 to 8n, the first byte of the compressed image in byte 0 of the first beat, all bytes valid (`Out_Keep`) except in the last beat, whose valid bytes are contiguous from byte 0, `Out_Last` on the last beat. | 5.2.1 |
| CH-IF-03 | The channel shall set `Out_Error` with `Out_Last` of a compressed image with an error and keep it '0' otherwise. | none |
| CH-IF-04 | The channel shall provide the status registers and, with `RuntimeConfig_g`, the configuration registers of `ocp_mib` on an AXI4-Lite slave. | none |
| CH-IF-05 | The channel shall provide the error limit stream (`Lim_*`), the memory error pulses (`Ecc_Sec`, `Ecc_Ded`), the framing error pulse (`Ev_ImageError`) and the error injection inputs (`ErrInj_*`) of `ocp_core`. | 4.8.2.4 |

### 2.2 Function

| ID | Requirement | CCSDS |
| --- | --- | --- |
| CH-FN-01 | The channel shall compress the samples of the SDUs with `ocp_core` (`UseInLast_g` true, `In_Last` and `In_Error` from the input adapter) and output the bytes of every compressed image of the core unchanged and in order. | 5.2.1 |
| CH-FN-02 | A compressed image with an error shall leave the channel as a packet like any other. Its bytes shall be those of the core: after an abort (CO-FR-03) the compressed image of the samples taken (with the header of the complete image); after an image end with `In_Error` on its last sample (CO-FR-08) or a missing end mark (CO-FR-04) the complete compressed image of its NX NY NZ samples. | 5.2.2 |
| CH-FN-03 | The counters of `ocp_mib` shall count: IMAGES_DONE and IMAGES_ABORTED the last words of compressed images without and with an error at the output of the core, SDU_ERRORS the faulty SDUs and SDUS_DISCARDED the discarded SDUs of the input adapter, ECC_CORRECTED and ECC_UNCORRECTABLE the memory error pulses of the core. | none |
| CH-TP-01 | With `OutStreamWidth_g` at least `OutWidth_g`, the output adapter shall take a word from the core in every clock cycle except one cycle per compressed image, so that the throughput of the channel is the throughput of the core (user guide, section 8) up to one clock cycle per SDU and per image. | none |
| CH-RS-01 | A reset shall abort the image in progress (CO-RS-01), clear the adapters and clear the counters. | none |
| CH-RC-01 | With `RuntimeConfig_g` true the channel shall compress every image with the configuration that software committed in `ocp_mib` before the first SDU of the image arrived at the core (MB-RC-02, CO-RC-03), and the active configuration registers shall show the configuration of the last image that started. | 5.3.2.2, 5.3.3.4 |

### 2.3 Configuration checks

| ID | Requirement | CCSDS |
| --- | --- | --- |
| CH-CF-01 | The elaboration shall stop when `InStreamWidth_g` or `OutStreamWidth_g` is not 8, 16, 32, 64 or 128, in addition to the checks of `ocp_core` (CO-CF) and `ocp_input_adapter` (IA-CF). | none |

## 3. Error scenarios

The table defines the counter steps of the error cases. Example system: SDUs from the Octet String receive port of an
OpenSPP core with `UserErrorMask_g` = bits 12 (Data Loss Indicator) and 13 (receive buffer error), the end mark the
User Application value 0x01 (bits 21:14). Image k has the SDUs 1 to n, the SDU n with the end mark.

| Case | Output | IMAGES_DONE | IMAGES_ABORTED | SDU_ERRORS | SDUS_DISCARDED |
| --- | --- | --- | --- | --- | --- |
| Image k without fault | Compressed image k | +1 | | | |
| SDU j < n faulty (receive buffer error or length) | Image k aborted after the samples of SDUs 1 to j; SDUs j + 1 to n discarded | | +1 | +1 | +(n - j) |
| SDU n faulty | Image k complete, `Out_Error` | | +1 | +1 | |
| (a) SDU j < n lost; SDU j + 1 carries the Data Loss Indicator | Image k aborted after the samples of SDUs 1 to j - 1 and j + 1; SDUs j + 2 to n discarded (none when j + 1 = n) | | +1 | +1 | +(n - j - 1) |
| (b) SDU n lost; SDU 1 of image k + 1 carries the Data Loss Indicator | Image k ends with an error after the samples of SDUs 1 to n - 1 and of SDU 1 of image k + 1 (aborted, complete with `Out_Error`, or completed and the rest of that SDU discarded, depending on its length); SDUs 2 to m of image k + 1 discarded; no output of image k + 1 | | +1 | +1 | +(m - 1) |
| SDU j < n faulty and SDU n lost | Image k aborted after the samples of SDUs 1 to j; SDUs j + 1 to n - 1 and the m SDUs of image k + 1 discarded, up to and including the end mark of image k + 1; no output of image k + 1 | | +1 | +1 | +(n - 1 - j + m) |
| End mark on SDU j < n, no fault | Image k aborted after SDU j (CO-FR-03); SDUs j + 1 to n form the next image, aborted at its end mark | | +2 | | |
| End mark missing on SDU n, no fault | Image k complete with `Out_Error` (CO-FR-04); the samples up to the next end mark (all of image k + 1) are discarded by the core | | +1 | | |

The discard after a faulty SDU always ends with the next SDU with the end mark that arrives, whichever image it
belongs to; the faults of discarded SDUs are not evaluated. In every case the image after the last affected one is
compressed normally. IMAGES_DONE + IMAGES_ABORTED is the number of compressed images output.

## 4. Configuration parameters

All generics of `ocp_core` with their names, meanings, defaults and ranges, among them `RuntimeConfig_g`, except
`UseInLast_g` (always true inside the channel); `OutWidth_g` is the width of the words of the core, as in `ocp_core`. In
addition:

| Generic | Default | Range | Description |
| --- | --- | --- | --- |
| `InStreamWidth_g` | 128 | 8, 16, 32, 64, 128 | Width of the SDU stream in bits (`InWidth_g` of `ocp_input_adapter`) |
| `OutStreamWidth_g` | 128 | 8, 16, 32, 64, 128 | Width of the compressed image stream in bits |
| `UserWidth_g` | 1 | 1 to 64 | Width of the user signal of the SDU stream |
| `UserLastMask_g`, `UserLastValue_g`, `UserErrorMask_g` | (others => '0') | `UserWidth_g` bits | End mark and faults (`ocp_input_adapter`); with the defaults every SDU ends an image and no bit flags a fault |

The example system of section 3 sets `UserWidth_g` = 22, `UserLastMask_g` = 22x"3FC000", `UserLastValue_g` =
22x"004000" and `UserErrorMask_g` = 22x"003000".

## 5. Integration constraints

| Constraint | Reason |
| --- | --- |
| The SDUs carry only samples: no secondary header, no padding | Every byte is sample data (IA-FN-01); a source flag for a secondary header can be added to `UserErrorMask_g` |
| A receiver that must identify the images with an error per image uses `Out_Error`, or compares the counters | An image ended by a faulty last SDU is complete and indistinguishable from a good image by its bytes (CH-FN-02) |
| The source starts after the reset of the channel with the first SDU of an image | An image in progress at the end of the reset is aborted at its end mark (+1 IMAGES_ABORTED) |
