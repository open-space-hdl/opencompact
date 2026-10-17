# ocp_input_adapter: Architecture

## 1. Structure

![Block diagram of ocp_input_adapter: the SDU control (state, Pending, user signal of the
last beat), the width converter olo_base_wconv_n2m (absent for one container per beat) and the sample extraction](img/ocp_input_adapter_arch.drawio.svg)

SB = ceil(D/8) is the container size in bytes. The width converter cuts the beats of an SDU into containers; the
sample extraction turns a container into a sample; the SDU control evaluates the user signal of the SDU, sets the image
end marker and the error flag with the last sample of the SDU and discards the rest of an image after a faulty SDU.

## 2. Width converter

`olo_base_wconv_n2m` with `InWidth_g` = `InWidth_g` of the adapter, `OutWidth_g` = 8 SB and `UseBe_g` = true converts
the SDU stream into a stream of containers. `In_Keep` drives `In_Be`; Open Logic allows a partial `In_Be` only in the
last beat, which is the contract of the source (specification, section 2.4). The converter aligns little-endian: the
first byte of an SDU is in bits 7 to 0 of the first container. With `In_Last` it flushes the SDU; its last container
carries `Out_Last` and, when the SDU ends inside the container, a partial `Out_Be`. After `In_Last` the converter
takes no input until the last container of the SDU has left, so at most one SDU is inside it.

When `InWidth_g` = 8 SB (8 bits with D up to 8, 16 bits with D from 9 to 16, 32 bits with D from 25 to 32) every beat
is one container and no converter is instantiated: data, `In_Keep` and `In_Last` pass directly.

## 3. Sample extraction

The container is mirrored byte by byte, so that its first byte becomes the most significant one (big-endian, IA-FN-01).
Bytes with `Out_Be` = '0' (the missing bytes of an incomplete last container) are set to zero before the mirroring
(IA-ER-01). The sample is the D least significant bits of the result. The extraction is combinational.

## 4. SDU control

| Register | Function |
| --- | --- |
| `State` | `Run_s`: SDUs go through the converter. `Discard_s`: SDUs are taken from the source and dropped |
| `User` | User signal of the SDU in the converter, taken with its last beat |
| `Pending` | The last beat of an SDU is in the converter and its last sample has not been taken by the core |
| `EvError`, `EvDiscard` | Event pulses |

```text
                faulty SDU without end mark taken by the core
     +-------+ -------------------------------------------> +-----------+
     | Run_s |                                              | Discard_s |
     +-------+ <------------------------------------------- +-----------+
                last beat of an SDU with the end mark taken
```

In `Run_s`, `In_Ready` is the ready of the converter while `Pending` is '0'. `Pending` keeps the first beat of the
next SDU out of the converter until the last sample of the current SDU has been taken: the decision to discard the
next SDUs depends on the length check of the last container, which is known only at the converter output. This costs
one clock cycle per SDU (IA-FN-05). Without converter the last beat is the last sample and `Pending` stays '0'.

With the last container of an SDU (converter `Out_Last`):

- End mark: (`User` and `UserLastMask_g`) = `UserLastValue_g`.
- Fault: (`User` and `UserErrorMask_g`) /= 0, or `Out_Be` not all ones.
- `Out_Last` = end mark or fault; `Out_Error` = fault.
- When the core takes the sample: `Ev_SduError` with a fault; `State` becomes `Discard_s` with a fault and no end mark.

In `Discard_s`, `In_Ready` is '1' and the beats bypass the converter. The last beat of every SDU pulses
`Ev_SduDiscarded`; with the end mark (evaluated on `In_User` of that beat) `State` returns to `Run_s`. A reset clears
`State`, `Pending` and the converter (IA-ER-04). The state machine returns to `Run_s` from any other encoding.

## 5. Image end with an error: the `In_Error` input of the core

### 5.1 Why the adapter cannot do it alone

The fault of an SDU is known only with its last beat: the error bit of the receive buffer of a Space Packet Protocol
core is valid only with `TLast`, and the length check needs the last container. By then the other samples of the SDU
are in the core. The adapter can end the image only with the last sample of the SDU. Three ways without a change of
the core were considered:

| Alternative | Result |
| --- | --- |
| Hold every SDU until its status is known | A buffer of the longest SDU (65536 bytes for the Octet String Service), SECDED-protected, and the latency of a whole SDU per channel |
| Set only `In_Last` with the last sample of a faulty SDU | When the samples of the faulty SDU complete the image (fault in the SDU with the end mark; or, after the loss of the SDU with the end mark, a next SDU with as many samples as the lost one) the core sees a correctly framed image: no `Ev_ImageError`, no `Out_Error`, a corrupted image counted as good |
| Withhold the last sample of every SDU and end the image one sample earlier when the SDU is faulty | Needs a sample delay across SDU boundaries for SDUs of one sample, drops an intact sample, and still yields a correctly framed image when the source delivered more samples than the image holds |

