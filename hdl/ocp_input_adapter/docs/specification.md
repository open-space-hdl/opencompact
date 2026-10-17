# ocp_input_adapter: Specification

## 1. Overview

`ocp_input_adapter` connects a byte stream of service data units (SDUs) to the sample input of `ocp_core`. Every SDU
carries a whole number of samples, each in a big-endian container of ceil(D/8) bytes. The adapter marks the last
sample of an image from a field of the user signal of the stream (the end mark), ends the image with an error when an
SDU is flagged as faulty by its user signal or does not hold a whole number of samples, and discards the rest of such
an image. The layout of the user signal is set by generics; the adapter assumes no particular protocol.

A typical source is the receive port of a Space Packet Protocol core of the Octet String Service: one Space Packet
per SDU, the end of an image marked by a value of the User Application field of the CPTP packet, faults flagged by the
Data Loss Indicator and the error bit of the receive buffer (section 2.4).

## 2. Requirements

### 2.1 Interfaces

| ID | Requirement | CCSDS |
| --- | --- | --- |
| IA-IF-01 | The adapter shall take SDUs on a valid / ready byte stream of `InWidth_g` bits (8, 16, 32, 64 or 128) with a byte enable per byte (`In_Keep`), a marker on the last beat of every SDU (`In_Last`) and a user signal of `UserWidth_g` bits (`In_User`); byte n of a beat occupies bits 8n + 7 to 8n, the first byte of an SDU is byte 0 of its first beat. | none |
| IA-IF-02 | The adapter shall output the samples on a valid / ready stream of `DynamicRange_g` bits with an image end marker (`Out_Last`) and an error flag (`Out_Error`, valid with `Out_Last`), the input of `ocp_core` with `UseInLast_g` true (`In_Last`, `In_Error`). | 5.4.2 |
| IA-IF-03 | The adapter shall pulse `Ev_SduError` for one clock cycle for every faulty SDU it forwards (IA-ER-01) and `Ev_SduDiscarded` for every SDU it discards (IA-ER-02). | none |

### 2.2 Function

| ID | Requirement | CCSDS |
| --- | --- | --- |
| IA-FN-01 | The adapter shall read the samples of an SDU from consecutive containers of ceil(D/8) bytes, the first byte of a container being its most significant byte, and output the D least significant bits of every container; the other bits of a container shall be ignored. | none |
| IA-FN-02 | The adapter shall output the samples in the order of the SDUs and of the bytes within them, without loss or reordering, so that the stream order is the input order of the compressor. | 5.4.2 |
| IA-FN-03 | The adapter shall evaluate the user signal of an SDU with its last beat; the user signal of the other beats shall be ignored. | none |
| IA-FN-04 | The adapter shall set `Out_Last` with the last sample of every SDU whose user signal carries the end mark: (`In_User` and `UserLastMask_g`) = `UserLastValue_g`. | none |
| IA-FN-05 | The adapter shall output the samples at the byte rate of the source, up to one sample per clock cycle, with at most one clock cycle without a sample between two forwarded SDUs. | none |

### 2.3 Error handling

| ID | Requirement | CCSDS |
| --- | --- | --- |
| IA-ER-01 | An SDU shall be faulty when its user signal has a bit set in `UserErrorMask_g` (`In_User` and `UserErrorMask_g` /= 0) or when its length is not a multiple of ceil(D/8) bytes. The adapter shall output the samples of a faulty SDU, an incomplete last container completed with zero bytes, and set `Out_Last` and `Out_Error` with its last sample. | none |
| IA-ER-02 | After a faulty SDU without the end mark the adapter shall discard the following SDUs up to and including the next SDU with the end mark; the SDU after it shall start a new image. After a faulty SDU with the end mark the adapter shall discard nothing. | none |
| IA-ER-03 | A discarded SDU shall produce no sample; only its end mark shall be evaluated. | none |
| IA-ER-04 | After a reset the adapter shall hold no part of an SDU and shall not discard; the next SDU shall start a new image. | none |

### 2.4 Partner behaviour

The adapter is specified against the receive port (`M_Rx_*`) of the OpenSPP core (`spp_core`, Octet String Service,
CPTP layer) and against any AXI4-Stream source with the same properties:

