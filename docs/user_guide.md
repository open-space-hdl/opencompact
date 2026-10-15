# OpenCompact User Guide

OpenCompact compresses multispectral and hyperspectral images according to CCSDS 123.0-B-2, Low-Complexity Lossless
and Near-Lossless Multispectral and Hyperspectral Image Compression. This guide explains how to integrate the core:
sources, generics, interfaces, operating sequence, integration constraints, performance and the conformance
statement.

## 1. Sources

| Library | Files | Content |
| --- | --- | --- |
| `olo` | All of `open-logic/src/base` and `open-logic/src/ft` in the order of `open-logic/compile_order.txt` (used: `olo_ft_ram_sdp`, `olo_ft_fifo_sync`, `olo_base_pl_stage` and their dependencies) | Open Logic, fault-tolerant fork, tag `4.7.0-ft.6` |
| `opencompact` | `hdl/ocp_pkg/src/ocp_pkg.vhd`, `hdl/ocp_pkg/src/ocp_low_entropy_pkg.vhd`, `hdl/ocp_predictor/src/*.vhd`, `hdl/ocp_entropy_coder/src/*.vhd`, `hdl/ocp_core/src/*.vhd` | OpenCompact; top level `ocp_core` |

All sources are VHDL-2008 and contain no vendor primitive. `tools/synth_libero.py` shows a complete synthesis and
place and route flow (Microchip Libero SoC); `tools/ocp_wrapper.py` writes a synthesis top level with the generics of a
configuration for any other tool.

## 2. Generics

All parameters of CCSDS 123.0-B-2 are generics of `ocp_core`; the header of the compressed image is computed from
them. Per-band tables are `integer_vector` generics: element z belongs to band z and the last element repeats for the
remaining bands, so `(0 => 2)` gives the value 2 to every band.

### 2.1 Image and compressed image

| Generic | Default | Range | Header field (CCSDS) |
| --- | --- | --- | --- |
| `XSize_g`, `YSize_g`, `ZSize_g` | 8, 8, 4 | 1 to 65536 | X, Y, Z Size (5.3.2.2) |
| `DynamicRange_g` | 16 | 2 to 32 | Dynamic Range, Large Dynamic Range Flag |
| `SignedSamples_g` | false | | Sample Type |
| `UserData_g` | 0 | 0 to 255 | User-Defined Data |
| `EncodingOrder_g` | "BI" | "BI", "BSQ" | Sample Encoding Order (5.4.2) |
| `SubFrameDepth_g` | 4 | 1 to NZ | Sub-Frame Interleaving Depth M (BI order) |
| `OutputWordSize_g` | 1 | 1 to 8 | Output Word Size B (5.2.2) |
| `EntropyCoder_g` | "SAMPLE_ADAPTIVE" | "SAMPLE_ADAPTIVE", "HYBRID", "BLOCK_ADAPTIVE" | Entropy Coder Type |
| `SupTableCount_g` | 0 | 0 to 15 | Supplementary Information Table Count |
| `SupTableData_g` | x"00" | | Supplementary Information Tables subpart (5.3.2.3), byte-aligned, as encoded by the user |

### 2.2 Predictor

| Generic | Default | Range | Header field (CCSDS) |
| --- | --- | --- | --- |
| `PredictionBands_g` | 3 | 0 to 15 | Number of Prediction Bands P (4.2) |
| `PredictionMode_g` | "FULL" | "FULL", "REDUCED" | Prediction Mode (4.3) |
| `LocalSum_g` | "WIDE_NEIGHBOR" | "WIDE_NEIGHBOR", "NARROW_NEIGHBOR", "WIDE_COLUMN", "NARROW_COLUMN" | Local Sum Type (4.4) |
| `RegisterSize_g` | 64 | max(32, D + Omega + 2) to 64 | Register Size R (4.7.2) |
| `WeightResolution_g` | 13 | 4 to 19 | Weight Component Resolution Omega (4.6.1) |
| `WeightUpdateInterval_g` | 6 | 4 to 11 | log2 of the Weight Update Scaling Exponent Change Interval tinc (4.10.2) |
| `WeightUpdateVmin_g`, `WeightUpdateVmax_g` | -1, 3 | -6 <= vmin <= vmax <= 9 | Weight Update Scaling Exponent Initial and Final Parameter |
| `WeightExpOffsetsUsed_g` | false | | Weight Exponent Offset Flag (4.10.4) |
| `WeightExpOffsetTable_g` | false | | Weight Exponent Offset Table in the header (5.3.3.3.3) |
| `WeightExpOffsets_g` | (0 => 0) | -6 to 5 | Per band: intra-band offset (full mode), then Pz* inter-band offsets, in the order of the table |
| `CustomWeights_g` | false | | Weight Initialization Method (4.6.3) |
| `WeightInitTable_g` | false | | Weight Initialization Table in the header (5.3.3.3.2) |
| `WeightInitResolution_g` | 0 | 3 to Omega + 3 | Weight Initialization Resolution Q |
| `WeightInitValues_g` | (0 => 0) | Q-bit signed | Per band Cz components, in the order of the table |

