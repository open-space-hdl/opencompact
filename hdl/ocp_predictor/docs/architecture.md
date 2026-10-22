# ocp_predictor: Architecture

## 1. Structure

`ocp_predictor` is a pipeline without internal stalls. Its issue stage starts the next sample of the input order as
soon as the samples it depends on have left the feedback loops and the output has room for every item in flight; every
following stage takes one clock cycle. The pipeline registers are records of the two-process pattern; the memories
are SECDED-protected (`olo_ft_ram_sdp`, read latency two cycles), the output is a SECDED-protected FIFO
(`olo_ft_fifo_sync`) followed by a register stage (`olo_base_pl_stage`), so that the SECDED correction of the FIFO
and the first stage of the entropy coder are in different clock cycles. The memories are read in every cycle, also
without an item; an error flag of a memory counts only in a cycle in which an item takes the read data (the item in
the stage that uses the data, the handshake at the output of the FIFO), so that an upset of a word that is not used
does not raise an alarm.

![Block diagram of ocp_predictor: the pipeline stages from the issue stage to the sample representative, the
memories with their read and write paths, the speculative weight loop, the output buffer of the stride order, the
output FIFO and the register stage](img/ocp_predictor_arch.drawio.svg)

| Stage | Function | CCSDS |
| --- | --- | --- |
| 0 issue | Next item of the input order (error limit value or sample); dependency check against the issued samples; read addresses of the memories | 4.8.2.4, 5.4.2 |
| 1 | Band parameters (weight exponent offsets, damping, offset, fixed error limits), weight update scaling exponent rho(t) | 4.10.2 |
| 2 | Memory data: neighbours N, NW, NE, W or the previous band, local differences of the previous bands, periodic error limits; local sum | 4.4 |
| 3 | Directional and central local differences, local difference vector | 4.5 |
| 4 | Weight increments for both signs of the prediction error; thresholds of the error sign | 4.10.3 |
| 5 | Weight vectors (memory, initial weights or speculative loop); products of the dot product; local sum term of the high-resolution predicted sample | 4.7.1, 4.7.2 |
| 6, 7 | Adder trees, four operands per stage: high-resolution sum | 4.7.1, 4.7.2 |
| sign | Error sign from the high-resolution sum; wrap to R bits (mod*R) | 4.7.2, 4.10.1 |
| update | Weights plus increment of the error sign, clipped; write back | 4.10.3 |
| PredB, Quant | Double-resolution and predicted sample, prediction residual | 4.7.3, 4.7.4, 4.8.1 |
| Limit | Maximum error; dividends of the quantizer and the mapper; with relative error limits the error sign | 4.8.2 |
| divider | Near-lossless compression: restoring division of three dividends by 2 m + 1, one quotient bit per stage (max(D, 16) + 2 stages) | 4.8.1, 4.11 |
| Rep, RepMul, RepSum | Quantizer index, clipped bin center, sample representative, central local difference; mapped quantizer index | 4.8.1, 4.9, 4.11 |

The pipeline is 14 to 16 stages long in lossless compression and 31 to 50 stages in near-lossless compression; the
divider stages exist only in near-lossless compression.

## 2. Feedback loops and the issue stage

A sample depends on earlier samples through four feedback loops:

| Loop | Earlier sample | Distance (cycles) |
| --- | --- | --- |
| Weights | Previous sample of the band | update stage - 1 (7 to 11) |
| Window of the previous line | Previous sample of the band (unless the window is forwarded, see below) | 4 |
| Sample representatives (near-lossless, or lossless with damping) | Previous sample of the band (W neighbour), first sample of the line, previous line | RepSum + 2 (about 33) |
| Central local differences and sample representatives of the previous band (near-lossless or lossless with damping, or local differences kept in memory) | Sample of the previous band at the same pixel (at x - 1 in row 0 with narrow local sums) | RepSum + 2 (lossless without damping: 1) |

