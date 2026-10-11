# OpenCompact Roadmap

The development follows the plan of the [architecture](architecture.md) (section 11). This page tracks the state of
every module; a module is done when its verification report is written and its regression is green.

## Technology readiness

The core is at **TRL 2**: a demonstrator in development with first performance estimates. It compresses the test
images of 30 configurations, which cover every option of CCSDS 123.0-B-2, identically to the CNES reference software,
at up to one sample per clock cycle; it is not yet fully verified by simulation, not tested on hardware and has no
flight heritage. The [TRL page](https://openspacehdl.org/trl/) explains what the levels mean for an IP core.

| Next level | What is needed | State |
| --- | --- | --- |
| TRL 3 | Full verification by simulation: unit testbenches of the entropy coders, the header generator and the bit packer; error injection into every memory through the `ErrInj` ports of the FT memories; random configurations (for example the CCSDS test data set run on the core); closed code coverage; recovery of the state machines | Open (see the open items) |
| TRL 4 | Synthesis with timing closure on a target FPGA and a hardware test with images compressed on the FPGA and decompressed by the CNES reference software; hardware test plan and report | Open |
| TRL 5 | Single-event effects test (beam test) on a radiation-tolerant FPGA with the core in operation | Open |

## Modules

| Module | Blocks (architecture section 7) | Status |
| --- | --- | --- |
| `ocp_pkg` | PK-1, PK-2 (common definitions, low-entropy code tables) | Demonstrator |
| `ocp_predictor` | PR-1 to PR-6 (predictor, quantizer, mapper) | Demonstrator: unit testbench against the reference model |
| `ocp_entropy_coder` | EC-1 to EC-3 (sample-adaptive, hybrid, block-adaptive coder) | Demonstrator: verified in the core testbench |
| `ocp_core` | CO-1 to CO-3 (header, bit packer, image sequencing) | Demonstrator: core testbench against the CNES reference software |

## Open items

| Item | State |
| --- | --- |
| Throughput | One sample per clock cycle in BI order with enough bands, with the speculative weight loop (BSQ, BIL; C <= 3) and in stride order (BIP, near-lossless); the entropy coders take one item per cycle ([user guide](user_guide.md#7-resources-and-performance)). Open: BIL input with encoding in BI order with several bands (a buffer of some lines) for configurations with more than three local differences; more than one sample per clock cycle (several datapaths for the bands of a pixel, or several cores on parts of an image) |
| Error injection into the memories | Open: the FT memories have error injection ports that the core does not yet expose |
| Unit testbenches of the entropy coders, header generator and bit packer | Open: verified through the core testbench only |
| QuestaSim regression and code coverage | Regression passes in QuestaSim; coverage measured, not closed ([coverage.md](coverage.md)) |
| Run-time configuration | Open: all parameters are generics; a register interface for the image size, the error limits and the tables would allow one bitstream for several instrument modes |
| External memory for large images in BSQ order | Open: BSQ order keeps the local differences of a band in an internal memory of NX NY words |
| Products of wide operands | Open: with D = 32 and Omega >= 16 the products of the predictor need a cascade of four math blocks in one clock cycle (80 MHz on PolarFire); a second product stage for such widths |
| Synthesis and timing on a radiation-tolerant target (RTG4, RT PolarFire, NG-Ultra, Versal XQR) | Open; on PolarFire every measured configuration except one with D = 32 reaches 100 MHz after place and route ([user guide](user_guide.md#7-resources-and-performance)) |