### 2.3 Quantizer and sample representatives

| Generic | Default | Range | Header field (CCSDS) |
| --- | --- | --- | --- |
| `Fidelity_g` | "LOSSLESS" | "LOSSLESS", "ABSOLUTE", "RELATIVE", "ABSOLUTE_RELATIVE" | Quantizer Fidelity Control Method (4.8.2.1) |
| `PeriodicUpdate_g`, `UpdatePeriodExp_g` | false, 0 | u: 0 to 9 | Periodic Updating Flag, Update Period Exponent (4.8.2.4) |
| `AbsBandDependent_g`, `AbsBitDepth_g`, `AbsErrorLimits_g` | false, 1, (0 => 0) | DA: 1 to min(D - 1, 16) | Absolute Error Limit block (5.3.3.4.3) |
| `RelBandDependent_g`, `RelBitDepth_g`, `RelErrorLimits_g` | false, 1, (0 => 0) | DR: 1 to min(D - 1, 16) | Relative Error Limit block (5.3.3.4.4) |
| `SampleRepResolution_g` | 0 | 0 to 4 | Sample Representative Resolution Theta; above 0 the Sample Representative subpart is included (5.3.3.5) |
| `DampingBandVarying_g`, `DampingTable_g`, `Damping_g` | false, false, (0 => 0) | 0 to 2^Theta - 1 | Damping phi_z (4.9.1) |
| `OffsetBandVarying_g`, `OffsetTable_g`, `Offset_g` | false, false, (0 => 0) | 0 to 2^Theta - 1 | Offset psi_z |

With periodic updating, `AbsErrorLimits_g` and `RelErrorLimits_g` are not used: the limits come from the `Lim` port.

### 2.4 Entropy coders

| Generic | Default | Range | Header field (CCSDS) |
| --- | --- | --- | --- |
| `UnaryLimit_g` | 16 | 8 to 32 | Unary Length Limit Umax |
| `RescaleCounterSize_g` | 6 | max(4, gamma0 + 1) to 11 | Rescaling Counter Size gamma* |
| `InitialCountExp_g` | 1 | 1 to 8 | Initial Count Exponent gamma0 |
| `AccuInitBandVarying_g`, `AccuInitTable_g`, `AccuInit_g` | false, false, (0 => 3) | 0 to min(D - 2, 14) | Sample-adaptive coder: Accumulator Initialization Constant K (first element) or the values k''_z per band, and their table (5.3.4.2) |
| `HybridAccuInit_g`, `HybridAccuInitHigh_g` | (0 => 0), (0 => 0) | 0 to 2^(D + gamma0) - 1 | Hybrid coder: initial high-resolution accumulator per band, `HybridAccuInitHigh_g` 2^31 + `HybridAccuInit_g` (5.4.3.3.4.3, not in the header) |
| `BlockSize_g` | 16 | 8, 16, 32, 64 | Block-adaptive coder: Block Size J |
| `RestrictedCodes_g` | false | D <= 4 | Restricted Code Options Flag |
| `RefInterval_g` | 4096 | 1 to 4096 | Reference Sample Interval r |

### 2.5 Implementation

