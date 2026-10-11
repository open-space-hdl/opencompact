# OpenCompact Architecture

Version 0.1. This file is the reference for the architecture and is versioned with the code.

## 1 Purpose, scope and references

This document defines the architecture of OpenCompact, an implementation of the compressor of CCSDS 123.0-B-2,
Low-Complexity Lossless and Near-Lossless Multispectral and Hyperspectral Image Compression. Together with the
standard it is the basis for the implementation: it fixes the building blocks, their interfaces, the clauses each
block owns and the Open Logic entities each block is built from.

### In scope

- The complete compressor of CCSDS 123.0-B-2: image properties (section 3), predictor with full and reduced
  prediction, the four local sum types, default and custom weight initialisation, weight exponent offsets, the
  quantizer with lossless, absolute, relative and combined fidelity control including band-dependent error limits
  and periodic error limit updating, sample representatives (section 4), the header with all optional tables, the
  band-interleaved and band-sequential input orders and the sample-adaptive, hybrid and block-adaptive entropy coders
  (section 5).
- The adaptive entropy coder of CCSDS 121.0-B-3 with the preprocessor bypassed, as the block-adaptive coder of
  CCSDS 123.0-B-2 5.4.3.4 requires.
- Fault tolerance of the memories, the verification architecture and the verification against the CNES reference
  software.

### Out of scope

- The decompressor. CCSDS 123.0-B-2 specifies the compressed image; a ground segment decompresses it with software.
  The verification decompresses the compressed images of the testbenches with the decoder of the CNES reference
  software.
- The transport of the compressed image (Space Packets, file systems). The compressed image leaves the core as a
  stream of words with an end-of-image marker; the user packs it into the transport format of the mission (CCSDS
  123.0-B-2 2.4).
- The encoding of supplementary information tables from their values: the core inserts the tables into the header
  as the user encodes them (tools/ocp_generics.py shows the encoding).

### Target technology

OpenCompact contains no vendor code. All memories are Open Logic fault-tolerant entities and all interfaces are
valid / ready streams with AXI4-Stream handshake semantics. The core runs on any FPGA.

### Project