| Property of the source | Consequence for the adapter |
| --- | --- |
| The first byte of an SDU is in byte 0; all bytes of a beat are valid except in the last beat of an SDU, whose valid bytes are contiguous from byte 0; no beat without a valid byte; an SDU has 1 to 65536 bytes | `In_Keep` is evaluated only in the last beat (IA-IF-01). A source that leaves a byte invalid in another beat is outside this contract (the Open Logic width converter reports it in simulation) |
| `TUser` is constant during the SDU, except bit 13 (double bit error in the receive buffer), which is valid only with `TLast` | The user signal is evaluated with the last beat (IA-FN-03). The error bit is known only after all other beats of the SDU have been taken, so the samples of a faulty SDU have already gone to the core when its fault is known (IA-ER-01) |
| An SDU read with a double bit error in the receive buffer is delivered with bit 13 set, not dropped | Such an SDU is faulty when bit 13 is in `UserErrorMask_g` |
| Bit 12 (Data Loss Indicator) is set on the first SDU after a gap in the Packet Sequence Count of its APID, when the continuity check is enabled; the lost SDU itself is never delivered | With bit 12 in `UserErrorMask_g` the SDU after a loss is faulty; the loss of the SDU with the end mark is seen only through the next SDU (section 3) |
| Bits 21:14 carry the User Application value of the CPTP packet | The end mark is a value of this field: `UserLastMask_g` = 22x"3FC000", `UserLastValue_g` = value * 2^14 (22x"004000" for the value 1) |
| Bit 11 is the Secondary Header Indicator; a Packet Secondary Header is part of the SDU | The adapter treats every byte of an SDU as sample data. A system whose sender adds a secondary header sets bit 11 in `UserErrorMask_g` to reject such SDUs |
| Back-pressure: the port holds its data while `TReady` is low | The adapter may stall the source at any beat |

## 3. Error conditions

| Condition | Detection | Response | Events |
| --- | --- | --- | --- |
| SDU flagged by its user signal | (`In_User` and `UserErrorMask_g`) /= 0 with the last beat | The samples are forwarded, the last with `Out_Last` and `Out_Error`; the core ends the image with an error (CO-FR-08). Without the end mark, the following SDUs up to and including the next end mark are discarded | `Ev_SduError`; `Ev_SduDiscarded` for every discarded SDU |
| SDU length not a multiple of ceil(D/8) bytes | Incomplete last container | As above; the incomplete container is completed with zero bytes | As above |
| End mark before the last sample of an image, or missing on it | In the core (CO-FR-03, CO-FR-04) | The core aborts or completes the image and flags it | `Ev_ImageError` of the core |
| SDU lost upstream | Not visible to the adapter; with the Data Loss Indicator in `UserErrorMask_g` the next SDU is faulty | As for a flagged SDU: one image ends with an error. When the lost SDU carried the end mark, the next SDU belongs to the next image and is forwarded into the open image; the next image is discarded up to its end mark | As above |

## 4. Configuration parameters

| Generic | Default | Range | Description |
| --- | --- | --- | --- |
| `InWidth_g` | 128 | 8, 16, 32, 64, 128 | Width of the SDU stream in bits |
| `DynamicRange_g` | 16 | 2 to 32 | D: bits per sample; the container has ceil(D/8) bytes |
| `UserWidth_g` | 1 | 1 to 64 | Width of the user signal |
| `UserLastMask_g` | (others => '0') | `UserWidth_g` bits | Bits of the user signal that form the end mark |
| `UserLastValue_g` | (others => '0') | `UserWidth_g` bits, within `UserLastMask_g` | Value of the masked bits that marks the last SDU of an image |
| `UserErrorMask_g` | (others => '0') | `UserWidth_g` bits | Bits of the user signal that flag a faulty SDU |

With the defaults every SDU is the last SDU of an image and no bit of the user signal flags a fault.

## 5. Configuration checks

| ID | Requirement | CCSDS |
| --- | --- | --- |
| IA-CF-01 | The elaboration shall stop when `InWidth_g` is not 8, 16, 32, 64 or 128, or when `UserLastValue_g` has a bit outside `UserLastMask_g`. | none |

## 6. Interpretation

| Clause | Interpretation |
| --- | --- |
| 5.4.2 | The standard defines the order in which the samples enter the compressor, not their format on an interface. The adapter uses containers of ceil(D/8) bytes, most significant byte first, the value in the D least significant bits: the byte order of the compressed image (CCSDS 1.6.3) and of the packet formats of CCSDS. The raw image files of the test tools (little-endian containers of 1, 2 or 4 bytes) are converted by `tools/ocp_model.py`. |