| Generic | Default | Range | Description |
| --- | --- | --- | --- |
| `OutWidth_g` | 8 | 8, 16, 32, 64 | Width of the compressed image interface in bits (section 4) |
| `Speculation_g` | true | | Speculative weight loop of the predictor where it applies (section 7) |
| `UseInLast_g` | false | | Image framing with `In_Last`: early and missing image ends are detected, flagged and resynchronised (section 4.2) |
| `RamStyle_g` | "auto" | | Implementation of the memories: passed unchanged to `RamStyle_g` of the Open Logic RAMs and FIFOs, which set the synthesis attributes `ram_style` and `ramstyle` with it (values of the synthesis tool, for example "block" or "distributed"); the simulation does not depend on it |

The stride order of the predictor is used wherever it applies (section 7.1); it has no generic at the core level.

The elaboration stops for parameter values that the standard does not allow (section 6). Every value of a generic that
changes the structure of the core is simulated, and the bounds of every numeric range are synthesised; the
verification report of `ocp_core` lists the simulated and synthesised values of every generic. The image dimensions
are verified in part: NX, NY, NZ and M are simulated from 1 to 64, 64, 48 and 48 (the CCSDS test data set reaches 66
columns, 513 rows, 239 bands and M = 32) and synthesised in these ranges and at 65536, with the other dimensions at 1
or 2. Larger images are not verified.

The supplementary information tables are given as their encoded subpart: per table the 16 bits of table type, purpose,
structure and user-defined data, then the Table Data subblock with its fill bits (5.3.2.3). The function
`sup_table_hex` of `tools/ocp_generics.py` produces the value of `SupTableData_g` from the table values.

## 3. Clock and reset

The core has one clock `Clk`. `Rst` is synchronous and high-active and must last at least one clock cycle; the
integrator synchronises it, for example with `olo_base_reset_gen` (`SyncTmr_g` = true for a triplicated
synchroniser). After the reset the core waits for the first sample
of an image. A reset at any time aborts the image in progress (header, body or tail); the next image is compressed
from the initial state of the standard. The memories need no initialisation: the core uses data read from a memory
only after it has been written in the same image.

## 4. Interfaces

| Port | Direction | Width | Description |
| --- | --- | --- | --- |
| `In_Valid`, `In_Ready`, `In_Data` | in, out, in | D | Samples, unsigned or two's complement, in the input order of the compressed image |
| `In_Last` | in | 1 | '1' with the last sample of every image (`UseInLast_g`, section 4.2); unused otherwise, may stay open |
| `Lim_Valid`, `Lim_Ready`, `Lim_Data` | in, out, in | 16 | Error limit values for periodic updating (unused otherwise) |
| `Out_Valid`, `Out_Ready`, `Out_Data`, `Out_Keep`, `Out_Last` | out, in, out, out, out | `OutWidth_g`, `OutWidth_g` / 8 | Compressed image in words: byte n of a word in `Out_Data` bits 8n + 7 to 8n, so the first byte of the image is in bits 7 to 0 of the first word; `Out_Last` on the last word of an image, whose valid bytes `Out_Keep` marks (bit n for byte n, contiguous from bit 0); all other words are complete |
| `Out_Error` | out | 1 | Valid with `Out_Last`: '1' when the image had a framing error (section 4.2); '0' on every other word and without `UseInLast_g` |
| `Ecc_Sec`, `Ecc_Ded` | out | 1 | One-cycle pulses: corrected single error, detected double error in a memory |
| `Ev_ImageError` | out | 1 | One-cycle pulse per image with a framing error (section 4.2), for a counter or an interrupt |
| `ErrInj_Channel`, `ErrInj_Double`, `ErrInj_Valid` | in | 4, 1, 1 | Error injection for tests: a pulse on `ErrInj_Valid` flips one bit (`ErrInj_Double` = '0') or two bits of the next word written into the memory of channel `ErrInj_Channel` (section 4.1); tie to '0' in operation |

All streams use the AXI4-Stream handshake: a transfer takes place in a cycle with valid and ready high.

The compressed image is a sequence of bytes; within a byte the first bit is the most significant bit (CCSDS 1.6.3).
The bytes are placed in increasing order of their position in the word, the order of byte-addressed memory buses (AXI
puts the byte at address offset n on bits 8n + 7 to 8n) and of the Open Logic width converters: a word written into
memory keeps the byte order of the compressed image, and the 8-bit stream after `olo_base_wconv_xn2n` is the
compressed image itself. Example with
`OutWidth_g` = 32 and an image of the six bytes B0 to B5 (B = 1, 2, 3 or 6):

