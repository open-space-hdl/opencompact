# ocp_entropy_coder: Architecture

## 1. Common structure

Each coder is a two-process state machine with an input handshake on the entropy coder input sequence and one output
register for codewords (`Cw_Data`, right-aligned, `Cw_Length` bits, `Cw_Last`). A codeword is at most 64 bits long; a
longer bit string is sent as several codewords. Error limit values and the uncoded first index of a band are passed
through as codewords of DA, DR or D bits.

## 2. Sample-adaptive coder (`ocp_sample_adaptive_coder`)

| State | Cycles | Function | CCSDS |
| --- | --- | --- | --- |
| `Idle_s` | 1 | Accept an item; error limits and first indexes are output directly; otherwise read the statistics of the band | 5.4.3.2.4.1, 5.4.3.2.4.2 |
| `Read_s` | 1 | Memory latency (SECDED decoder with pipeline register) | |
| `Load_s` | 1 | Accumulator and counter from the memory, or the initial values at t = 1 (57) to (59); right-hand side of (62) | 5.4.3.2.3 |
| `Index_s` | 1 | Largest k <= D - 2 with Gamma 2^k <= Sigma + floor(49 Gamma / 2^7) | 5.4.3.2.4.3 |
| `Code_s` | 1 | GPO2 codeword, statistics update (60), (61), write back | 5.4.3.2.2, 5.4.3.2.3.4 |

The statistics memory holds per band the accumulator (D + gamma\* + 2 bits) and the counter (gamma\* + 1 bits). It is
written in `Code_s` and read at the earliest in the next `Idle_s`, so consecutive indexes of the same band see the
updated values. The initial accumulators are a constant table of the generics.

## 3. Hybrid coder (`ocp_hybrid_coder`)

| State | Function | CCSDS |
| --- | --- | --- |
| `Idle_s` | Accept an item; error limits and first indexes are output directly | 5.4.3.3.5.1.1, 5.4.3.3.5.1.3 |
| `Read_s` | Memory latency | |
| `Update_s` | Statistics update (64), (65) with the rescaling bit; high or low entropy (5.4.3.3.5.1.4); high entropy: code index (66) and reversed GPO2 codeword; low entropy: code index, input symbol, escape codeword, address of the code table | 5.4.3.3.4, 5.4.3.3.5 |
| `Lookup_s` | Code table entry: complete input codeword (output codeword, active prefix reset) or next active prefix | 5.4.3.3.5.3.4, 5.4.3.3.5.3.5 |
| `Emit_s` | Pending codewords in the order rescaling bit, GPO2 or escape codeword, low-entropy output codeword | 5.4.3.3.5.1.2 |
| `Flush_s` | Flush word of the active prefix of codes 0 to 15 | 5.4.3.3.5.4.2 |
| `TailRead_s`, `TailAcc_s` | Final accumulator of every band, 2 + D + gamma* bits | 5.4.3.3.5.4.3 |
| `TailEnd_s` | The final '1' bit, last codeword | 5.4.3.3.5.4.4 |

The 16 low-entropy codes are state machines whose states are the active prefixes (proper prefixes of the input
codewords, state 0 is the null prefix). `ocp_low_entropy_pkg` holds one transition entry per state and input symbol
(2740 entries of 27 bits) and one flush word per state (630 entries of 14 bits), generated from the tables of annex B
by `tools/gen_low_entropy_pkg.py`. The transition table is read as a synchronous ROM. The active prefixes of the 16
codes are registers and return to the null prefix after the tail.

## 4. Block-adaptive coder (`ocp_block_adaptive_coder`)

| State | Function | Reference |
| --- | --- | --- |
| `Collect_s` | Accept J values into the block buffer; update the code lengths of all options while the values arrive | LDC 3 |
| `Pad_s` | Zeros after the last value up to the end of the block | CCSDS 5.4.3.4.2.7 |
| `Select_s` | All-zeros block: extend the run, end it at the end of a segment (64 blocks or the end of the reference sample interval) or of the input; other blocks: shortest option, first the pending zero-block run | LDC 3.5, 3.7 |
| `ZeroId_s`, `ZeroFs_s` | Zero-block coded data set: option identifier and fundamental sequence codeword of the run length or remainder of segment | LDC 3.5, 5.2.5 |
| `Id_s` | Option identifier | LDC 5.2.1 |
| `Main_s` | Samples (no compression), fundamental sequence codewords of the second extension symbols or of the split values, in parts of at most 64 bits | LDC 3.2 to 3.4, 3.6 |
| `Lsb_s` | k split bits of every value | LDC 3.3 |

The code lengths are accumulated with saturation at 8191 bits, far above the length of the no-compression option
(at most 32 * 64 + 5 bits), so a saturated length never wins. The option identifiers and the largest split-sample
parameter follow table 5-1 of CCSDS 121.0-B-3: identifiers of 1 (restricted, n <= 2), 2 (restricted, n <= 4), 3
(n <= 8), 4 (n <= 16) and 5 bits, split-sample options up to k = 1, 5, 13 and 29. The block buffer is a register array
of J values.

## 5. Interfaces

| Port | Direction | Description |
| --- | --- | --- |
| `In_Valid`, `In_Ready`, `In_Data`, `In_Kind`, `In_Band`, `In_First`, `In_Init`, `In_Last` | in | Entropy coder input sequence (the block-adaptive coder uses value and last flag only) |
| `Cw_Valid`, `Cw_Ready`, `Cw_Data`, `Cw_Length`, `Cw_Last` | out | Codewords |
| `Ecc_Sec`, `Ecc_Ded` | out | Memory error events (sample-adaptive and hybrid coder) |
