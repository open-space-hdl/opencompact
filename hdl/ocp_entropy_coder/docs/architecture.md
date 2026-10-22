# ocp_entropy_coder: Architecture

## 1. Common structure

Every coder takes one item of the entropy coder input sequence per clock cycle and produces codewords (`Cw_Data`,
right-aligned, `Cw_Length` bits, `Cw_Last`) of up to 96 bits (`CwWidth_c`). The sample-adaptive and the hybrid
coder are pipelines without internal stalls: an item enters only when the output buffer has room for every item in
flight. Error limit values and the uncoded first index of a band pass through as codewords of DA, DR or D bits.

All three coders end in the codeword buffer `ocp_cw_buffer`: a register concatenates consecutive codewords into one
codeword of up to 96 bits before it enters a SECDED-protected FIFO (`olo_ft_fifo_sync`, 16 entries). A FIFO entry
therefore holds several short codewords. While the bit packer takes the header of the next image, the coder keeps
running into the buffer, and afterwards the bit packer takes several codewords per clock cycle until the backlog is
gone. A codeword with the last flag ends a concatenation. The error flags of the FIFO count once per word, with the
handshake at its output.

The statistics of a band (accumulator and counter) live in a SECDED-protected memory (`olo_ft_ram_sdp`, read latency
two cycles). An item reads the memory when it enters the pipeline; when one of the three items ahead of it belongs to
the same band and has not yet written its updated statistics, the item takes them from that item's pipeline register
instead (newest first). Consecutive indexes of one band (BSQ order) therefore cost no extra cycles. The error flags
of the memory count only when an item (or the tail of the hybrid coder) takes the read statistics.

## 2. Sample-adaptive coder (`ocp_sample_adaptive_coder`)

![Block diagram of ocp_sample_adaptive_coder: issue, statistics, code selection and codeword stages, the statistics
memory with forwarding from the items ahead, and the codeword buffer](img/ocp_sample_adaptive_coder_arch.drawio.svg)

| Stage | Function | CCSDS |
| --- | --- | --- |
| 0 | Accept an item, read the statistics of its band | |
| 1 | Memory latency | |
| 2 | Accumulator and counter (memory, forwarded or initial values at t = 1 (57) to (59)); update (60), (61); write back from the next stage | 5.4.3.2.3 |
| 3 | Right-hand side Sigma + floor(49 Gamma / 2^7) of (62) | 5.4.3.2.4.3 |
| 4 | Largest k <= D - 2 with Gamma 2^k <= right-hand side | 5.4.3.2.4.3 |
| 5 | Codeword: error limit value, uncoded first index or length-limited GPO2 codeword | 5.4.3.2.2, 5.4.3.2.4 |

The statistics memory holds per band the accumulator (D + gamma\* + 2 bits) and the counter (gamma\* + 1 bits). The
initial accumulators are a constant table of the generics.

## 3. Hybrid coder (`ocp_hybrid_coder`)

![Block diagram of ocp_hybrid_coder: issue, statistics, coding method, main codeword, low-entropy and codeword
stages, the statistics memory, the low-entropy code tables, the tail, the output multiplexer and the codeword
buffer](img/ocp_hybrid_coder_arch.drawio.svg)

| Stage | Function | CCSDS |
| --- | --- | --- |
| 0, 1 | Accept an item, read the statistics of its band | |
| 2 | Statistics update (64), (65); with rescaling the least significant bit of the accumulator is kept for the output | 5.4.3.3.4, 5.4.3.3.5.1.2 |
| 3 | Products of the counter with the 16 thresholds of table 5-16, right-hand side of (66); comparison of the index with the input symbol limit of every low-entropy code | 5.4.3.3.5.1.4, 5.4.3.3.5.3.4 |
| 4 | High or low entropy, code index of a high-entropy index (66), low-entropy code | 5.4.3.3.5.1.4, 5.4.3.3.5.3.1 |
| 5 | High entropy: reversed GPO2 codeword; low entropy: escape codeword above the input symbol limit (67), address of the code table entry | 5.4.3.3.5.2, 5.4.3.3.5.3 |
| 6 | Code table entry: output codeword of a complete input codeword or extended active prefix; rescaling bit in front of the main codeword | 5.4.3.3.5.3.4, 5.4.3.3.5.3.5 |
| 7 | Codeword of the sample: rescaling bit, main codeword, low-entropy output codeword (at most 86 bits) | 5.4.3.3.5.1 |

