# ocp_channel: Architecture

## 1. Structure

![Block diagram of ocp_channel: the input adapter, ocp_core, the output width converter
(absent for equal widths) and the status registers ocp_mib with the events of the adapter and the core](img/ocp_channel_arch.drawio.svg)

The channel is a structural entity: the input adapter (`ocp_input_adapter`), the compressor (`ocp_core` with
`UseInLast_g` true), the output adapter and the status interface (`ocp_mib`). Its
only own logic is the output adapter and the decoding of the image events for the counters.

## 2. Output adapter

`olo_base_wconv_n2m` (`InWidth_g` = `OutWidth_g`, `OutWidth_g` = `OutStreamWidth_g`, `UseBe_g` = true) converts the
words of the core into the beats of the output stream: `Out_Keep` of the core drives `In_Be`, `Out_Last` drives
`In_Last`, `Out_Be` becomes `Out_Keep` of the channel. The core marks partial bytes only in the last word of an image
(CO-IF-02), which is the condition of Open Logic for `In_Be`; the converter removes the invalid bytes, so all beats of a
packet are full except the last, whose valid bytes are contiguous from byte 0 (CH-IF-02). The converter handles
back-pressure on both sides.

After the last word of an image the converter takes no input until the last beat of that image has left, so at most
one image end is inside it. A one-bit register therefore carries the error flag: it takes `Out_Error` of the core
with the last word of an image and drives `Out_Error` of the channel with `Out_Last` (CH-IF-03).

When `OutWidth_g` = `OutStreamWidth_g`, no converter is instantiated: the words of the core with `Out_Keep`,
`Out_Last` and `Out_Error` are the beats of the channel.

Throughput: with `OutStreamWidth_g` at least `OutWidth_g` the converter takes a word in every clock cycle in which
it outputs a beat or holds less than one beat; after the last word of an image it waits for the output of the last
beat (CH-TP-01). With `OutStreamWidth_g` below `OutWidth_g` the output stream limits the throughput to
`OutStreamWidth_g` bits per clock cycle.

## 3. Image events

| Event of `ocp_mib` | Source |
| --- | --- |
| `Ev_ImageDone` | Last word of an image taken from the core with `Out_Error` = '0' |
| `Ev_ImageAborted` | Last word of an image taken from the core with `Out_Error` = '1' |
| `Ev_SduError`, `Ev_SduDiscarded` | Input adapter |
| `Ecc_Sec`, `Ecc_Ded` | Core |

The core pulses `Ev_ImageError` once for every image with an error and flags the last word of the same image with
`Out_Error` (CO-FR-05, CO-FR-06), so IMAGES_ABORTED counts the images with `Ev_ImageError`. Counting both image
counters at the output of the core keeps IMAGES_DONE + IMAGES_ABORTED equal to the number of images that have left
the core at any time.

With `RuntimeConfig_g` the configuration outputs of `ocp_mib` (`Cfg_XSize` to `Cfg_RelLimit`) drive the configuration
inputs of the core; `Cfg_Taken` and the values the core took (`Act_XSize` to `Act_RelLimit`) return to the MIB,
which shows them in its active registers and clears CFG_PENDING. The input adapter does not depend on the image
dimensions: it forwards samples and end marks only.

With `RuntimeParams_g` the channel passes the generic to the MIB and the core and connects the parameter outputs of
the MIB (`Cfg_UserData` to `Cfg_RefInterval`) to the core and the `Act_` outputs of the core back to the MIB in the
same way; the ports of the channel do not change.

## 4. Ports

| Port | Direction | Width | Description |
| --- | --- | --- | --- |
| `Clk`, `Rst` | in | 1 | Clock, synchronous high-active reset |
| `In_Valid`, `In_Ready`, `In_Data`, `In_Keep`, `In_Last`, `In_User` | | `InStreamWidth_g`, `InStreamWidth_g` / 8, `UserWidth_g` | SDU stream (`ocp_input_adapter`) |
| `Lim_Valid`, `Lim_Ready`, `Lim_Data` | | 16 | Error limit values for periodic updating (`ocp_core`) |
| `Out_Valid`, `Out_Ready`, `Out_Data`, `Out_Keep`, `Out_Last` | | `OutStreamWidth_g`, `OutStreamWidth_g` / 8 | Compressed images, one packet per image |
| `Out_Error` | out | 1 | Image with an error; valid with `Out_Last` |
| `S_AxiLite_*` | | 8-bit address, 32-bit data | Status registers (`ocp_mib`) |
| `Ecc_Sec`, `Ecc_Ded` | out | 1 | Pulses: corrected and detected memory errors of `ocp_core` (the adapters and the MIB have no memories) |
| `Ev_ImageError` | out | 1 | Pulse: framing error of an image (`ocp_core`) |
| `ErrInj_Channel`, `ErrInj_Double`, `ErrInj_Valid` | in | 4, 1, 1 | Error injection into the memories of `ocp_core` |

## 5. Public entities

| Entity | Use |
| --- | --- |
| `ocp_channel` | Compression channel of a system: SDU stream in, packet stream out, status registers |
| `ocp_core` | Compressor with sample and word interfaces, for systems with another input or output format or without status registers |
| `ocp_input_adapter`, `ocp_mib` | Building blocks of the channel, documented and verified on their own, usable around `ocp_core` in other assemblies |

## 6. Verification approach

The testbench of the channel drives SDUs built from the samples of the test configurations by
`tools/ocp_model.py` (big-endian containers of ceil(D/8) bytes, the end mark on the last SDU of every image, random
SDU lengths and source and sink stalls) and compares every output packet with the golden image of the CNES reference
software, byte by byte. It covers the error scenarios of the specification (section 3) with injected faults in the user
signal, SDUs with an incomplete last sample, lost SDUs, an aborted image followed by a good one, and checks the
counters through the AXI4-Lite slave; the memory error counters are tested through `ErrInj_*`.
