# OpenCompact Roadmap

The development follows the plan of the [architecture](architecture.md) (section 11). This page tracks the state of
every module; a module is done when its verification report is written and its regression is green.

## Technology readiness

The core is at **TRL 3**: fully verified by simulation. It compresses the test images of 38 configurations, which
cover every option of CCSDS 123.0-B-2, and of 24 random configurations identically to the CNES reference software, in
GHDL and in QuestaSim, at up to one sample per clock cycle, and reproduces the compressed images of 300 vectors of the
CCSDS test data set. Unit testbenches verify the predictor, the entropy coders and the bit packer; error injection
reaches every memory; resets at random times are followed by correct images; images with an early or a missing
image end marker are flagged and followed by correct images (image framing); with the runtime configuration and the
runtime parameters, sequences of images with their own dimensions, error limit values and parameters equal the
reference model; code coverage is closed or justified ([coverage](coverage.md)). The core is not tested on hardware
and has no flight heritage. The
[TRL page](https://openspacehdl.org/trl/) explains what the levels mean for an IP core.

| Next level | What is needed | State |
| --- | --- | --- |
| TRL 4 | Hardware test of a reference system of the family that contains the core (spfi_compress on the VCK190 is the first): synthesis with timing closure of the system; images compressed by the core on the FPGA equal to the compressed images of the reference model (`tools/ocp_model.py`) and, as a step of the system test, decompressed by the decoder of the reference model, validated against the CNES reference software, and compared with the input images (identical when lossless, within the error limits when near-lossless); hardware test plan and report of the system | Open: the first hardware test is spfi_compress with this version and OpenFibre 0.1.4; synthesis, place and route of the core alone at 100 MHz on PolarFire for eleven configurations ([user guide](user_guide.md#8-resources-and-performance)) |
| TRL 5 | Single-event effects test (beam test) on a radiation-tolerant FPGA with the core in operation | Open |

## Modules

| Module | Blocks (architecture section 7) | Status |
| --- | --- | --- |
| `ocp_pkg` | PK-1, PK-2 (common definitions, low-entropy code tables) | Verified: tables checked against the standard, used by all testbenches |
| `ocp_predictor` | PR-1 to PR-6 (predictor, quantizer, mapper) | Verified: unit testbench against the reference model and the throughput model |
| `ocp_entropy_coder` | EC-1 to EC-3 (sample-adaptive, hybrid, block-adaptive coder) | Verified: unit testbench and core testbench against the CNES reference software |
| `ocp_core` | CO-1 to CO-4 (header, bit packer, image sequencing, image framing) | Verified: core testbench against the CNES reference software and the CCSDS test data set, error injection, resets, early and missing image end markers; unit testbench of the bit packer |

## Open items

| Item | State |
| --- | --- |
| Throughput | One sample per clock cycle in BI order with enough bands, with the speculative weight loop (BSQ, BIL; C <= 3) and in stride order (BIP, near-lossless); the entropy coders take one item per cycle ([user guide](user_guide.md#8-resources-and-performance)). Open: BIL input with encoding in BI order with several bands (a buffer of some lines) for configurations with more than three local differences; more than one sample per clock cycle (several datapaths for the bands of a pixel, or several cores on parts of an image) |
| CCSDS test data set in CI | The data set carries no licence statement and is not part of the repository; `tools/ocp_testvectors.py` prepares a selection locally and the regression runs it with `OCP_TESTVECTORS` |
| Scrubbing of the memories | The memories correct single errors on every read; an upset in a word that is not read again in the image is overwritten by the next image. Scrubbing of the memories during an image is open |
| Run-time configuration | Image dimensions and band-independent error limit values per image (`RuntimeConfig_g`, registers of `ocp_mib`; [user guide](user_guide.md#44-runtime-configuration)) and the scalar parameters per image (`RuntimeParams_g`: user-defined data, M, the weight update and the entropy coder parameters). Open: the per-band tables at run time with table memories and a header serializer (error limits, damping, offset, accumulator initialisation, weight initialisation and exponent offsets); candidates for that step: periodic error limit updating with the runtime configuration, supplementary information tables, the initial accumulators of the hybrid coder taken from the final accumulators of the image before. Investigate a stride order for runtime dimensions (with the runtime configuration the predictor does not use the stride order, so near-lossless BIP configurations run at the pipeline rate) |
| External memory for large images in BSQ order | Open: BSQ order keeps the local differences of a band in an internal memory of NX NY words |
| Predictor at the widest generic corner | Open: c11 of `tools/ocp_configs.py` (D = 32, Omega = 19, P = 15, R = 64) needs 81160 LUTs on PolarFire, 72549 of them in the predictor, and reaches 75 MHz after place and route ([user guide](user_guide.md#82-resources)); area and clock frequency of the predictor for this corner |
| Synthesis and timing on a radiation-tolerant target (RTG4, RT PolarFire, NG-Ultra, Versal XQR) | Open; on PolarFire every measured configuration except one with D = 32 reaches 100 MHz after place and route ([user guide](user_guide.md#8-resources-and-performance)) |
