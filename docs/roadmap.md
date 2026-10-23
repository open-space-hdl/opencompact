# OpenCompact Roadmap

The development follows the plan of the [architecture](architecture.md) (section 11). This page tracks the state of
every module; a module is done when its verification report is written and its regression is green.

## Technology readiness

The core is at **TRL 3**: fully verified by simulation. It compresses the test images of 38 configurations, which
cover every option of CCSDS 123.0-B-2, and of 24 random configurations identically to the CNES reference software, in
GHDL and in QuestaSim, at up to one sample per clock cycle, and reproduces the compressed images of 300 vectors of the
CCSDS test data set. Unit testbenches verify the predictor, the entropy coders and the bit packer; error injection
reaches every memory; resets at random times are followed by correct images; images with an early or a missing
image end marker are flagged and followed by correct images (image framing); code coverage is closed or justified
([coverage](coverage.md)). The core is not tested on hardware and has no flight heritage. The
[TRL page](https://openspacehdl.org/trl/) explains what the levels mean for an IP core.

| Next level | What is needed | State |
| --- | --- | --- |
| TRL 4 | Synthesis with timing closure on a target FPGA and a hardware test with images compressed on the FPGA and decompressed by the CNES reference software; hardware test plan and report | Open: synthesis, place and route at 100 MHz on PolarFire for eleven configurations ([user guide](user_guide.md#8-resources-and-performance)); hardware test open |
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
| Run-time configuration | Image dimensions and band-independent error limit values per image (`RuntimeConfig_g`, registers of `ocp_mib`; [user guide](user_guide.md#44-runtime-configuration)). Open: the other parameters and the per-band tables at run time; investigate a stride order for runtime dimensions (with the runtime configuration the predictor does not use the stride order, so near-lossless BIP configurations run at the pipeline rate) |
| External memory for large images in BSQ order | Open: BSQ order keeps the local differences of a band in an internal memory of NX NY words |
| Products of wide operands | Open: with D = 32 and Omega >= 16 the products of the predictor need a cascade of four math blocks in one clock cycle (81 MHz on PolarFire); a second product stage for such widths |
| Synthesis and timing on a radiation-tolerant target (RTG4, RT PolarFire, NG-Ultra, Versal XQR) | Open; on PolarFire every measured configuration except one with D = 32 reaches 100 MHz after place and route ([user guide](user_guide.md#8-resources-and-performance)) |
