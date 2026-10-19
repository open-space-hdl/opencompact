# ocp_entropy_coder: Verification Report

## 1. Test results

Run on 2026-10-18 with GHDL (mcode, in the CI of the repository), VUnit 5.0.0.dev7, UVVM (commit 4f1e13b), Open Logic
4.7.0-ft.6: `python run.py "*ocp_entropy_coder*"`; the coders are also part of every test of `ocp_core_tb` ([ocp_core
verification report](../../ocp_core/docs/verification_report.md)). The same tests pass in QuestaSim (Questa Pro
Microchip Edition 2024.3, time resolution 1 fs, 2026-10-19), with code coverage and in the optimised run without it; the
code coverage is in [coverage.md](../../../docs/coverage.md). The tests of the CCSDS test data set ran in GHDL 6.0.0 on
2026-10-18 (`OCP_TESTVECTORS`, selection of `tools/ocp_testvectors.py`).

| Testbench | Tests | Passed |
| --- | --- | --- |
| `ocp_entropy_coder_tb` | 64 (62 configurations: 25 sample-adaptive, 17 hybrid, 20 block-adaptive, every second with back pressure; 2 hybrid configurations also with strong sink stalls) | 64 |
| `ocp_entropy_coder_tb` with the CCSDS test data set | 300 (99 sample-adaptive, 54 hybrid, 147 block-adaptive; every second with back pressure) | 300 |

## 2. Summary

The bit stream of every coder equals the body of the compressed image of the CNES reference software (or of the CCSDS
test data set) byte by byte, including the tail and the fill bits, for two consecutive images; so does every
compressed image of the core tests. Each coder takes one item per clock cycle (TC-CO-25 to TC-CO-28). Every
requirement of the specification is covered; the error injection into the statistics memories and the codeword
buffers (EC-FT-01, EC-FT-02) runs in the core testbench (TC-CO-37).

Findings:

| Finding | Resolution |
| --- | --- |
| Block-adaptive coder: the block index was not reset after a block with the no-compression or a split-sample option, so the next block was selected after one value (TC-CO-06 to TC-CO-08) | Index reset on every return to the collection of a block |
| Sample-adaptive coder: memory read, SECDED decoding, code index and codeword in one cycle limited the clock frequency to 60 MHz (synthesis estimate) | Pipeline of six stages with forwarding of the statistics of the same band |
| Hybrid coder: the tail of an image took one cycle per low-entropy code and stalled the next image (TC-CO-26) | Flush word of every code state in the code table; two flush words per cycle |
| Codeword buffer: bits beyond the length of a codeword reached the joined codeword | Input masked to the codeword length |
| Timing (place and route at 100 MHz): the block buffer read, the fundamental sequence lengths and the codeword decision formed one path of 11 ns (block-adaptive coder); the code index, the input symbol, an adder and the code table formed the loop of the low-entropy codes (hybrid coder) | Fundamental sequence lengths read one cycle ahead; rows of the code table aligned to a power of two (address by OR) and the escape comparisons one stage earlier |
| Synthesis inferred the block buffers of the block-adaptive coder as memories without ECC (uSRAM on PolarFire) | Synthesis attributes keep the block buffers in registers |
| The error flags of the statistics memory were raised for reads in cycles without a coded sample (TC-CO-37) | A flag counts only when a coded sample or the tail of the hybrid coder takes the statistics |
| GHDL command of a simulation: VUnit 5.0.0.dev7 appends the generics of a test to the list of the option `ghdl.sim_flags` in place, and configurations added after the option is set share that list, so a simulation would also run with the generics of a configuration started before it. `run.py` sets the option after adding the configurations, so every configuration had its own list; QuestaSim is not affected | `run.py` copies the list per simulation and stops when a GHDL command does not carry exactly the generics of its configuration; all configurations pass with this check |