### 5.2 Function in the core (CO-FR-08)

`ocp_core` gets the input `In_Error` (default '0'), evaluated only with `In_Last` = '1' and `UseInLast_g` true:

| Case | Behaviour |
| --- | --- |
| `In_Last` and `In_Error` with the last sample of an image | The compressed image is complete and bit-identical to the image of the same samples without the flag. `Out_Error` = '1' with its last word, one `Ev_ImageError` pulse; the next sample starts a new image |
| `In_Last` and `In_Error` before the last sample | Abort as with `In_Last` alone (CO-FR-03) |
| `In_Error` without `In_Last`, or while the core discards samples after a missing `In_Last` (CO-FR-04) | Ignored |

The image framer (`ocp_image_framer`) needs no new state: with the last sample of an image the error flag it writes
into its flag queue becomes (not `In_Last`) or `In_Error`, and `Ev_ImageError` pulses for the same condition. The flag
queue, `Out_Error`, the error limit handling (CO-FR-07) and the resynchronisation are those of the existing framing
errors. Cost: two gates.

### 5.3 Discard of the rest of the image

Without the discard, the SDUs after a faulty SDU up to the end mark would form a second image with fewer samples,
aborted at the end mark: two `Ev_ImageError` and an extra compressed image of displaced samples per fault. With the
discard, every fault ends exactly one image with an error, and the next image starts with the SDU after the end mark.

### 5.4 Verification impact

`In_Error` defaults to '0', and all existing tests of `ocp_core` drive it '0': their results, including the
bit-identity of every compressed image with the CNES reference software, are unaffected. New test cases of `ocp_core`
cover the three cases of section 5.2: the complete image with `In_Error` is compared with the golden image and must
carry `Out_Error` and one `Ev_ImageError`; the early end with `In_Error` must give the abort of CO-FR-03; `In_Error`
without `In_Last` must give the golden image without error.

## 6. Ports

| Port | Direction | Width | Description |
| --- | --- | --- | --- |
| `Clk` | in | 1 | Clock |
| `Rst` | in | 1 | Synchronous reset, high-active |
| `In_Valid`, `In_Ready` | in, out | 1 | Handshake of the SDU stream |
| `In_Data` | in | `InWidth_g` | Bytes of the SDU, byte n in bits 8n + 7 to 8n |
| `In_Keep` | in | `InWidth_g` / 8 | Valid bytes; all ones except in the last beat of an SDU, contiguous from byte 0 |
| `In_Last` | in | 1 | Last beat of an SDU |
| `In_User` | in | `UserWidth_g` | User signal, evaluated with the last beat |
| `Out_Valid`, `Out_Ready` | out, in | 1 | Handshake of the sample stream |
| `Out_Data` | out | `DynamicRange_g` | Sample |
| `Out_Last` | out | 1 | Last sample of an image (end mark or fault) |
| `Out_Error` | out | 1 | The image ends with an error; valid with `Out_Last` |
| `Ev_SduError` | out | 1 | Pulse: faulty SDU forwarded |
| `Ev_SduDiscarded` | out | 1 | Pulse: SDU discarded |

## 7. Behaviour

Image k of 6 SDUs, the third flagged faulty (D = 16, 128-bit beats, 8 samples per beat):

| SDU | User signal | Adapter | Core |
| --- | --- | --- | --- |
| 1, 2 | no mark, no fault | Samples forwarded | Image k continues |
| 3 | fault | Samples forwarded, the last with `Out_Last` and `Out_Error`; `Ev_SduError`; `Discard_s` | Image k aborted (CO-FR-03), `Out_Error` on its last word, `Ev_ImageError` |
| 4, 5 | no mark | Discarded, `Ev_SduDiscarded` each | Idle |
| 6 | end mark | Discarded, `Ev_SduDiscarded`; `Run_s` | Idle |
| 7 | no mark | Samples forwarded | First samples of image k + 1 |

## 8. Resources and throughput

Registers: the converter (`InWidth_g` + 8 SB bits of data and one flag per byte), the user register (`UserWidth_g`
bits), the state, `Pending` and two event bits. No memory. The converter outputs one container per clock cycle while it
holds one; it takes the next beat in the cycle in which its content drops below one container, so the samples of an
SDU leave without gaps when the source delivers in time. Between two forwarded SDUs, `Pending` inserts one clock cycle
without a sample.
