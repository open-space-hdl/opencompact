# ocp_entropy_coder: Verification Report

## 1. Test results

Run on 2026-10-10 with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit 4f1e13b) as part of `ocp_core_tb`
(`python run.py "*ocp_core*"`).

| Coder | Test cases | Passed |
| --- | --- | --- |
| Sample-adaptive | 11 | 11 |
| Hybrid | 9 | 9 |
| Block-adaptive | 8 | 8 |

## 2. Summary

Every compressed image of the core tests equals the compressed image of the CNES reference software, byte by byte,
for two consecutive images. Every requirement of the specification is covered; the error injection into the
statistics memories (EC-FT-01) is not yet tested.

Findings:

| Finding | Resolution |
| --- | --- |
| Block-adaptive coder: the block index was not reset after a block with the no-compression or a split-sample option, so the next block was selected after one value (TC-CO-06 to TC-CO-08) | Index reset on every return to the collection of a block |
| Sample-adaptive coder: memory read, SECDED decoding, code index and codeword in one cycle limited the clock frequency to 60 MHz (synthesis estimate) | Decoder pipeline register and separate states for the statistics, the code index and the codeword |
