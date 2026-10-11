# ocp_predictor: Architecture

## 1. Structure

`ocp_predictor` is one two-process state machine with five SECDED-protected memories (`olo_ft_ram_sdp`). It processes
one sample at a time: the next sample is accepted when the state of the previous one is written back (architecture
decision D4).

```text
 In -> Idle_s -> Fetch_s -> Sum_s -> Dot_s -> Pred_s -> Quant_s [-> Div_s] -> Rep_s -> Map_s -> Update_s -> Out_s
         |          ^ reads                                                                                  | writes
         v          |                                                                                        v
      LimIn_s <-> LimOut_s (periodic error limits)        sample representatives, local differences, weights
```

| State | Cycles | Function | CCSDS |
| --- | --- | --- | --- |
| `Idle_s` | 1 | Accept a sample; start an error limit update at the start of an update period | 4.8.2.4, 5.4.2 |
| `LimIn_s`, `LimOut_s` | 2 per value | Read an error limit value, store it, forward it as an item | 4.8.2.4 |
| `Fetch_s` | 5 | Read the neighbours N, NW, NE and W (or the previous band), the local differences of the previous bands, the weights and the error limits | 4.4, 4.5 |
| `Sum_s` | 1 | Local sum, directional local differences, local difference vector | 4.4, 4.5 |
| `Dot_s`, `DotLast_s` | C + 1 | Predicted central local difference: product of component j, sum of the product of component j - 1 | 4.7.1 |
| `Pred_s` | 1 | High-resolution predicted sample value (wrap to R bits, clipping), double-resolution and predicted sample value | 4.7.2 to 4.7.4 |
| `Quant_s` | 1 | Residual, maximum error, dividends of the quantizer and of the mapper | 4.8 |
| `Div_s` | max(D, 16) + 2 | Restoring division by 2 m + 1 of three dividends (only when m > 0) | 4.8.1, 4.11 |
| `Rep_s` | 1 | Quantizer index, clipped bin center, offset term of the sample representative, prediction error, weight update scaling exponent | 4.8.1, 4.9, 4.10.1, 4.10.2 |
| `RepMul_s`, `RepSum_s` | 2 | Products and sum of the numerator of the sample representative, sample representative, central local difference (not for t = 0) | 4.9, 4.5.1 |
| `Map_s` | 1 | Mapped quantizer index | 4.11 |
| `Update_s`, `UpdateLast_s` | C + 1 | Weight update in two stages: increment of component j, then weight j - 1 plus its increment, clipped | 4.10.3 |
| `Out_s` | 1 | Output item, write back of the sample representative, the local differences and the weights, next position | 5.4.2 |

C is the number of local differences (P + 3 in full, P in reduced prediction mode). A sample with t = 0 skips
`Dot_s`, `RepMul_s`, `RepSum_s` and `Update_s`; a sample with m = 0 skips `Div_s`. Cycles per sample: 16 + 2 C, plus
max(D, 16) + 2 when m > 0. The damping and offset of the band are read into registers during `Fetch_s`.

## 2. Memories

| Memory | Depth | Width | Content |
| --- | --- | --- | --- |
| Sample representatives | BI: 2 NZ NX; BSQ: 6 NX | D | BI: rows y and y - 1 of every band. BSQ: row 0 and two further rows of the current and of the previous band, so that the narrow local sums of row 0 find the previous band |
| Local differences | BI: NX; BSQ: NX NY | P (D + 3) | Central local differences of the last P bands processed at the pixel: band z reads d_{z-1} to d_{z-P} and writes d_z to d_{z-P+1} |
| Weights | BI: NZ; BSQ: 2 | C (Omega + 3) | Weight vector of every band (BSQ: of the current band) |
| Absolute, relative error limits | NZ + 1 | 16 | Band-dependent error limits of periodic updating |

The input order processes the bands of a pixel in increasing order (BI) or the bands one after the other (BSQ), so
the word of local differences of a pixel always holds the preceding bands. At t = 1 the weights come from the initial
weight vector (a constant table of the generics), afterwards from the memory; no memory is initialised.

## 3. Arithmetic

| Quantity | Width | Note |
| --- | --- | --- |
| Samples, sample representatives | D + 2 (signed) | Unsigned and signed samples in one format |
| Local differences | D + 4 (signed) | D + 3 bits stored |
| Weights | Omega + 3 | |
| Dot product | Omega + D + 12 | No overflow for C <= 18; then wrapped to R bits (37) |
| High-resolution predicted sample value | Omega + D + 6 | After clipping |
| Quantizer operands | max(D, 16) + 2 | Error limits up to 16 bits |

The quantizer divides |residual| + m, the distance of the prediction to the lower and to the upper sample limit plus
m by 2 m + 1 in parallel; the remainder of the first division gives the clipped bin center without a multiplier:
q (2 m + 1) = sgn(residual) (|residual| + m - remainder).

## 4. Interfaces

| Port | Direction | Description |
| --- | --- | --- |
| `In_Valid`, `In_Ready`, `In_Data` | in | Samples (D bits) in the input order |
| `Lim_Valid`, `Lim_Ready`, `Lim_Data` | in | 16-bit error limit values (periodic updating) |
| `Out_Valid`, `Out_Ready`, `Out_Data` | out | Item value, max(D, 16) bits |
| `Out_Kind` | out | `ItemSample_c`, `ItemAbsLimit_c` or `ItemRelLimit_c` |
| `Out_Band`, `Out_First`, `Out_Init`, `Out_Last` | out | Band, t = 0, t = 1, last sample of the image |
| `Ecc_Sec`, `Ecc_Ded` | out | Memory error events |