| Word | `Out_Data` 31:24 | 23:16 | 15:8 | 7:0 | `Out_Keep` | `Out_Last` |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | B3 | B2 | B1 | B0 | "1111" | '0' |
| 2 | - | - | B5 | B4 | "0011" | '1' |

The input order (CCSDS 5.4.2) is:

- BI with depth M: for every row y, for every group of M bands (the last group may be smaller), for every column x, the
  bands of the group in increasing order. M = NZ is BIP, M = 1 is BIL.
- BSQ: band by band, every band row by row.

With periodic error limit updating, the core reads the error limit values at the start of every frame y with
y mod 2^u = 0, before the first sample of that frame: the absolute limits (A*, or a_0 to a_(NZ-1)) followed by the
relative limits (R*, or r_0 to r_(NZ-1)), each as a 16-bit value of which DA or DR bits are used.

### 4.1 Memories and error injection

Every memory of the core is protected by a SECDED code: a single bit error in a word is corrected when the word is
read (`Ecc_Sec`), a double bit error is detected (`Ecc_Ded`). The tables of the configuration (low-entropy codes,
initial weights and accumulators, damping and offset values) are constants and map to logic. The channels of the error
injection:

| Channel | Memory | Present |
| --- | --- | --- |
| 0 | Sample representatives of the current line of every band | always |
| 1 | Window of the previous line of every band | BI order with M > 1 |
| 2 | Sample representative of the previous sample of every band | always |
| 3 | First sample representative of the line of every band | always |
| 4 | Central local differences of the previous bands | P > 0 in BSQ order or in BI order with M < NZ |
| 5 | Weights of every band | C > 0, except with the speculative weight loop in BSQ order and in single-band images |
| 6 | Band-dependent absolute error limits | periodic error limit updating with band-dependent absolute limits |
| 7 | Band-dependent relative error limits | periodic error limit updating with band-dependent relative limits |
| 8 | Output FIFO of the predictor | always |
| 9, 10, 11 | Input buffer, output buffer and local differences of the stride order | stride order (section 7.1) |
| 12 | Statistics of the entropy coder | sample-adaptive and hybrid coder |
| 13 | Codeword buffer of the entropy coder | always |

The flags count only in cycles in which the core takes the read data for an item: an upset of a word that is not read
again, or that is read only in a cycle without an item, raises no alarm. An injection into a channel without memory has
no effect.
`tools/ocp_throughput.py` (`ecc_channels`) lists the channels of a configuration.

### 4.2 Image framing

The core counts the NX NY NZ samples of an image by itself. When samples get lost upstream, for example in a lost
packet, it would compress the samples of the next image as the rest of the damaged one, and every following image
would start at the wrong sample. With `UseInLast_g` the core checks the image end marker `In_Last` against its count
and resynchronises:

| Case | Behaviour of the core |
| --- | --- |
| `In_Last` with the last sample | Correct image: `Out_Error` = '0' on its last word |
| `In_Last` before the last sample (samples lost inside the image) | The image is aborted. The sample with `In_Last` is taken; once the earlier images have left the entropy coder, the predictor and the coder are cleared. The compressed image ends after its complete header and the codewords already produced, with at least one fill bit up to a multiple of B bytes, and its last word carries `Out_Error` = '1'. The next sample starts a new image with its own header; no sample of it is lost. |
| No `In_Last` with the last sample (the end marker was lost) | The image is completed normally; its last word carries `Out_Error` = '1'. The core then takes the following samples and discards them, one per clock cycle, up to and including the next sample with `In_Last`; the sample after it starts a new image. |

`Ev_ImageError` pulses once for every image with an error, when the error is detected at the input. An aborted image is
not decodable as a whole (its header announces the full image); its first part is the compressed image of the
samples before the loss. An image without its end marker is complete, but its last samples may belong to the next
image. The system marks or discards both kinds by `Out_Error`. The stream stays aligned to B bytes, so the next image
starts like after a correct one.

Error limit values (periodic updating): the core takes none from the sample with the error until the next image may
start, and the next value it takes belongs to the first frame of the next image. A source that computes the values on
request (`Lim_Ready`) needs no action; a source that delivers them ahead (a buffer) drops the remaining values of the
damaged image on `Ev_ImageError`. The limit values are part of the compressed image, so values that do not match
their frame change only the compression of that image, never its decodability.