The issue stage keeps the band and the column of the samples issued in the last cycles (scoreboard). A sample waits
while a sample of its band was issued less than the distance of its loops ago, or a sample of the previous band at its
column less than the cross-band distance ago. In BI order with M at least the weight distance, lossless compression
runs at one sample per clock cycle. The throughput model `tools/ocp_throughput.py` mirrors these distances and gives
the issue cycle of every sample; the testbench checks the RTL against it.

The error sign of the weight update follows from the high-resolution sum by comparisons (lossless and absolute error
limits): with V the bits R - 1 to Omega + 1 of the wrapped sum, the double-resolution predicted sample is
s~ = clip(V + 2 smid + 1), and the sign is positive when s~ < 2 (s - m), negative when s~ >= 2 (s + m + 1) and
otherwise given by the parity of s~ (4.8.1, 4.9, 4.10.1). The thresholds come from the sample and the maximum error
before the dot product, so the weight loop closes right after the adder tree.

## 3. Speculative weight loop

When consecutive samples belong to the same band (BSQ order, BI order with M = 1) and the adder tree has one stage
(at most three local differences), the weight loop speculates (`Speculation_g`): the update of a weight vector depends
only on the sign of the prediction error, so the loop keeps the four weight vectors of the next sample for the four
sign combinations of the two samples ahead of it. Stage 5 computes the products of all four vectors, the adder trees
the four sums, and the sign stage selects the sum of the signs that are known by then. In the same cycle the sign of
the sample two ahead selects four of the eight updated vectors for the next sample. Cycles without a sample act as
samples with a zero increment, so the candidates stay consistent. A run of a band starts with the initial weights
(t = 1) or, in BI order with M = 1, with the weights of the band in memory at the first column of a line; in BSQ order
and in images of one band a run continues from line to line. The loop applies to lossless compression and to
near-lossless compression with absolute error limits, narrow local sums and reduced prediction, where no sample
representative of the previous sample enters the prediction.

## 4. Stride order

In BI order with M = NZ and near-lossless compression with dependencies between the bands of a pixel (P > 0 or narrow
local sums), without periodic error limit updating, the predictor processes the samples of an image in stride order
(`Stride_g`): sample (z, t) in slot t M + z S, with S the smallest number at least the cross-band distance that is
coprime with M. The sample of the previous band at the same pixel is then S slots ahead, the previous sample of the
band M slots. Slot n + 1 holds band z + S^-1 (mod M); the pixel index changes by a constant, so band, column, row and
input index of the slots follow from adders. Slots outside the image are skipped in one cycle each, about (M - 1) S per
image.

An input buffer (at least (M - 1)(S - 1) + M samples) holds the samples until their slot; an output buffer holds the
mapped quantizer indices at their input index and is read in the input order once the slot of the next index has
passed. The central local differences of the previous bands come from a memory per band. The next image starts when
all slots of the image have passed and its output has been read.

Early end (`In_End`, PR-FR-02): the input buffer records the input index L of the end sample (`EndA`) and takes no
further sample. Slot n of index a = t M + z is n = a + z (S - 1), at most `Skew_c` = (M - 1)(S - 1) slots after its
index, so every slot of an index up to L lies at or before L + `Skew_c` and every later slot belongs to an index above
L. The sequencer skips the slots of indices above L in one cycle each, like the slots outside the image, issues the
others as usual, and ends the image when L + 1 samples have been issued (`IssCnt`), at the last slot of an index up to
L instead of the last slot of the image. The output buffer is read up to index L, which carries the last-item flag;
the next image starts at slot 0 when index L has been read. Compared with the arrival of the end sample, the
sequencer needs at most the slots between its current slot and that last slot, which the input buffer bounds to
`InDepth_c` + `Skew_c` slots.

In the input order (all other cases) the issue stage marks the sample with `In_End` as the last item and resets its
position (column, row, band, sub-frame, error limit state) as after the last sample of an image (PR-FR-01).

## 5. Memories

