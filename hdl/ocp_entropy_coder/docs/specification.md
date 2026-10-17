# ocp_entropy_coder: Specification

## 1. Overview

The module contains the three entropy coders of CCSDS 123.0-B-2 (5.4.3): `ocp_sample_adaptive_coder` (EC-1),
`ocp_hybrid_coder` (EC-2) and `ocp_block_adaptive_coder` (EC-3). Each takes the entropy coder input sequence of the
predictor and produces the codewords of the compressed image body; `ocp_core` instantiates the coder selected by
`EntropyCoder_g`. The fill bits at the end of the body are added by the bit packer of `ocp_core`.

## 2. Requirements

### 2.1 Common

| ID | Requirement | CCSDS |
| --- | --- | --- |
| EC-IF-01 | Every coder shall take the entropy coder input sequence (value, kind, band, t = 0, t = 1, last item) and output codewords of up to 96 bits with their length, and mark the last codeword of the image. | 5.4.1 |
| EC-TP-01 | The sample-adaptive and the hybrid coder shall take one item per clock cycle while their output buffer has room; the block-adaptive coder one value per clock cycle while a block buffer is free; every coder shall concatenate consecutive codewords into codewords of up to 96 bits before its output buffer. | none |
| EC-IF-02 | The sample-adaptive and the hybrid coder shall encode every error limit value of periodic error limit updating as a DA-bit (absolute) or DR-bit (relative) unsigned integer without changing their statistics. | 5.4.3.2.4.1, 5.4.3.3.5.1.1 |

### 2.2 Sample-adaptive coder (EC-1)

| ID | Requirement | CCSDS |
| --- | --- | --- |
| EC-SA-01 | The coder shall encode with length-limited GPO2 codewords with a unary length limit Umax from 8 to 32. | 5.4.3.2.2 |
| EC-SA-02 | The coder shall keep an accumulator and a counter per band, initialised with the initial count exponent gamma0 from 1 to 8 and the accumulator initialisation constant K or the band-dependent values k''_z, and rescaled with the rescaling counter size gamma* from max(4, gamma0 + 1) to 11. | 5.4.3.2.3 |
| EC-SA-03 | The coder shall output the first mapped quantizer index of every band uncoded and select the code index of every other index from the statistics. | 5.4.3.2.4.2, 5.4.3.2.4.3 |

### 2.3 Hybrid coder (EC-2)

| ID | Requirement | CCSDS |
| --- | --- | --- |
| EC-HY-01 | The coder shall keep a high-resolution accumulator and a counter per band, initialised with gamma0 and the user-specified initial accumulator values, and output the least significant bit of the accumulator before the codewords of an index whenever the statistics are rescaled. | 5.4.3.3.4, 5.4.3.3.5.1.2 |
| EC-HY-02 | The coder shall output the first mapped quantizer index of every band uncoded and encode every other high-entropy index with a reversed length-limited GPO2 codeword. | 5.4.3.3.3.2, 5.4.3.3.5.1.3, 5.4.3.3.5.1.4, 5.4.3.3.5.2 |
| EC-HY-03 | The coder shall encode every low-entropy index with the low-entropy code selected by the statistics: escape symbol with a reversed GPO2 codeword of the residual, active prefix, output codeword of a complete input codeword. | 5.4.3.3.3.3, 5.4.3.3.5.3 |
| EC-HY-04 | After the last index the coder shall output the compressed image tail: the flush word of every low-entropy code, the final accumulator of every band and a '1' bit; the final accumulator of a band whose statistics were not initialised in the image (no index with t = 1, for example in an image that ended early) shall be its initial accumulator. | 5.4.3.3.5.4 |

### 2.4 Block-adaptive coder (EC-3)

| ID | Requirement | CCSDS |
| --- | --- | --- |
| EC-BA-01 | The coder shall encode the entropy coder input sequence, including the error limit values, with the adaptive entropy coder of CCSDS 121.0-B-3 without preprocessor, resolution n = D, block size J of 8, 16, 32 or 64, reference sample interval r from 1 to 4096 and the basic or, for D up to 4, the restricted set of code options. | 5.4.3.4.1, 5.4.3.4.2 |
| EC-BA-02 | The coder shall append zeros to the input sequence up to a multiple of J. | 5.4.3.4.2.7 |
| EC-BA-03 | The coder shall encode every block with the shortest of the no-compression, second-extension, fundamental sequence and split-sample options (ties: no compression, then second extension, then the smallest k, CCSDS 121.0-B-3 section 3.7), and every run of all-zeros blocks inside a 64-block segment of a reference sample interval with the zero-block option, using the remainder-of-segment codeword for five or more blocks at the end of a segment (CCSDS 121.0-B-3 section 3.5). The body is the concatenation of the coded data sets. | 5.4.3.4.3.1 |

### 2.5 Fault tolerance

| ID | Requirement | CCSDS |
| --- | --- | --- |
| EC-FT-01 | The statistics of the sample-adaptive and the hybrid coder and the codeword buffers of all coders shall be stored in memories with SECDED ECC; corrected single and detected double errors shall be signalled on `Ecc_Sec` and `Ecc_Ded`. | none |
| EC-FT-02 | Every coder shall inject a single or a double bit error into the next word written into its statistics memory (`ErrInj_Stats`) or its codeword buffer (`ErrInj_Buffer`). The block buffers of the block-adaptive coder are registers. | none |

## 3. Configuration parameters

| Generic | Coder | Range | Description |
| --- | --- | --- | --- |
| `ZSize_g`, `DynamicRange_g` | all | 1 to 65536, 2 to 32 | NZ, D |
| `UnaryLimit_g` | EC-1, EC-2 | 8 to 32 | Umax |
| `RescaleCounterSize_g`, `InitialCountExp_g` | EC-1, EC-2 | 4 to 11, 1 to 8 | gamma*, gamma0 |
| `AccuInitBandVarying_g`, `AccuInit_g` | EC-1 | 0 to min(D - 2, 14) | K (first element) or k''_z per band |
| `HybridAccuInit_g` | EC-2 | 0 to 2^(D + gamma0) - 1 | Initial high-resolution accumulator per band |
| `AbsBitDepth_g`, `RelBitDepth_g` | EC-1, EC-2 | 1 to 16 | DA, DR |
| `BlockSize_g`, `RestrictedCodes_g`, `RefInterval_g` | EC-3 | 8, 16, 32, 64; D <= 4; 1 to 4096 | J, restricted code options, r |
| `XSize_g`, `YSize_g` | EC-2 | | Image of one pixel per band: the final accumulators are the initial ones |

## 4. Interpretation of the standard

| Clause | Interpretation |
| --- | --- |
| 5.4.3.3.4.4 | The counter Gamma(t) is the same for all bands; the coder keeps it per band together with the accumulator. |
| 5.4.3.3.5.1.2 | The bit output at a rescaling is the least significant bit of the accumulator before the update, which equals the bit lost by the halving of the accumulator plus 4 delta. |
| 5.4.3.4.2.7 | The zeros appended to the input sequence are part of the last block and of its zero-block runs. |

## 5. Integration constraints

| Constraint | Reason |
| --- | --- |
| `HybridAccuInit_g` values are VHDL integers: initial accumulators of 2^31 and more cannot be given | Range of `integer_vector`; affects D + gamma0 > 31 only |