Integration with OpenSPP: the samples arrive as Octet String SDUs. The sender marks the last SDU of an image (for
example by its APID or a field of the Packet Secondary Header), and the adapter between OpenSPP and the core sets
`In_Last` on the last sample of that SDU. A lost SDU inside an image makes the marked SDU arrive early: the image is
aborted (`In_Last` before the last sample). A lost marked SDU makes the core complete the image with the first
samples of the next one and discard the rest of that image: the core is back in step with the stream at the next
marked SDU. The Data Loss Indicator of OpenSPP (`TUser` bit 12 of the first SDU after the gap, with the continuity
check of the APID enabled) and `Ev_ImageError` together tell the system which images are affected.

## 5. Operating sequence

1. Release the reset.
2. Send the samples of the image in the input order (and the error limit values when they are requested). The header
   of the compressed image is output once the first sample or error limit value has been accepted.
3. Take the compressed image from `Out` until `Out_Last`. Its size is a multiple of the output word size B; the next
   image starts with a new word.
4. Send the next image; it is compressed independently with the same parameters. The samples of the next image may
   follow the last sample of an image without a gap.
5. With `UseInLast_g`, set `In_Last` on the last sample of every image and check `Out_Error` on the last word of every
   compressed image (section 4.2).

The output can be stalled at any time; the core then stops taking samples after its internal buffers are full.

A detected double error (`Ecc_Ded`) may falsify the compressed image in progress; the core continues to the end of the
image. The system discards that image and resets the core before the next image. A corrected single error changes
nothing; its counter is a measure of the upset rate.

## 6. Integration constraints

| Constraint | Reason |
| --- | --- |
| Periodic error limit updating requires BI order | CCSDS 4.8.2.4.4 |
| An image of width 1 requires reduced prediction and column-oriented local sums | CCSDS 4.3.1, 4.4.1 (elaboration stops otherwise) |
| The elaboration stops for the parameter values of section 2 that the standard does not allow: register size below max(32, D + Omega + 2), width 1 with full prediction or neighbour-oriented local sums, vmin above vmax, periodic updating in BSQ order, M above NZ, block sizes other than 8, 16, 32 and 64, restricted code options with D above 4, rescaling counter sizes below max(4, gamma0 + 1) and accumulator initialisation values above min(D - 2, 14). The user keeps the other ranges of the standard, for example the values of the error limit and weight tables | The header fields have the widths of the standard and would carry most of these values; the compressed image would contradict its header |
| The decompressor must know the tables that are not included in the header (table flags false) and the initial accumulators of the hybrid coder | CCSDS 5.3.3.3.2.1, 5.4.3.3.4.3 |
| The hybrid coder needs the end of the compressed image to decode it in reverse; `Out_Last` marks it | CCSDS 5.4.3.3.1 |
| With `UseInLast_g`, `In_Last` accompanies the last sample of every image | Otherwise every image is flagged and the samples up to the next `In_Last` are discarded (section 4.2) |

## 7. Resources and performance

### 7.1 Throughput

The predictor is a pipeline that starts one sample per clock cycle as long as dependent samples are far enough apart
(see the [architecture of the predictor](../hdl/ocp_predictor/docs/architecture.md)). The rate depends on the
configuration:

| Configuration | Mechanism | Samples per clock cycle |
| --- | --- | --- |
| BI order with M at least the weight loop (7 to 11 cycles), lossless | Pipeline | 1 |
| BSQ order or BI order with M = 1, at most three local differences (C <= 3); lossless, or absolute error limits with narrow local sums and reduced prediction | Speculative weight loop (`Speculation_g`) | 1 |
| BI order with M = NZ, near-lossless with P > 0 or narrow local sums (no periodic updating) | Stride order | 1 for NZ above about 33; NZ / 33 otherwise; plus about (NZ - 1) S cycles per image |
| BSQ order or BI order with small M otherwise | Pipeline | M / (loop length): 1/8 to 1/11 in lossless, about 1/33 in near-lossless compression |

