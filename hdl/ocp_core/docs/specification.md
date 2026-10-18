# ocp_core: Specification

## 1. Overview

`ocp_core` is the top level of OpenCompact: the header generator (CO-1, `ocp_header`), the predictor
(`ocp_predictor`), the entropy coder selected by `EntropyCoder_g` (`ocp_entropy_coder`), the bit packer (CO-2,
`ocp_bit_packer`), the image sequencer (CO-3) and, with `UseInLast_g`, the image framer (CO-4, `ocp_image_framer`). It
compresses images according to CCSDS 123.0-B-2 with all options of the standard set by generics and outputs every
compressed image as a stream of words of 8 to 64 bits.

## 2. Requirements

### 2.1 Interfaces

| ID | Requirement | CCSDS |
| --- | --- | --- |
| CO-IF-01 | The core shall take the samples of an image in the input order (BI or BSQ) on a valid / ready stream of D-bit samples and, with periodic error limit updating, the error limit values on a valid / ready stream of 16-bit values. | 5.4.2 |
| CO-IF-02 | The core shall output every compressed image as a valid / ready stream of words of `OutWidth_g` bits (8, 16, 32 or 64) in which byte n of a word occupies bits 8n + 7 to 8n (the first byte of the compressed image in bits 7 to 0 of the first word) and the first bit of every byte is its most significant bit, with a marker on the last word of the image and its valid bytes, contiguous from byte 0. | 5.2.1 |
| CO-IF-03 | The core shall signal corrected single and detected double memory errors of all its memories on `Ecc_Sec` and `Ecc_Ded`. | none |
| CO-IF-04 | The core shall inject a single or a double bit error into the next word written into the memory selected by `ErrInj_Channel` (channels 0 to 13). | none |

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
| CO-TP-01 | The bit packer shall take one codeword (or header part) per clock cycle while the compressed image needs on average at most `OutWidth_g` bits per clock cycle, so that the core takes the samples of consecutive images in the cycles of the predictor. | none |

### 2.4 Image framer (CO-4)

| ID | Requirement | CCSDS |
| --- | --- | --- |
| CO-FR-01 | With `UseInLast_g` false the core shall ignore `In_Last` and `In_Error`, compress every NX NY NZ samples as one image and keep `Out_Error` and `Ev_ImageError` at '0'. | none |
| CO-FR-02 | With `UseInLast_g` true the core shall expect `In_Last` = '1' with the last sample of every image (sample NX NY NZ of the image in the input order) and `In_Last` = '0' with every other sample. | 5.4.2 |
| CO-FR-03 | When a sample before the last sample of an image comes with `In_Last` = '1', the core shall take it and end the image with it (an aborted image): the compressed image shall be the header of the complete image followed by the body of the samples taken, the `In_Last` sample included, and of the error limit values taken for them, with the end of the image of the selected entropy coder after the codeword of the last sample taken and fill bits up to a multiple of B bytes. The compressed images before it shall not change, and the next sample shall be the first sample of a new image with its own header. | 5.2.2, 5.4.3.3.5.4, 5.4.3.4 |
| CO-FR-04 | When the last sample of an image comes with `In_Last` = '0', the core shall complete the compressed image, then take and discard every following sample up to and including the next sample with `In_Last` = '1', one per clock cycle; the sample after it shall be the first sample of a new image. | none |
| CO-FR-05 | `Out_Error` shall be '1' with the last word of a compressed image that was aborted (CO-FR-03), whose last sample came without `In_Last` (CO-FR-04) or that ended with `In_Error` (CO-FR-08), and '0' with every other word. | none |
| CO-FR-06 | The core shall pulse `Ev_ImageError` for one clock cycle for every image with an early or a missing `In_Last` or ended with `In_Error`. | none |
| CO-FR-07 | After the sample with an early `In_Last` the core shall take no error limit value for three clock cycles, and after a last sample without `In_Last` none until the sample with `In_Last` of CO-FR-04; the next value it takes belongs to the first frame of the next image. | 4.8.2.4 |
| CO-FR-09 | The bytes of an aborted image shall not depend on the timing of the input and of the output (gaps of the samples, `Out_Ready`) or on the image before it. | none |
| CO-FR-08 | With `UseInLast_g` true, `In_Error` = '1' together with `In_Last` = '1' shall end the image with an error: with the last sample of the image the compressed image shall be complete and identical to the compressed image without `In_Error`, and the next sample shall be the first sample of a new image; before the last sample the image shall be aborted as in CO-FR-03. `In_Error` shall be ignored with `In_Last` = '0' and while samples are discarded (CO-FR-04). | none |

