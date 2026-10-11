# ocp_entropy_coder: Verification Report

## 1. Test results

Run on 2026-10-11 with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit 4f1e13b) as part of `ocp_core_tb`
(`python run.py "*ocp_core*"`).

| Coder | Test cases | Passed |
| --- | --- | --- |
| Sample-adaptive | 14 | 14 |
| Hybrid | 11 | 11 |
| Block-adaptive | 9 | 9 |

## 2. Summary

Every compressed image of the core tests equals the compressed image of the CNES reference software, byte by byte, for
two consecutive images. Each coder takes one item per clock cycle (TC-CO-25 to TC-CO-28). Every requirement of the
specification is covered; the error injection into the statistics memories (EC-FT-01) is not yet tested.

Findings:

| Finding | Resolution |
| --- | --- |
| Block-adaptive coder: the block index was not reset after a block with the no-compression or a split-sample option, so the next block was selected after one value (TC-CO-06 to TC-CO-08) | Index reset on every return to the collection of a block |
| Sample-adaptive coder: memory read, SECDED decoding, code index and codeword in one cycle limited the clock frequency to 60 MHz (synthesis estimate) | Pipeline of six stages with forwarding of the statistics of the same band |
| Hybrid coder: the tail of an image took one cycle per low-entropy code and stalled the next image (TC-CO-26) | Flush word of every code state in the code table; two flush words per cycle |
| Codeword buffer: bits beyond the length of a codeword reached the joined codeword | Input masked to the codeword length |
| Timing (place and route at 100 MHz): the block buffer read, the fundamental sequence lengths and the codeword decision formed one path of 11 ns (block-adaptive coder); the code index, the input symbol, an adder and the code table formed the loop of the low-entropy codes (hybrid coder) | Fundamental sequence lengths read one cycle ahead; rows of the code table aligned to a power of two (address by OR) and the escape comparisons one stage earlier |
