# OpenCompact User Guide

OpenCompact compresses multispectral and hyperspectral images according to CCSDS 123.0-B-2, Low-Complexity Lossless
and Near-Lossless Multispectral and Hyperspectral Image Compression. This guide explains how to integrate the core:
sources, generics, interfaces, operating sequence, integration constraints, performance and the conformance
statement.

## 1. Sources

| Library | Files | Content |
| --- | --- | --- |
| `olo` | `open-logic/src/base/vhdl/olo_base_pkg_*.vhd`, `olo_base_ram_sdp.vhd`, `open-logic/src/ft/vhdl/olo_ft_pkg_*.vhd`, `olo_ft_ecc_encode.vhd`, `olo_ft_ecc_decode.vhd`, `olo_ft_ram_sdp.vhd` (or all of `src/base` and `src/ft` in the order of `open-logic/compile_order.txt`) | Open Logic, fault-tolerant fork, tag `4.7.0-ft.1` |
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
| `RamStyle_g` | "auto" | | Implementation of the memories (Open Logic) |

The supplementary information tables are given as their encoded subpart: per table the 16 bits of table type, purpose,
structure and user-defined data, then the Table Data subblock with its fill bits (5.3.2.3). The function
`sup_table_hex` of `tools/ocp_generics.py` produces the value of `SupTableData_g` from the table values.

## 3. Clock and reset

The core has one clock `Clk`. `Rst` is synchronous and high-active and must last at least one clock cycle; the
integrator synchronises it, for example with `olo_ft_reset_gen`. After the reset the core waits for the first sample
of an image.

## 4. Interfaces

| Port | Direction | Width | Description |
| --- | --- | --- | --- |
| `In_Valid`, `In_Ready`, `In_Data` | in, out, in | D | Samples, unsigned or two's complement, in the input order of the compressed image |
| `Lim_Valid`, `Lim_Ready`, `Lim_Data` | in, out, in | 16 | Error limit values for periodic updating (unused otherwise) |
| `Out_Valid`, `Out_Ready`, `Out_Data`, `Out_Last` | out, in, out, out | 8 | Compressed image, first byte first; `Out_Last` on the last byte of an image |
| `Ecc_Sec`, `Ecc_Ded` | out | 1 | One-cycle pulses: corrected single error, detected double error in a memory |

All streams use the AXI4-Stream handshake: a transfer takes place in a cycle with valid and ready high.

The input order (CCSDS 5.4.2) is:

- BI with depth M: for every row y, for every group of M bands (the last group may be smaller), for every column x, the
  bands of the group in increasing order. M = NZ is BIP, M = 1 is BIL.
- BSQ: band by band, every band row by row.

With periodic error limit updating, the core reads the error limit values at the start of every frame y with
y mod 2^u = 0, before the first sample of that frame: the absolute limits (A*, or a_0 to a_(NZ-1)) followed by the
relative limits (R*, or r_0 to r_(NZ-1)), each as a 16-bit value of which DA or DR bits are used.

## 5. Operating sequence

1. Release the reset.
2. Send the samples of the image in the input order (and the error limit values when they are requested). The header
   of the compressed image is output as soon as the first sample or error limit value arrives.
3. Take the compressed image from `Out` until `Out_Last`. Its size is a multiple of the output word size B.
4. Send the next image; it is compressed independently with the same parameters.

The output can be stalled at any time; the core then stops taking samples after its internal buffers are full.

## 6. Integration constraints

| Constraint | Reason |
| --- | --- |
| Periodic error limit updating requires BI order | CCSDS 4.8.2.4.4 |
| An image of width 1 requires reduced prediction and column-oriented local sums | CCSDS 4.3.1, 4.4.1 (elaboration stops otherwise) |
| The parameter ranges of section 2 are checked only where the elaboration would otherwise be wrong (register size, width 1, vmin and vmax, periodic updating with BSQ); the user keeps the other ranges of the standard | Header fields have the widths of the standard |
| The decompressor must know the tables that are not included in the header (table flags false) and the initial accumulators of the hybrid coder | CCSDS 5.3.3.3.2.1, 5.4.3.3.4.3 |
| The hybrid coder needs the end of the compressed image to decode it in reverse; `Out_Last` marks it | CCSDS 5.4.3.3.1 |

## 7. Resources and performance

The predictor processes one sample in 16 + 2 C cycles (C = P + 3 in full, P in reduced prediction mode), plus
max(D, 16) + 2 cycles for a sample with a non-zero maximum error. The memories grow with the image: two rows of every
band (BI) or six rows and P bands of local differences (BSQ).

Cycles per sample measured in simulation; resources and clock frequency with Libero SoC 2025.2 (Synplify Pro and
SmartTime) for a PolarFire MPF100T (FCG484, STD speed grade, industrial range), with the configurations of the
regression ([architecture](architecture.md), section 9). The place and route results are for a 100 MHz constraint;
the synthesis estimates are the estimates of Synplify Pro.

| Configuration | Cycles per sample | LUT | Flip-flops | LSRAM | uSRAM | Math blocks | Clock frequency |
| --- | --- | --- | --- | --- | --- | --- | --- |
| c01: 32 x 12 x 16, D = 16, lossless, P = 3 full, sample-adaptive | 28.0 | 4000 | 946 | 2 | 19 | 3 | 147 MHz (place and route) |
| c03: 20 x 10 x 8, D = 8, BSQ, P = 2 full, sample-adaptive | 25.9 | 2998 | 740 | 3 | 3 | 5 | 96 MHz (synthesis estimate) |
| c04: 24 x 12 x 12, D = 16, near-lossless, P = 3 full, hybrid | 45.9 | 10184 | 1506 | 2 | 20 | 24 | 128 MHz (place and route) |
| c06: 24 x 12 x 10, D = 16, near-lossless, P = 4 full, block-adaptive | 46.1 | 5756 | 1550 | 1 | 23 | 12 | 103 MHz (place and route) |
| c09: 20 x 12 x 10, D = 16, custom weights, P = 4 full, sample-adaptive | 30.0 | 5375 | 1080 | 1 | 23 | 8 | 94 MHz (synthesis estimate) |
| c11: 12 x 8 x 18, D = 32, P = 15 full, sample-adaptive | 51.6 | 11327 | 2787 | 49 | 6 | 6 | 72 MHz (synthesis estimate) |
| c16: 32 x 16 x 16, D = 12, near-lossless, P = 2 full, hybrid | 42.8 | 8830 | 1204 | 1 | 14 | 19 | 112 MHz (synthesis estimate) |
| c18: 16 x 8 x 12, D = 24, lossless, P = 2 full, block-adaptive | 28.8 | 5668 | 1836 | 1 | 17 | 4 | 103 MHz (place and route) |
| c20: 12 x 10 x 6, D = 28, lossless, P = 3 full, hybrid | 28.0 | 11366 | 1697 | 1 | 24 | 22 | 100 MHz (synthesis estimate) |

The logic grows with D and with the number of local differences C; the memories grow with the image (NX NZ D bits
for the sample representatives in BI order) and with C (Omega + 3) bits per band for the weights. These are the
figures of a demonstrator: the predictor processes one sample at a time, and the roadmap lists the steps to one sample
per clock cycle. `python tools/synth_libero.py --config <configuration> [--impl]` repeats a run;
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

A new configuration is a new entry in `tools/ocp_configs.py`; the testbenches pick it up automatically.
