# ocp_predictor: Specification

## 1. Overview

`ocp_predictor` implements the predictor of CCSDS 123.0-B-2 (section 4) with the quantizer, the sample
representatives and the mapper: blocks PR-1 to PR-6 of the architecture. It takes the samples of an image in the input
order of the compressed image and produces the entropy coder input sequence: one mapped quantizer index per sample and,
with periodic error limit updating, the error limit values at the start of every update period.

## 2. Requirements

### 2.1 Interfaces and sequencing (PR-1)

| ID | Requirement | CCSDS |
| --- | --- | --- |
| PR-IF-01 | The predictor shall accept images of NX, NY and NZ from 1 to 65536 samples, with a dynamic range D from 2 to 32 bits, of unsigned or signed (two's complement) samples. | 3.2, 3.3 |
| PR-IF-02 | The predictor shall accept the samples in band-interleaved order with a sub-frame interleaving depth M from 1 to NZ and in band-sequential order. | 5.4.2.1, 5.4.2.2.1, 5.4.2.3 |
| PR-IF-03 | The predictor shall output the entropy coder input sequence in the input order with, for every mapped quantizer index, the band z, a flag for t = 0, a flag for t = 1 and a flag for the last sample of the image. | 3.4, 5.4.1, 5.4.2.2.2 |
| PR-IF-04 | With periodic error limit updating the predictor shall read the error limit values (A\* or a_z for every band, then R\* or r_z for every band) at the start of every frame y with y mod 2^u = 0, use them for the frames of the update period and insert them into the entropy coder input sequence before the first sample of the frame. | 4.8.2.4, 5.4.2.2.2 |
| PR-IF-05 | The predictor shall signal with a pulse on `Img_Start` that it has accepted the first item (sample or error limit value) of an image. | none |

### 2.2 Local sums and local differences (PR-2)

| ID | Requirement | CCSDS |
| --- | --- | --- |
| PR-LS-01 | The predictor shall use P preceding bands for prediction, P from 0 to 15, and Pz* = min(z, P) in band z. | 4.2 |
| PR-LS-02 | The predictor shall implement full and reduced prediction mode. | 4.3 |
| PR-LS-03 | The predictor shall compute wide neighbor-oriented, narrow neighbor-oriented, wide column-oriented and narrow column-oriented local sums, including the cases at the image edges. | 4.4 |
| PR-LS-04 | The predictor shall compute the central local difference and, in full prediction mode, the three directional local differences, and form the local difference vector. | 4.5 |

### 2.3 Prediction (PR-3)

| ID | Requirement | CCSDS |
| --- | --- | --- |
| PR-PD-01 | The predictor shall represent weights with Omega + 3 bits for a weight resolution Omega from 4 to 19. | 4.6.1, 4.6.2 |
| PR-PD-02 | The predictor shall initialise the weights of every band with the default weight initialisation or with custom weight initialisation vectors of resolution Q from 3 to Omega + 3. | 4.6.3 |
| PR-PD-03 | The predictor shall compute the predicted central local difference, the high-resolution predicted sample value with register size R from max(32, D + Omega + 2) to 64, the double-resolution and the predicted sample value. | 4.7 |

### 2.4 Quantizer (PR-4)

| ID | Requirement | CCSDS |
| --- | --- | --- |
| PR-QU-01 | The predictor shall compute the prediction residual and the quantizer index with step size 2 m_z(t) + 1; the first sample of every band is not quantized. | 4.8.1 |
| PR-QU-02 | The predictor shall compute the maximum error for lossless, absolute error limit only, relative error limit only and both absolute and relative error limits. | 4.8.2.1 |
| PR-QU-03 | The predictor shall accept absolute and relative error limits of 1 to 16 bits, band-independent or band-dependent. | 4.8.2.2, 4.8.2.3 |

### 2.5 Sample representatives and weight update (PR-5)

| ID | Requirement | CCSDS |
| --- | --- | --- |
| PR-SR-01 | The predictor shall compute the clipped bin center and the sample representative with resolution Theta from 0 to 4 and per-band damping and offset values. | 4.9 |
| PR-WU-01 | The predictor shall compute the double-resolution prediction error and the weight update scaling exponent with the parameters vmin, vmax and tinc. | 4.10.1, 4.10.2 |
| PR-WU-02 | The predictor shall update the weights after every sample with t > 0, with intra-band and inter-band weight exponent offsets from -6 to 5. | 4.10.3, 4.10.4 |

### 2.6 Mapper (PR-6)

| ID | Requirement | CCSDS |
| --- | --- | --- |
| PR-MP-01 | The predictor shall map every quantizer index to the mapped quantizer index. | 4.11 |

### 2.7 Throughput

| ID | Requirement | CCSDS |
| --- | --- | --- |
| PR-TP-01 | The predictor shall start a sample in the first clock cycle in which the samples it depends on (the previous sample of its band; in near-lossless compression, or when the local differences of the previous bands come from memory, the sample of the previous band at the same pixel) have left the feedback loops and the output has room for every item in flight; it shall then process one sample per clock cycle (throughput model `tools/ocp_throughput.py`). | none |
| PR-TP-02 | When consecutive samples belong to the same band (BSQ order, BI order with M = 1) and C <= 3, the predictor shall continue the weight update of the band from one sample to the next without waiting (speculative weight loop, `Speculation_g`) in lossless compression and in near-lossless compression with absolute error limits, narrow local sums and reduced prediction. | none |
| PR-TP-03 | In BI order with M = NZ and near-lossless compression with dependencies between the bands of a pixel (P > 0 or narrow local sums), without periodic error limit updating, the predictor shall process the samples of an image in stride order (`Stride_g`) and output the entropy coder input sequence in the input order. | 5.4.2.2 |

### 2.8 Fault tolerance

| ID | Requirement | CCSDS |
| --- | --- | --- |
| PR-FT-01 | Sample representatives, local differences, weights and band-dependent periodic error limits shall be stored in memories with SECDED ECC; corrected single and detected double errors shall be signalled on `Ecc_Sec` and `Ecc_Ded`. | none |
| PR-FT-02 | The predictor shall inject a single or a double bit error into the next word written into its memory selected by `ErrInj_Channel` (channels 0 to 11). | none |

## 3. Configuration parameters

| Generic | Default | Range | Description |
| --- | --- | --- | --- |
| `XSize_g`, `YSize_g`, `ZSize_g` | 8, 8, 4 | 1 to 65536 | NX, NY, NZ |
| `DynamicRange_g` | 16 | 2 to 32 | D |
| `SignedSamples_g` | false | | Signed samples |
| `EncodingOrder_g` | "BI" | "BI", "BSQ" | Input order |
| `SubFrameDepth_g` | 4 | 1 to NZ | M (BI order) |
| `PredictionBands_g` | 3 | 0 to 15 | P |
| `PredictionMode_g` | "FULL" | "FULL", "REDUCED" | Prediction mode |
| `LocalSum_g` | "WIDE_NEIGHBOR" | "WIDE_NEIGHBOR", "NARROW_NEIGHBOR", "WIDE_COLUMN", "NARROW_COLUMN" | Local sum type |
| `RegisterSize_g` | 64 | max(32, D + Omega + 2) to 64 | R |
| `WeightResolution_g` | 13 | 4 to 19 | Omega |
| `WeightUpdateInterval_g` | 6 | 4 to 11 | log2(tinc) |
| `WeightUpdateVmin_g`, `WeightUpdateVmax_g` | -1, 3 | -6 to 9 | vmin, vmax |
| `WeightExpOffsetsUsed_g`, `WeightExpOffsets_g` | false, (0) | -6 to 5 | Weight exponent offsets: per band the intra-band offset (full mode), then Pz* inter-band offsets |
| `CustomWeights_g`, `WeightInitResolution_g`, `WeightInitValues_g` | false, 0, (0) | Q: 3 to Omega + 3 | Custom weight initialisation: per band Cz values of Q bits |
| `Fidelity_g` | "LOSSLESS" | "LOSSLESS", "ABSOLUTE", "RELATIVE", "ABSOLUTE_RELATIVE" | Quantizer fidelity control method |
| `PeriodicUpdate_g`, `UpdatePeriodExp_g` | false, 0 | u: 0 to 9 | Periodic error limit updating (BI order) |
| `AbsBandDependent_g`, `AbsErrorLimits_g` | false, (0) | | Absolute error limits (fixed limits) |
| `RelBandDependent_g`, `RelErrorLimits_g` | false, (0) | | Relative error limits (fixed limits) |
| `SampleRepResolution_g`, `Damping_g`, `Offset_g` | 0, (0), (0) | Theta: 0 to 4 | Sample representatives |
| `Speculation_g` | true | | Speculative weight loop where it applies (PR-TP-02) |
| `Stride_g` | true | | Stride order where it applies (PR-TP-03) |
| `RamStyle_g` | "auto" | | Memory implementation (Open Logic) |

Per-band tables are `integer_vector` generics; the last element repeats for the remaining bands.

## 4. Interpretation of the standard

| Clause | Interpretation |
| --- | --- |
| 4.6.3.3.3 | The low bits of an initial weight with Q < Omega + 3 are a '0' followed by '1' bits (the note of the clause); with Q = Omega + 3 the weight equals the initialisation value. |
| 4.7.3 | At t = 0 the double-resolution predicted sample value of band z > 0 (P > 0) is twice the sample of band z - 1 at t = 0, which equals its sample representative (4.9.2, t = 0). |
| 4.10.3 | The increment floor((sgn+(e) 2^-(rho + zeta) d + 1) / 2) is computed exactly for both signs of the exponent; an increment outside the weight range is saturated before the clipping of the weight, which gives the same weight. |
| 4.8.2.4 | The error limit values are 16-bit values on the `Lim` stream; only the DA or DR least significant bits are used, as in the header. |

## 5. Integration constraints

| Constraint | Reason |
| --- | --- |
| Periodic error limit updating needs BI order | CCSDS 4.8.2.4.4 |
| An image of width 1 needs reduced prediction and column-oriented local sums | CCSDS 4.3.1, 4.4.1; checked by an assertion during elaboration |