The entropy coders take one item per clock cycle. The bit packer outputs `OutWidth_g` bits per clock cycle: with
16-bit samples and an interface of 32 bits the output keeps up with one sample per cycle down to a compression ratio
of 0.5. The header of the next image takes a few cycles that the codeword buffers absorb. `tools/ocp_throughput.py`
computes the cycle in which the predictor takes every sample of a configuration:

```shell
python tools/ocp_throughput.py                     # all configurations of tools/ocp_configs.py
python tools/ocp_throughput.py c25_tp_bsq_lossless
```

Cycles per sample of the predictor for the configurations of the regression (throughput model, checked by the
testbenches cycle by cycle):

| Configuration | Order, mode | Cycles per sample |
| --- | --- | --- |
| c01, c09, c11, c12, c15, c18, c22, c27 | BIP or BI with M >= 8, lossless | 1.00 |
| c14, c20, c24 | BIP with 3 to 6 bands, lossless | 1.33 |
| c23 | BIP with 4 bands and five local differences, lossless | 1.98 |
| c36 | BSQ without local differences (reduced prediction, P = 0), lossless | 1.00 |
| c13, c25 | One band (BI) or BSQ, lossless, speculative weight loop | 1.00 |
| c26, c28, c35 | BIL or BSQ, near-lossless, speculative weight loop (c35 with periodic error limit updating) | 1.00 to 1.02 |
| c29, c30 | BIP with 40 and 48 bands, near-lossless, stride order | 1.00 per sample, plus (NZ - 1)(S - 1) cycles per image |
| c04, c06, c16 | BIP with 10 to 16 bands, near-lossless, stride order | 2.3 to 3.8 |
| c33 | BIP with 6 bands, near-lossless, stride order, image of 20 pixels | 14.2 (the per-image cycles of the stride order dominate) |
| c02, c03, c07, c08, c17, c34, c37 | BIL or BSQ with more than three local differences, lossless | 7.5 to 8.0 |
| c05, c10, c19, c21, c31, c32, c38 | BI with M < NZ or with periodic error limit updating, near-lossless | 17.5 to 31.5 |

Consecutive images: `image_period(g)` of `tools/ocp_throughput.py` gives the cycles between the first samples of two
images that follow each other without gaps and without back pressure. Outside stride order an image follows the
previous one like the samples of one image: its first sample waits only for the samples it depends on. In stride
order the next image starts once all slots of the image have passed and its last item has been read from the output
buffer; the input buffer takes the first sample of the next image four cycles after that read. The period then
exceeds the input span of an image by the stride skew and the latency of the output buffer (c29: 4322 cycles for
2880 samples). TC-CO-50 checks the period exactly.

Size of a compressed image: `max_image_bytes(cfg)` of `tools/ocp_model.py` is a strict upper bound on the size of
the compressed image of any image of a configuration; its docstring names the clause of every term:

| Part | Bits |
| --- | --- |
| Header | 8 H, with H bytes from `header(cfg)` |
| Error limit values (periodic updating) | DA per absolute and DR per relative value: NZ or 1 of each at every update frame |
| Sample-adaptive coder | D per band (first index) plus Umax + D per further index |
| Hybrid coder | D per band (first index) plus Umax + D + 21 per further index (length-limited codeword or escape residual, and the longest low-entropy output codeword), one bit per rescaling of the statistics of a band (counted from the counter, which does not depend on the data), and the tail: 130 (longest flush codeword of each low-entropy code) + NZ (2 + D + gamma\*) + 1 |
| Block-adaptive coder | ceil((NX NY NZ + error limit values) / J) blocks of at most ID + J D bits (no-compression option; option identifier ID of 1 to 5 bits) |
| Fill bits | Up to the next multiple of B bytes |

Every compressed image of the regression and of the CCSDS test data set is at most this size (TC-CO-51). For
incompressible images the block-adaptive bound is reached to 99 % (c18, D = 24, noise in every second band: 4629 of
4659 bytes) and the sample-adaptive bound to 70 % (c15, noise: 2145 of 3083 bytes); small images of the test data set
reach it exactly. The hybrid bound is reached to 35 % (c20, D = 28: 2315 of 6605 bytes): it allows an escape residual
and the longest low-entropy output codeword for every index, more than any image produces at every index.

### 7.2 Resources