The 16 low-entropy codes are state machines whose states are the active prefixes (proper prefixes of the input
codewords, state 0 is the null prefix). `ocp_low_entropy_pkg` holds one transition entry per state and input symbol
(3004 entries of 41 bits), generated from the tables of annex B by `tools/gen_low_entropy_pkg.py`. An entry that extends
the active prefix holds the table address of the new prefix, an entry that completes an input codeword the output
codeword; every entry holds the flush word of the resulting prefix. The state of a code is therefore the table address
of its active prefix. The rows of a code have a power of two of entries, so the next address is the address in the entry
just read ORed with the next input symbol: the loop of one clock cycle holds two multiplexers and the table, no adder,
and when consecutive samples use the same code the entry read in the previous cycle is used directly. The input symbol
is selected from comparisons made one stage earlier. The flush words of the 16 codes are registers that follow the table
entries.

After the last item the tail follows (5.4.3.3.5.4): the flush words of the 16 codes, two per codeword, then the final
accumulator of every band (2 + D + gamma\* bits, read from the statistics memory one band per clock cycle) and the
final '1' bit together with the last accumulator. The next image enters only after the tail; the active prefixes
return to the null prefix.

## 4. Block-adaptive coder (`ocp_block_adaptive_coder`)

![Block diagram of ocp_block_adaptive_coder: collection, selection, zero-block runs and output, the three block
buffers and the codeword buffer](img/ocp_block_adaptive_coder_arch.drawio.svg)

| Part | Function | Reference |
| --- | --- | --- |
| Collection | One value per cycle into one of three block buffers; the code lengths of all options accumulate as the values arrive; zeros after the last value up to the end of the block | LDC 3; CCSDS 5.4.3.4.2.7 |
| Selection | Lengths of the no-compression, second-extension and split-sample options of a complete block; comparison tree in two stages that keeps the order of the ties (no compression, second extension, smallest k) | LDC 3.7 |
| Zero-block runs | All-zeros blocks extend a run that ends at the end of a segment (64 blocks or the end of the reference sample interval) or of the input, or before a block of another option | LDC 3.5 |
| Output | Zero-block coded data set (option identifier and fundamental sequence codeword of the run or remainder of segment), then the block: option identifier in front of the first part, up to two fundamental sequence codewords, up to four uncoded values or up to four sets of split bits per codeword; fundamental sequence codewords longer than 88 bits in parts | LDC 3.2 to 3.6, 5.2 |

The code lengths are accumulated with saturation at 8191 bits, far above the length of the no-compression option
(at most 32 * 64 + 5 bits), so a saturated length never wins. The option identifiers and the largest split-sample
parameter follow table 5-1 of CCSDS 121.0-B-3: identifiers of 1 (restricted, n <= 2), 2 (restricted, n <= 4), 3
(n <= 8), 4 (n <= 16) and 5 bits, split-sample options up to k = 1, 5, 13 and 29. The output of a block takes fewer
clock cycles than its collection (for J = 8 at most six), so the three buffers let the next blocks fill while a block
is output. The lengths of the fundamental sequence codewords of the next two entries are registers: they are read
from the block buffer one cycle ahead (the first two entries when the output of a block starts, then the entries
two and three positions ahead), so that the decision between one and two codewords per cycle starts from registers
and not from the buffer. The block buffers are registers: synthesis attributes keep the tools from inferring memories
without ECC from them.

## 4a. Runtime configuration

With `RuntimeConfig_g` (`ocp_core` architecture, section 6) the sample-adaptive and the hybrid coder take NZ, and the
hybrid coder also the single-pixel case NX = NY = 1, from the configuration entry of every image at its first item.
The statistics memories keep `ZSize_g` entries. The tail of the hybrid coder steps through the bands 0 to NZ - 1 of the
image with a counter that wraps at NZ, instead of the index modulo `ZSize_g`. The block-adaptive coder does not depend
on the image dimensions.

## 5. Interfaces

| Port | Direction | Description |
| --- | --- | --- |
| `In_Valid`, `In_Ready`, `In_Data`, `In_Kind`, `In_Band`, `In_First`, `In_Init`, `In_Last` | in | Entropy coder input sequence (the block-adaptive coder uses value and last flag only) |
| `Cw_Valid`, `Cw_Ready`, `Cw_Data`, `Cw_Length`, `Cw_Last` | out | Codewords of up to `CwWidth_c` bits |
| `Ecc_Sec`, `Ecc_Ded` | out | Memory error events (statistics memories, codeword buffer) |
| `ErrInj_Stats`, `ErrInj_Buffer`, `ErrInj_Double` | in | Error injection into the next write of the statistics memory or of the codeword buffer (the block-adaptive coder has no statistics memory) |