### 2.5 Reset

| ID | Requirement | CCSDS |
| --- | --- | --- |
| CO-RS-01 | A reset at any time shall abort the image in progress; the core shall compress the next image from the initial state of the standard, without initialisation of its memories. | none |

### 2.6 Configuration checks

| ID | Requirement | CCSDS |
| --- | --- | --- |
| CO-CF-01 | In BI order the elaboration shall stop when `SubFrameDepth_g` exceeds `ZSize_g`. | 5.4.2.2.1 |
| CO-CF-02 | With the block-adaptive coder the elaboration shall stop when `BlockSize_g` is not 8, 16, 32 or 64, or when `RestrictedCodes_g` is true with D above 4. | 5.3.4.4, 5.4.3.4.2.4, 5.4.3.4.2.6 |
| CO-CF-03 | With the sample-adaptive or the hybrid coder the elaboration shall stop when `RescaleCounterSize_g` is below max(4, `InitialCountExp_g` + 1); with the sample-adaptive coder also when an accumulator initialisation value in use (`AccuInit_g`) is outside 0 to min(D - 2, 14). | 5.4.3.2.3.3, 5.4.3.2.3.4, 5.4.3.3.4.5 |

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
| `OutWidth_g` | 8 | 8, 16, 32, 64 | Width of the compressed image interface in bits |
| `Speculation_g` | true | | Speculative weight loop of the predictor where it applies (PR-TP-02); the stride order of the predictor (PR-TP-03) is always used where it applies |
| `UseInLast_g` | false | | Image framing with `In_Last`, `Out_Error` and `Ev_ImageError` (CO-4) |

## 4. Interpretation of the standard

| Clause | Interpretation |
| --- | --- |
| 5.2.2 | The size of the compressed image (header and body) is a multiple of B; the header itself need not be (CCSDS 5.3.1.1 note 2). |
| 5.3.3.3 | A table that is not included in the header (table flag false) is not output; the decompressor must know it (CCSDS 5.3.3.3.2.1 note). |
| 2.4 | The end of a compressed image is the last byte marker of the output stream; the transport of the image to the decompressor is the task of the user. |
| 5.2.1, 5.2.2 | An aborted image (CO-FR-03) is the compressed image of the samples taken; a decoder that is given the number of samples taken (L + 1, with L the index of the sample with the early `In_Last` in the input order of the image, counted from 0) decodes it; the header announces the complete image (NX NY NZ samples), so a decoder that relies on the header alone expects the codewords of all samples and does not decode it. Its size is a multiple of B, so the next compressed image starts at an output word boundary of the stream as after a complete image. |
| 1.6.3 | The standard numbers the bits of a word from the first transmitted bit, which is the most significant bit, and groups them into bytes; it does not define how bytes are placed in a wider interface word. The core keeps the bit order within every byte and places the bytes in increasing order of their position in the interface word: byte n in bits 8n + 7 to 8n. A byte stream written into memory over a byte-addressed bus, or converted to another width with the Open Logic width converters, then keeps the order of the compressed image. |

## 5. Integration constraints

| Constraint | Reason |
| --- | --- |
| The header of an image is output once its first sample (or error limit value) is accepted | Consecutive images on one stream; no header without image |
| The last codeword of the body is never empty | The bit packer marks the last word when it outputs the bits of the last codeword |
| With `UseInLast_g` true, `In_Last` accompanies the last sample of every image | Otherwise every image is flagged with `Out_Error` and the samples up to the next `In_Last` are discarded (CO-FR-04) |
| A source that learns only at the end of a group of samples that the group is faulty (for example a packet with a memory error) sets `In_Last` and `In_Error` with its last sample | The image ends there and is flagged even when its sample count is complete (CO-FR-08) |
| A source of error limit values that delivers them ahead of the request drops the remaining values of an aborted image within two clock cycles of `Ev_ImageError` and continues with the values of the next image | The core takes no value for three clock cycles after an early `In_Last` and then the values of the next image (CO-FR-07) |