| Memory | Depth | Width | Content |
| --- | --- | --- | --- |
| Sample representatives | BI: NZ NX; BSQ: 3 NX | D | BI: the current line of every band (a value is read as NE before it is overwritten). BSQ: row 0 of the current and of the previous band, and the current line |
| Window | NZ (not in BSQ and BI with M = 1, where it is forwarded) | 2 D | N and NE of the previous sample of the band, the NW and N of the next one |
| Previous sample, first sample of the line | NZ (BSQ: 2) | D each | W neighbour; N of the first column |
| Local differences | BI with M < NZ: NX; BSQ: NX NY | P (D + 3) | Central local differences of the last P bands at the pixel, for the first band of a sub-frame (BI) or of the pixel (BSQ) |
| Weights | NZ (BSQ: 2) | C (Omega + 3) | Weight vector of every band; read at stage 3 for stage 5 |
| Absolute, relative error limits | NZ + 1 | 16 | Band-dependent error limits of periodic updating |
| Input, output buffer, local differences per band | Stride order only | D, D, P (D + 3) | See section 4 |

Within a sub-frame (BI) the local differences of the previous bands come from the previous sample through a
register; in lossless compression without damping (all phi_z = 0) the sample representatives are the samples and are
written when the sample is issued. With damping the sample representative depends on the high-resolution predicted
sample also in lossless compression (CCSDS 4.9.2), so lossless compression with damping uses the path of near-lossless
compression with m_z = 0 and no divider stages. At t = 1 the weights come from the initial weight vector (a constant
table of the generics); no memory is initialised.

## 6. Arithmetic

| Quantity | Width | Note |
| --- | --- | --- |
| Samples, sample representatives | D + 2 (signed) | Unsigned and signed samples in one format |
| Local differences | D + 4 (signed) | D + 3 bits stored |
| Weights | Omega + 3 | |
| High-resolution sum | Omega + D + 12 | Dot product and local sum term; no overflow for C <= 18; wrapped to R bits (37) |
| High-resolution predicted sample value | Omega + D + 6 | After clipping |
| Quantizer operands | max(D, 16) + 2 | Error limits up to 16 bits |

The quantizer divides |residual| + m, the distance of the prediction to the lower and to the upper sample limit plus
m by 2 m + 1 in parallel; the remainder of the first division gives the clipped bin center without a multiplier:
q (2 m + 1) = sgn(residual) (|residual| + m - remainder).

## 7. Interfaces

| Port | Direction | Description |
| --- | --- | --- |
| `In_Valid`, `In_Ready`, `In_Data`, `In_End` | in | Samples (D bits) in the input order; `In_End` with a sample that ends its image early (PR-FR-01, PR-FR-02) |
| `Lim_Valid`, `Lim_Ready`, `Lim_Data` | in | 16-bit error limit values (periodic updating) |
| `Img_Start` | out | Pulse: the first item of an image is accepted |
| `Out_Valid`, `Out_Ready`, `Out_Data` | out | Item value, max(D, 16) bits |
| `Out_Kind` | out | `ItemSample_c`, `ItemAbsLimit_c` or `ItemRelLimit_c` |
| `Out_Band`, `Out_First`, `Out_Init`, `Out_Last` | out | Band, t = 0, t = 1, last sample of the image |
| `Ecc_Sec`, `Ecc_Ded` | out | Memory error events |
| `ErrInj_Channel`, `ErrInj_Double`, `ErrInj_Valid` | in | Error injection into the next write of a memory: channel n is the memory whose error flags are bit n of the internal error vector (0 line, 1 window, 2 previous representative, 3 first representative of the line, 4 local differences, 5 weights, 6 and 7 error limits, 8 output FIFO, 9 to 11 stride buffers) |

## 8. Runtime configuration

With `RuntimeConfig_g` (`ocp_core` architecture, section 6) the predictor takes the dimensions and the band-independent
error limit values of an image from the configuration entry of that image. The position counters of the input order
compare with NX, NY, NZ and M of the image; the memories keep the sizes of `XSize_g`, `YSize_g` and `ZSize_g`, and the
line memories are addressed with the pitch of `XSize_g`. The conditions of the issue stage that the elaboration
derives from the dimensions (section 2) come from the image-start sequencer, which computes them in a fixed number of
clock cycles before the first sample of the image is started; the history of issued bands has the length of the worst
case over the allowed dimensions. The stride order (section 4) is not instantiated.