Resources and clock frequency with Libero SoC 2025.2 (Synplify Pro and SmartTime) for a PolarFire MPF100T (FCG484,
STD speed grade, industrial range) and a 32-bit interface. The clock frequencies are the place and route results
for a 100 MHz constraint; the cycles per sample are those of the throughput model (section 7.1; for c29 and c30 the
small test images make the per-image skew of the stride order visible).

| Configuration | Cycles per sample | LUT | Flip-flops | LSRAM | uSRAM | Math blocks | Clock frequency |
| --- | --- | --- | --- | --- | --- | --- | --- |
| c01: 32 x 12 x 16, D = 16, BIP, lossless, P = 3 full, sample-adaptive | 1.00 | 11521 | 5422 | 1 | 34 | 13 | 133 MHz |
| c03: 20 x 10 x 8, D = 8, BSQ, lossless, P = 2 full, narrow local sums, sample-adaptive | 7.93 | 12058 | 4231 | 1 | 17 | 7 | 120 MHz |
| c04: 24 x 12 x 12, D = 16, BIP, absolute error limit, P = 3 full, hybrid (stride order) | 3.14 | 20908 | 13832 | 3 | 41 | 36 | 116 MHz |
| c06: 24 x 12 x 10, D = 16, BIP, absolute and relative error limits, P = 4 full, block-adaptive (stride order) | 3.78 | 19433 | 16994 | 3 | 40 | 23 | 106 MHz |
| c11: 12 x 8 x 18, D = 32, BIP, lossless, P = 15 full, Omega = 19, sample-adaptive | 1.00 | 39435 | 15178 | 12 | 34 | 74 | 81 MHz |
| c20: 12 x 10 x 6, D = 28, BIP, lossless, P = 3 full, hybrid | 1.33 | 21949 | 7337 | 1 | 41 | 31 | 125 MHz |
| c25: 32 x 12 x 6, D = 16, BSQ, lossless, P = 3 reduced, narrow local sums, sample-adaptive (speculative weight loop) | 1.00 | 13310 | 4123 | 3 | 17 | 49 | 106 MHz |
| c26: 40 x 8 x 6, D = 16, BIL, absolute error limit, P = 3 reduced, narrow column-oriented local sums, hybrid (speculative weight loop) | 1.00 | 22928 | 11584 | 1 | 34 | 68 | 106 MHz |
| c27: 16 x 8 x 24, D = 16, BIP, lossless, P = 3 full, block-adaptive | 1.00 | 19945 | 7396 | 1 | 33 | 25 | 107 MHz |
| c29: 12 x 6 x 40, D = 12, BIP, absolute error limit, P = 3 full, sample-adaptive (stride order) | 1.49 | 16248 | 11776 | 5 | 38 | 11 | 117 MHz |
| c30: 10 x 5 x 48, D = 16, BIP, absolute and relative error limits, P = 2 reduced, hybrid (stride order) | 1.67 | 18545 | 10727 | 7 | 33 | 25 | 119 MHz |

All configurations reach 100 MHz except c11, which combines D = 32 with Omega = 19: the product of a 35-bit local
difference and a 22-bit weight needs a cascade of four math blocks within one clock cycle. A second product stage for
such widths is an open item of the [roadmap](roadmap.md).

The logic grows with D, with the number of local differences C and, for the speculative weight loop, four times with
C; the memories grow with the image (NX NZ D bits for the sample representatives in BI order, the input and output
buffers of the stride order) and with C (Omega + 3) bits per band for the weights. The image framing (`UseInLast_g`)
adds 93 LUTs and 49 flip-flops and no memory; it puts one more multiplexer level between the codeword buffer and the
bit packer, which in c01 is the critical path (place and route at 125 MHz instead of 133 MHz).
`python tools/synth_libero.py --config <configuration> [--impl] [--in-last]` repeats a run;
`python tools/libero_summary.py` lists the results.

## 8. Conformance statement

The implementation conformance statement of CCSDS 123.0-B-2 annex A for the compressor `ocp_core`: every item of the
requirements list is supported with the full range of values of the standard.