OpenCompact is an open CCSDS 123.0-B-2 compressor based on the Open Logic VHDL Library. The code lives in
[open-space-hdl/opencompact](https://github.com/open-space-hdl/opencompact) under the PSI HDL Library License,
Version 1.0, the licence of Open Logic. Open Logic is pinned to the tag `4.7.0-ft.1` (9fea4eb) of the branch
`fault-tolerant` of open-space-hdl/open-logic-ft, the fault-tolerant fork of Open Logic.

### References

| ID | Document | Version used |
| --- | --- | --- |
| \[CCSDS\] | CCSDS 123.0-B-2, Low-Complexity Lossless and Near-Lossless Multispectral and Hyperspectral Image Compression | Blue Book, Issue 2, February 2019, with Technical Corrigendum 3 |
| \[LDC\] | CCSDS 121.0-B-3, Lossless Data Compression | Blue Book, Issue 3, August 2020 |
| \[CNES\] | CNES reference software for CCSDS 123.0-B-2 and 121.0-B-3 (Low-Complexity Near-Lossless tools, Universitat Autònoma de Barcelona for CNES) | build of 27 January 2022 |
| \[OLO\] | [Open Logic, fault-tolerant fork, branch fault-tolerant](https://github.com/open-space-hdl/open-logic-ft/tree/fault-tolerant) | 4.7.0-ft.1 (9fea4eb) |

### Conventions

- Requirement references are clause numbers of CCSDS 123.0-B-2, for example CCSDS 4.10.3, and equation numbers in
  parentheses. Clauses of CCSDS 121.0-B-3 are written LDC 3.5.
- Coding conventions: those of Open Logic (naming, two-process style, synchronous high-active resets, VSG rules),
  entity prefix `ocp_`, VHDL library `opencompact`; see [conventions.md](conventions.md).
- "FT" (fault-tolerant) means the Open Logic `olo_ft_*` entities: SECDED ECC on every memory.

| Term | Meaning |
| --- | --- |
| NX, NY, NZ | Image width, height and number of spectral bands (CCSDS 3.2) |
| D | Dynamic range of the samples in bits (CCSDS 3.3) |
| t | Index of a sample within its band, t = y NX + x (CCSDS 3.4) |
| BI, BSQ | Band-interleaved and band-sequential input order (CCSDS 5.4.2); BIP and BIL are BI with M = NZ and M = 1 |
| Mapped quantizer index | Unsigned integer delta that the entropy coder encodes (CCSDS 4.11) |
| Entropy coder input sequence | Mapped quantizer indices, and with periodic updating the error limit values, in input order (CCSDS 5.4.1) |
| Codeword | Bit string of at most 64 bits appended to the compressed image |

## 2 Functional overview of CCSDS 123.0-B-2

The compressor predicts every sample from neighbouring samples in the current band and from the P preceding bands,
quantizes the prediction residual with a step size given by the error limits and maps the quantizer index to an
unsigned integer, which the entropy coder encodes (CCSDS 4.1, 5.1). Near-lossless compression bounds the error of
every reconstructed sample by an absolute and/or relative error limit; the lossless mode has error limit zero.

| Function | CCSDS clauses |
| --- | --- |
| Image dimensions, dynamic range, supplementary information tables | 3 |
| Local sums and local differences | 4.4, 4.5 |
| Weights: initialisation, prediction, update | 4.6, 4.7, 4.10 |
| Quantization, fidelity control, periodic error limit updating | 4.8 |
| Sample representatives | 4.9 |
| Mapped quantizer index | 4.11 |
| Header: image, predictor and entropy coder metadata | 5.3 |
| Input order of the entropy coder | 5.4.2 |
| Sample-adaptive, hybrid and block-adaptive entropy coders | 5.4.3 |

Three properties of the standard shape the architecture more than any single feature:

- **Prediction depends on reconstructed values.** In near-lossless compression the predictor works on sample
  representatives, which depend on the quantization of the sample itself (CCSDS 4.9). The central local difference
  of a sample is known only after its quantization, and the next band at the same position needs it. A sample is
  therefore processed completely, including the weight update, before the next sample starts.
- **The predictor needs a line of every band.** Local sums use the previous row of the same band, inter-band
  prediction the central local differences of the P preceding bands at the same position. The memory grows with
  NX NZ in BI order and with NX NY P in BSQ order.
- **The compressed image is exactly defined.** Header, codewords and fill bits are specified to the bit, so the
  output of the core can be compared bit by bit with an independent implementation.

## 3 Design drivers

| Driver | Consequence |
| --- | --- |
| Complete standard | Every option of CCSDS 123.0-B-2 is a generic; the three entropy coders are separate blocks selected at elaboration (D3) |
| Use in space: single event upsets in memories and state | SECDED ECC on every memory, state machines with a recovery state, ECC event outputs (P5) |
| Bit-exact compressed images | Verification against the CNES reference software, byte by byte, for every configuration of the regression (section 9) |
| Technology independence | Valid / ready streams, no vendor primitive (P10) |
| Small footprint for small images and few bands | Memories sized by the generics of the image; logic of unused options removed by generics (D2) |
| Reuse | Memories and ECC from Open Logic; custom logic is limited to the compression algorithm (P9) |

## 4 Design goals

| Goal | Implementation |
| --- | --- |
| Defined handshakes between blocks | Every internal data path is a valid / ready stream (P2) |
| One function per block | A block implements one part of the standard; no clause is owned by two blocks (P1) |
| Exact arithmetic | All quantities of the standard computed with `numeric_std` in widths derived from the generics; no overflow and no rounding outside the standard (D5) |
| Fault tolerance | FT memories, safe state machines (P5) |
| Configuration at elaboration | All image and compression parameters are generics; the header is computed from them (D2) |
| Tests independent of the design hierarchy | Tests observe only ports (section 9) |

## 5 Design principles

| ID | Principle | Rule for the implementation |
| --- | --- | --- |
| P1 | One function per block | A block implements one part of the standard. Its specification names the clauses it owns; no clause is owned by two blocks. |
| P2 | Streams everywhere | Every data path between blocks is a valid / ready stream (Open Logic AXI4-Stream conventions). |
| P3 | One clock domain | All blocks run in `Clk`. |
| P4 | Configuration by generics | Every parameter of the standard is a generic of `ocp_core`; per-band tables are `integer_vector` generics whose last element repeats. |
| P5 | Fault tolerance by construction | All memories are `olo_ft_*` entities (SECDED ECC) with their single and double error events at the ports of the core. State machines have a defined recovery state. |
| P6 | Exact to the bit | The compressed image is identical to the one of the CNES reference software for the same configuration and image. |
| P7 | No hidden state between images | Every image starts with the initial state of the standard; consecutive images are independent compressed images. |
| P8 | Verifiable in isolation | Each module has a specification and a testbench that drives only its ports. Reference data comes from the CNES reference software and from an independent reference model. |
| P9 | Reuse before design | A function available in Open Logic (memory, ECC, FIFO) is instantiated, not rewritten. |
| P10 | No vendor code | The core has no vendor primitive. |

## 6 Architecture overview

```text
                 +------------------------------------------------------------------------------+
                 |                    CO-1 header generator --+                                 |
                 |                                            v                                 |
 In  (samples) ->| PR-1 sequencer --> PR-2..PR-6 predictor --> EC-1 | EC-2 | EC-3 --> CO-2 bit -->|-> Out (words)
 Lim (limits)  ->|   input order       quantizer, mapper      entropy coder        packer       |
                 |                                                                  CO-3        |
                 |   FT memories: sample representatives, local differences, weights,           |
                 |   error limits, coder statistics ----------------------------------------->  |-> Ecc_Sec, Ecc_Ded
                 +------------------------------------------------------------------------------+
```

The samples enter in the input order of the compressed image (BI with sub-frame interleaving depth M, or BSQ). The
predictor is a pipeline: it reads the neighbours and the weights, predicts, quantizes, computes the sample
representative, updates the weights and writes the state back, one stage per clock cycle, and starts a sample as soon
as the samples it depends on have left the feedback loops. Its output is the entropy coder input sequence. The entropy
coder selected by `EntropyCoder_g` turns it into codewords, one item per clock cycle; the bit packer appends the
header and the codewords to the compressed image, adds the fill bits after the last codeword and outputs words of
8 to 64 bits.

### Architecture decisions

| ID | Decision | Reason |
| --- | --- | --- |
| D1 | One clock domain `Clk`, synchronous high-active reset `Rst` | The core is a stream processor; crossings belong to the integration |
| D2 | All image and compression parameters are generics of `ocp_core`; the header is a constant computed at elaboration and streamed before the body of every image | The parameters of a compressor are fixed for a mission or an instrument mode; constants remove the logic of unused options and make the header exact by construction |
| D3 | The entropy coder is chosen by `EntropyCoder_g`; only the selected coder is instantiated | The three coders share no state; one per configuration keeps the footprint small |
| D4 | The predictor is a pipeline without internal stalls; its issue stage starts a sample once the samples it depends on (previous sample of the band, sample of the previous band at the same pixel) have left the feedback loops | The dependencies of the standard limit the throughput, not the arithmetic: with enough distance between dependent samples every configuration runs at one sample per clock cycle, and the same datapath is exact for every input order and every option. Throughput is a function of the configuration (section 6, performance) |
| D11 | The error sign of the weight update is computed from the high-resolution sum by comparisons with thresholds of the sample; when consecutive samples belong to the same band the weight loop speculates over the signs of the two samples ahead (four weight vectors); in BI order with M = NZ near-lossless compression processes the samples of a pixel in stride order | The weight update depends on one bit per sample, so the loop closes after the dot product and can be unrolled over the unknown signs; the stride order makes the bands of a pixel independent of each other in the pipeline |
| D12 | The entropy coders concatenate their codewords into words of up to 96 bits before an output FIFO | The FIFO then absorbs the header of the next image, and the bit packer catches up with several codewords per clock cycle |
| D5 | Widths of the datapath derived from D, Omega and R: the dot product is computed without overflow and wrapped to R bits as (37) requires; weight increments are saturated to the weight range before clipping | The predicted values are exact for every allowed parameter, including D = 32, Omega = 19 and R = 64 |
| D6 | Neighbours are kept in a memory of the current row of every band (BI) or of row 0 of the current and the previous band and the current row (BSQ), the window of the previous row and the previous sample per band; the central local differences of the P preceding bands in one word per pixel of a row (BI with M < NZ) or of a band (BSQ); the weight vector of every band in one word | One read and one write per memory and sample; memories sized by the image |
| D7 | Error limits for periodic updating enter on their own stream in the order of the entropy coder input sequence and are forwarded into it | The user supplies them every 2^u frames (CCSDS 4.8.2.4.2) from any source |
| D8 | The image ends with the last codeword: the bit packer adds the fill bits up to the output word boundary of the whole compressed image and marks the last interface word with its valid bytes; the header of the next image starts once its first sample is accepted | Consecutive compressed images on one stream, each self-delimiting by the end-of-image marker |
| D9 | The low-entropy codes of the hybrid coder are state machines whose states are the active prefixes; their code and flush tables (CCSDS annex B) are ROM constants generated from the tables of the standard | Exact transcription of the 32 normative tables; one table lookup per low-entropy symbol |
| D10 | Supplementary information tables are given as their encoded header bits (`SupTableData_g`) | Tables are data for the user of the image, not used by the compression |

### Clock and reset

All blocks run in `Clk`. The reset input `Rst` is synchronous and high-active (Open Logic convention); the integrator
synchronises it to `Clk`, for example with `olo_ft_reset_gen`.

### Internal interfaces

| Interface | Between | Payload | Protocol |
| --- | --- | --- | --- |
| Samples | User to PR-1 | D-bit sample, unsigned or two's complement | Valid / ready |
| Error limits | User to PR-1 | 16-bit error limit value | Valid / ready |
| Entropy coder input | Predictor to EC-1, EC-2, EC-3 | Value (mapped quantizer index or error limit), kind, band, first sample of the band (t = 0), first coded sample (t = 1), last item of the image | Valid / ready |
| Codewords | CO-1, EC-1, EC-2, EC-3 to CO-2 | Up to 96 bits, length, last codeword of the image | Valid / ready |
| Compressed image | CO-2 to user | Word of 8, 16, 32 or 64 bits, valid bytes, last word of the image | Valid / ready |

### Performance

The predictor is a pipeline that takes one sample per clock cycle as long as dependent samples are far enough apart:
the previous sample of a band at least the length of the weight loop (7 to 11 cycles) and, in near-lossless
compression, of the sample representative loop (about 33 cycles), the sample of the previous band at the same pixel
in near-lossless compression also about 33 cycles. Three mechanisms provide that distance:

- BI order spreads the samples of a band M samples apart: BIP (M = NZ) with enough bands runs at one sample per cycle.
- When consecutive samples belong to the same band (BSQ, BI with M = 1), the weight loop speculates over the error
  signs (at most three local differences; lossless, or absolute error limits with narrow local sums and reduced
  prediction): one sample per cycle.
- In BI order with M = NZ, near-lossless compression processes the samples of a pixel in stride order, the bands S
  slots apart: one sample per cycle for NZ above about 33, and still a gain of a factor of ten for fewer bands.

The entropy coders take one item per cycle; the bit packer outputs `OutWidth_g` bits per cycle. The throughput model
`tools/ocp_throughput.py` gives the cycle in which the predictor issues every sample; the testbenches check the RTL
against it cycle by cycle. The user guide lists the throughput of the configurations of section 9.

## 7 Building block specifications

The core has 13 building blocks in four groups. Each block lists its responsibility, the Open Logic entities it is
built from and the clauses it owns (P1: no clause is owned twice).

### 7.1 Predictor (`ocp_predictor`)

| ID | Block | Responsibility | Open Logic | CCSDS |
| --- | --- | --- | --- | --- |
| PR-1 | Sequencer | Position (x, y, z, t) of the next sample in BI or BSQ order or in stride order, flags of the first sample of a band (t = 0) and of the last sample, start of a sample once its dependencies have left the feedback loops, periodic error limit updating: read the limits at the start of every 2^u-th frame and forward them; output FIFO, in stride order input and output buffers | `olo_ft_ram_sdp` (band-dependent limits, stride buffers), `olo_ft_fifo_sync` (output) | 3.2, 3.3, 3.4, 4.8.2.3, 4.8.2.4, 5.4.2 |
| PR-2 | Local sums and differences | Neighbour memory, local sum of the four types, central and directional local differences, local difference vector | `olo_ft_ram_sdp` (neighbours, central differences) | 4.2, 4.3, 4.4, 4.5 |
| PR-3 | Prediction | Weight memory, initial weights (default and custom), predicted central local difference, high-resolution, double-resolution and predicted sample values | `olo_ft_ram_sdp` (weights) | 4.6, 4.7 |
| PR-4 | Quantizer | Prediction residual, maximum error from absolute and relative error limits, quantizer index, clipped bin center | none | 4.8.1, 4.8.2.1, 4.8.2.2 |
| PR-5 | Sample representative and weight update | Sample representative with damping and offset, double-resolution prediction error, weight update scaling exponent, weight update with weight exponent offsets | none | 4.9, 4.10 |
| PR-6 | Mapper | Mapped quantizer index | none | 4.11 |

### 7.2 Entropy coders (`ocp_entropy_coder`)

| ID | Block | Responsibility | Open Logic | CCSDS |
| --- | --- | --- | --- | --- |
| EC-1 | Sample-adaptive coder | Accumulator and counter per band, code selection, length-limited GPO2 codewords, uncoded first sample, error limit values | `olo_ft_ram_sdp` (statistics), `olo_ft_fifo_sync` (codeword buffer) | 5.4.3.2 |
| EC-2 | Hybrid coder | High-resolution accumulator and counter per band with rescaling bit, high-entropy reversed GPO2 codewords, 16 low-entropy codes, compressed image tail | `olo_ft_ram_sdp` (statistics), `olo_ft_fifo_sync` (codeword buffer) | 5.4.3.3, annex B |
| EC-3 | Block-adaptive coder | Blocks of J values, zero padding, option selection (no compression, second extension, fundamental sequence, split samples, zero block with remainder of segment), coded data sets | `olo_ft_fifo_sync` (codeword buffer) | 5.4.3.4, LDC 3, LDC 5.2 |

### 7.3 Core (`ocp_core`)

| ID | Block | Responsibility | Open Logic | CCSDS |
| --- | --- | --- | --- | --- |
| CO-1 | Header generator | Image metadata with supplementary information tables, predictor metadata with weight, quantization and sample representative subparts, entropy coder metadata | none | 3.5, 5.3 |
| CO-2 | Bit packer | Codewords to interface words, fill bits up to the output word boundary, end of the compressed image | none | 5.2 |
| CO-3 | Image sequencer | Header before the body of every image, end of the image after the last codeword, ECC events of all memories | none | 5.2.1 |

### 7.4 Common definitions (`ocp_pkg`)

| ID | Block | Responsibility | Open Logic | CCSDS |
| --- | --- | --- | --- | --- |
| PK-1 | Common package | Stream definitions, codes of the string generics, per-band table access | none | none |
| PK-2 | Low-entropy code tables | Code and flush tables of the 16 low-entropy codes as ROM constants, input symbol limits and thresholds | none | 5.4.3.3.3.3, annex B |

## 8 Open Logic usage

| Open Logic entity | Used in | Purpose |
| --- | --- | --- |
| `olo_ft_ram_sdp` | PR-1, PR-2, PR-3, EC-1, EC-2 | Simple dual-port memories with SECDED ECC: sample representatives, central local differences, weights, error limits, stride buffers, coder statistics |
| `olo_ft_fifo_sync` | PR-1, EC-1, EC-2, EC-3 | FIFOs with SECDED ECC: output of the predictor, codeword buffers of the entropy coders |
| `olo_base_pl_stage` | PR-1 | Register stage at the output of the predictor |
| `olo_base_pkg_math` | all | `log2ceil` for the widths of addresses and counters |

### Gaps in Open Logic

| Gap | Resolution in this architecture |
| --- | --- |
| No pipelined divider | The quantizer divides by 2 m + 1 with a restoring division, one quotient bit per pipeline stage, inside PR-4 |
| No bit packer for variable-length codewords | CO-2 |

## 9 Verification architecture

The core is verified with VUnit and UVVM in a seven-phase module workflow (requirements, architecture, verification
plan, RTL, testbenches, verification, integration; see [conventions.md](conventions.md)). Every building block of
section 7 belongs to a module with its own specification, verification plan, testbench and verification report. Every
test case names the requirements it verifies, and every requirement names its clauses, so the traceability matrix of
section 10 is checked by `tools/compliance.py`.

| Level | Scope | Bench | Checks |
| --- | --- | --- | --- |
| Unit | Predictor | `ocp_predictor_tb`: test image of a configuration in input order, periodic error limits | Entropy coder input sequence (values, kinds, bands, flags) against the reference model; cycles of the input (and in stride order of the output) against the throughput model |
| Core | Header, predictor, entropy coders and bit packer | `ocp_core_tb`: two images in sequence, interface widths of 8 to 64 bits, optional back pressure | Compressed images byte by byte, including the end-of-image marker and the valid bytes, against the CNES reference software; for the throughput configurations the cycles of the input of both images against the throughput model |

### Reference data

- `tools/golden.py` compresses the test image of every configuration of `tools/ocp_configs.py` with the CNES reference
  software (`lcnl_header_tool`, `lcnl_encoder`) and decompresses it with `lcnl_decoder`: lossless images must be
  reconstructed exactly, near-lossless images within the error limits. The test images, the compressed images, the
  error limit values and the optional tables are stored in `tb/golden/<configuration>/`.
- The reference model `tools/ocp_model.py` is an independent implementation of the compressor in Python, written from
  the clauses of the standard. `tools/golden.py` requires it to produce the same compressed image as the CNES
  software for every configuration; `tools/check_model_testvectors.py` checks it against the CCSDS test data set of
  randomly configured images (TestVectors-B2, Test1-20181021): the model reproduces all 6474 compressed images of the
  set, 347 with the sample-adaptive, 223 with the hybrid and 5904 with the block-adaptive coder. The model provides
  the entropy coder input sequence for the unit testbench of the predictor.
- The test images are synthetic and deterministic: scenes of three materials with smooth spectra, edges and noise,
  push-broom stripes, flat low-entropy images and uncorrelated noise.

### Configurations

The regression runs every testbench with every configuration of `tools/ocp_configs.py`. Together the configurations
cover all options of the standard:

| Configuration | Options covered |
| --- | --- |
| c01_lossless_bip | Lossless, full prediction, wide neighbour-oriented local sums, BIP, sample-adaptive coder, 4-byte words |
| c02_lossless_bil_column | Reduced prediction, wide column-oriented local sums, BIL, band-dependent accumulator initialisation table |
| c03_lossless_bsq_narrow | BSQ, narrow neighbour-oriented local sums, 8-bit samples, weight exponent offset table |
| c04_near_abs_hybrid | Band-independent absolute error limit, sample representatives (damping, offset), hybrid coder, 8-byte words |
| c05_near_rel_bi4_signed | Signed samples, BI with M = 4, band-dependent relative error limits, narrow column-oriented local sums, reduced prediction with weight exponent offsets, hybrid coder |
| c06_near_both_block | Absolute and relative error limits, band-varying damping and offset tables, block-adaptive coder with reference interval 4 |
| c07_lossless_block_bsq | Block-adaptive coder in BSQ order on a low-entropy image: zero blocks and remainder of segment, J = 64 |
| c08_restricted_d4 | 4-bit samples, restricted set of code options, J = 8 |
| c09_custom_weights | Custom weight initialisation table, weight exponent offsets outside the header (optional table) |
| c10_periodic_limits | Periodic error limit updating every two frames, band-dependent absolute and band-independent relative limits, BI with M = 2, hybrid coder |
| c11_wide_d32 | 32-bit samples, P = 15, Omega = 19, R = 64, Umax = 32, gamma* = 11, gamma0 = 8 |
| c12_single_column | Image of width one: reduced prediction with narrow column-oriented local sums |
| c13_single_band_hybrid | One band, P = 0, hybrid coder on a low-entropy image (low-entropy codes, flush words) |
| c14_supplementary_tables | Four supplementary information tables (unsigned 1-D, signed 0-D, float 2-D-zx, unsigned 2-D-yx), user-defined data |
| c15_noise_escape | Uncorrelated noise: escape codewords at Umax = 8, fast rescaling with gamma* = 4, K = 0 |
| c16_hybrid_low_entropy | Band-dependent absolute error limits from 0 to 255: all 16 low-entropy codes of the hybrid coder with escape symbols and flush words |
| c17_block_zero_runs | Constant bands with outliers in BSQ order: runs of all-zeros blocks up to a full segment, remainder of segment, reference interval of 70 blocks, J = 8 |
| c18_block_d24_mixed | 24-bit signed samples, noise in every second band: no-compression option and split-sample options with 5-bit identifiers, J = 32 |
| c19_block_restricted_d2 | 2-bit samples, restricted set of code options with 1-bit identifiers, periodic error limits in the block-adaptive coder input, vanishing weight increments (vmax = 9, Omega = 4) |
| c20_hybrid_d28 | 28-bit samples with the hybrid coder: initial accumulators up to 2^33 - 1, 40-bit final accumulators |
| c21_sample_periodic | Sample-adaptive coder with periodic error limit updating every frame (absolute band-independent, relative band-dependent), BIL |
| c22_single_pixel_hybrid | Image of one pixel per band: uncoded samples only, hybrid coder tail with the initial accumulators |
| c23_extreme_weights | D = 3, Omega = 19, vmin = vmax = -6, weight exponent offsets -6: weight increments beyond the weight range |
| c24_reduced_p0 | Reduced prediction with P = 0 (no weights), block-adaptive coder with J = 8 |
| c25_hp_bsq_lossless | Throughput: BSQ, lossless, reduced prediction with P = 3, narrow local sums, D = 16, Omega = 19, R = 48: speculative weight loop |
| c26_hp_bil_near_abs | Throughput: BIL, absolute error limit with sample representatives, reduced prediction with P = 3, narrow column-oriented local sums, hybrid coder: speculative weight loop |
| c27_hp_bip_full | Throughput: BIP with 24 bands, full prediction with P = 3, block-adaptive coder |
| c28_hp_bsq_near_abs | Throughput: BSQ, absolute error limit, reduced prediction with P = 2, narrow neighbour-oriented local sums: speculative weight loop |
| c29_hp_bip_near_stride | Throughput: BIP with 40 bands, absolute error limit with sample representatives, full prediction with P = 3: stride order |
| c30_hp_bip_both_stride | Throughput: BIP with 48 bands, absolute and relative error limits, reduced prediction with P = 2, narrow column-oriented local sums, hybrid coder: stride order |

### Framework

- VUnit (`run.py`) discovers and runs every test and is the CI regression; the configurations are VUnit
  configurations of the testbenches (`hdl/<module>/tb/vunit_config.py`).
- UVVM supplies alert and log handling, `check_value` and randomisation of the back pressure.
- Simulator: GHDL for every test; QuestaSim for code coverage.

### Rules

- Tests observe ports only (P8).
- A failed check fails the test; a test cannot pass with a failed step.
- Every commit passes the full regression.

## 10 Requirement traceability matrix

Every clause in the scope of section 1 has exactly one owner block. "First verified at" names the lowest verification
level at which the clause can be fully checked. The [compliance matrix](compliance.md), generated from this table, the
module specifications and the verification plans, lists the requirements and test cases of every clause.

| CCSDS clause | Title | Owner | Also involved | First verified at |
| --- | --- | --- | --- | --- |
| 3.2 | Dimensions | PR-1 | CO-1 | Unit |
| 3.3 | Dynamic range | PR-1 | PR-4 | Unit |
| 3.4 | Sample coordinate indices | PR-1 |  | Unit |
| 3.5 | Supplementary information tables | CO-1 |  | Core |
| 4.2 | Number of bands for prediction | PR-2 | PR-3 | Unit |
| 4.3 | Full and reduced prediction modes | PR-2 | PR-3 | Unit |
| 4.4 | Local sum | PR-2 |  | Unit |
| 4.5 | Local differences | PR-2 |  | Unit |
| 4.6 | Weights | PR-3 | CO-1 | Unit |
| 4.7 | Prediction calculation | PR-3 |  | Unit |
| 4.8.1 | Quantizer output | PR-4 |  | Unit |
| 4.8.2.1, 4.8.2.2 | Controlling maximum error, allowed error limit values | PR-4 | CO-1 | Unit |
| 4.8.2.3 | Error limit assignment methods | PR-1 | CO-1 | Unit |
| 4.8.2.4 | Periodic error limit updating | PR-1 | EC-1, EC-2, EC-3 | Core |
| 4.9 | Sample representatives | PR-5 | CO-1 | Unit |
| 4.10 | Weight update | PR-5 |  | Unit |
| 4.11 | Mapped quantizer index | PR-6 |  | Unit |
| 5.2 | General: compressed image, output word size | CO-2 | CO-3 | Core |
| 5.3 | Header | CO-1 |  | Core |
| 5.4.2 | Input order | PR-1 | EC-3 | Unit |
| 5.4.3.2 | Sample-adaptive entropy coder | EC-1 |  | Core |
| 5.4.3.3 | Hybrid entropy coder | EC-2 | PK-2 | Core |
| 5.4.3.4 | Block-adaptive entropy coder | EC-3 |  | Core |

## 11 Development plan

1. Foundations: repository, reference model, golden data from the CNES reference software, regression and CI.
2. Predictor (PR-1 to PR-6) with the unit testbench against the reference model.
3. Entropy coders (EC-1 to EC-3), header generator and bit packer (CO-1 to CO-3) with the core testbench against the
   CNES reference software.
4. Demonstrator: all configurations of section 9 bit-exact, synthesizability check, first performance estimates.
5. Verification closure: unit testbenches of the entropy coders, error injection into the memories, code coverage,
   then pipelining of the predictor towards one sample per cycle.
