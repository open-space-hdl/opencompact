# ocp_core: Specification

## 1. Overview

`ocp_core` is the top level of OpenCompact: the header generator (CO-1, `ocp_header`), the predictor
(`ocp_predictor`), the entropy coder selected by `EntropyCoder_g` (`ocp_entropy_coder`), the bit packer (CO-2,
`ocp_bit_packer`) and the image sequencer (CO-3). It compresses images according to CCSDS 123.0-B-2 with all options of
the standard set by generics and outputs every compressed image as a byte stream.

## 2. Requirements

### 2.1 Interfaces

| ID | Requirement | CCSDS |
| --- | --- | --- |
| CO-IF-01 | The core shall take the samples of an image in the input order (BI or BSQ) on a valid / ready stream of D-bit samples and, with periodic error limit updating, the error limit values on a valid / ready stream of 16-bit values. | 5.4.2 |
| CO-IF-02 | The core shall output every compressed image as a valid / ready byte stream, first byte of the compressed image first, with a marker on the last byte. | 5.2.1 |
| CO-IF-03 | The core shall signal corrected single and detected double memory errors of all its memories on `Ecc_Sec` and `Ecc_Ded`. | none |

### 2.2 Header generator (CO-1)

| ID | Requirement | CCSDS |
| --- | --- | --- |
| CO-HD-01 | The header shall consist of the image metadata, the predictor metadata and the entropy coder metadata, each an integer number of bytes, with all fill bits and reserved fields zero. | 5.3.1 |
| CO-HD-02 | The image metadata shall contain the essential subpart with the user-defined data, the image dimensions, the sample type, the dynamic range, the sample encoding order and sub-frame interleaving depth, the output word size, the entropy coder type, the quantizer fidelity control method and the number of supplementary information tables. | 5.3.2.1, 5.3.2.2 |
| CO-HD-03 | The image metadata shall contain up to 15 supplementary information tables as encoded by the user. | 3.5, 5.3.2.3 |
| CO-HD-04 | The predictor metadata shall contain the primary subpart and, when selected, the weight initialisation table and the weight exponent offset table. | 5.3.3.1, 5.3.3.2, 5.3.3.3 |
| CO-HD-05 | The predictor metadata shall contain the quantization subpart (error limit update period, absolute and relative error limit blocks with their values unless updated periodically) except in lossless compression. | 5.3.3.4 |
| CO-HD-06 | The predictor metadata shall contain the sample representative subpart with the damping and offset tables when selected. | 5.3.3.5 |
| CO-HD-07 | The entropy coder metadata shall have the structure of the selected coder, with the accumulator initialisation table of the sample-adaptive coder when selected. | 5.3.4 |

### 2.3 Bit packer (CO-2) and image sequencer (CO-3)

| ID | Requirement | CCSDS |
| --- | --- | --- |
| CO-PK-01 | The compressed image shall be the header followed by the body. | 5.2.1 |
| CO-PK-02 | After the last codeword of the body, fill bits (zeros) shall be appended up to the next output word boundary so that the size of the compressed image is a multiple of the output word size B, from 1 to 8 bytes. | 5.2.2, 5.4.3.2.4.4, 5.4.3.3.5.4.5, 5.4.3.4.3.2 |
| CO-PK-03 | Images shall be compressed one after the other; every image shall start with the initial state of the standard and with its own header. | 5.2.1 |

## 3. Configuration parameters

All parameters of the standard are generics; the user guide lists them with their header fields. Generics that the
predictor or the entropy coders use are described in their specifications. Generics used by `ocp_core` only:

| Generic | Default | Range | Description |
| --- | --- | --- | --- |
| `UserData_g` | 0 | 0 to 255 | User-defined data field of the header |
| `OutputWordSize_g` | 1 | 1 to 8 | B |
| `EntropyCoder_g` | "SAMPLE_ADAPTIVE" | "SAMPLE_ADAPTIVE", "HYBRID", "BLOCK_ADAPTIVE" | Entropy coder |
| `SupTableCount_g`, `SupTableData_g` | 0, x"00" | 0 to 15 | Number of supplementary information tables and the encoded Supplementary Information Tables subpart (byte-aligned) |
| `WeightExpOffsetTable_g`, `WeightInitTable_g` | false | | Weight exponent offset table and weight initialisation table in the header |
| `AbsBitDepth_g`, `RelBitDepth_g` | 1 | 1 to min(D - 1, 16) | DA, DR |
| `DampingBandVarying_g`, `DampingTable_g`, `OffsetBandVarying_g`, `OffsetTable_g` | false | | Sample representative subpart flags |
| `AccuInitTable_g` | false | | Accumulator initialisation table in the header |

## 4. Interpretation of the standard

| Clause | Interpretation |
| --- | --- |
| 5.2.2 | The size of the compressed image (header and body) is a multiple of B; the header itself need not be (CCSDS 5.3.1.1 note 2). |
| 5.3.3.3 | A table that is not included in the header (table flag false) is not output; the decompressor must know it (CCSDS 5.3.3.3.2.1 note). |
| 2.4 | The end of a compressed image is the last byte marker of the output stream; the transport of the image to the decompressor is the task of the user. |

## 5. Integration constraints

| Constraint | Reason |
| --- | --- |
| The header of an image is output when its first sample (or error limit value) arrives | Consecutive images on one stream; no header without image |
| The last codeword of the body is never empty | The bit packer marks the last byte when it outputs the bits of the last codeword |