| Table | Items | Support | Values supported |
| --- | --- | --- | --- |
| A-1 Image | I1 signed samples, I2 unsigned samples, I3 to I5 X, Y, Z size, I6 dynamic range, I7 supplementary information tables | Y | NX, NY, NZ: 1 to 2^16; D: 2 to 32 |
| A-2 Supplementary information tables | S1 number of tables, S2 purpose, S3 unsigned, S4 signed, S5 float tables with all bit depths, exponent bias and structures | Y | 0 to 15 tables, as encoded by the user (`SupTableData_g`) |
| A-3 Prediction | P1 number of prediction bands, P2 full and P3 reduced mode, P4 to P7 the four local sum types, P8 register size, P9 sample representative resolution, P10 band-varying damping, P11 damping, P12 band-varying offset, P13 offset | Y | P: 0 to 15; R: max(32, D + Omega + 2) to 64; Theta: 0 to 4; phi, psi: 0 to 2^Theta - 1 |
| A-4 Weights | W1 weight resolution, W2 default and W3 custom initialisation, W3.1 resolution Q, W4 vmin, W5 vmax, W6 tinc, W7 intra-band and W8 inter-band weight exponent offsets | Y | Omega: 4 to 19; Q: 3 to Omega + 3; vmin, vmax: -6 to 9; tinc: 2^4 to 2^11; offsets: -6 to 5 |
| A-5 Quantization | Q1 lossless, Q2 absolute and Q3 relative error limits (bit depths, band-dependent and band-independent assignment, values), Q4 periodic error limit updating with u | Y | DA, DR: 1 to min(D - 1, 16); u: 0 to 9 |
| A-6 Encoder | E1 output word size, E2 BI order with E2.1 depth M, E3 BSQ order, E4 sample-adaptive, E5 hybrid, E6 block-adaptive coder | Y | B: 1 to 8; M: 1 to NZ |
| A-7 Header | H1 to H9: all header parts, subparts and optional tables | Y | Tables included or omitted by generics |
| A-8 Sample-adaptive coder | ES1 gamma0, ES2 accumulator initialisation table, ES3 accumulator initialisation constant, ES4 gamma*, ES5 Umax | Y | gamma0: 1 to 8; k''_z, K: 0 to min(D - 2, 14); gamma*: max(4, gamma0 + 1) to 11; Umax: 8 to 32 |
| A-9 Hybrid coder | EH1 gamma0, EH2 initial high-resolution accumulators, EH3 gamma*, EH4 Umax | Y | Accumulators: 0 to 2^(D + gamma0) - 1 |
| A-10 Block-adaptive coder | EB1 block size, EB2 reference sample interval, EB3 basic and EB4 restricted code options | Y | J: 8, 16, 32, 64; r: 1 to 4096 |

The decompressor is not part of the core. The verification compares the compressed images of the core with those of
the CNES reference software for the configurations of the regression; the [compliance matrix](compliance.md) traces
every clause to its requirements and test cases.

## 9. Generating reference data

`tools/golden.py` regenerates the golden data of the regression (`tb/golden/`) with the CNES reference software for
CCSDS 123.0-B-2 (Linux executables, on Windows through WSL):

```shell
python tools/golden.py --cnes-bin /path/to/cnes/bin            # all configurations of tools/ocp_configs.py
python tools/golden.py --cnes-bin /path/to/cnes/bin c01_lossless_bip
```

A new configuration is a new entry in `tools/ocp_configs.py`; the testbenches pick it up automatically. The random
configurations `r01_random` to `r24_random` come from `random_config(seed)` in the same file: every parameter is drawn
in the range of the standard, with a small test image.

The CCSDS test data set (images compressed with randomly chosen configurations) is not part of the repository.
`tools/ocp_testvectors.py` selects test vectors from it that together cover the parameter values of the data set,
converts them into the golden format and writes them into a directory; the core, predictor and entropy coder
testbenches then run them as well:

```shell
python tools/ocp_testvectors.py /path/to/testdata --out /path/to/selection --count 300
OCP_TESTVECTORS=/path/to/selection python run.py -p 4
```

## 10. Corrected defects

| Defect | Affected | Effect | Correction |
| --- | --- | --- | --- |
| `BlockSize_g` other than 8, 16, 32 and 64 was accepted | All versions before the generic range checks | The header carries the block size code of 64 while the block-adaptive coder codes blocks of the given size, so the compressed image cannot be decompressed | The elaboration stops (CO-CF-02, section 6) |
