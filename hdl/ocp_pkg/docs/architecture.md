# ocp_pkg: Architecture

## 1. ocp_pkg

| Content | Description |
| --- | --- |
| `CwWidth_c`, `CwLenWidth_c` | Codeword stream: 64 data bits, 7 length bits |
| `ItemSample_c`, `ItemAbsLimit_c`, `ItemRelLimit_c` | Item kinds of the entropy coder input sequence |
| `encodingOrderCode`, `entropyCoderCode`, `fidelityCode`, `localSumCode`, `fullPrediction` | Decoding of the string generics; an unknown value is a `failure` during elaboration |
| `vecElem`, `bandsUsed`, `diffsUsed`, `bandTableStart`, `bandTableSize` | Per-band tables: element z with the last element repeated; Pz*, Cz and the start of band z in a table of Pz* + extra entries per band |
| `LeLimit_c`, `LeThreshold_c` | Input symbol limits L_i and thresholds T_i of table 5-16 |

## 2. ocp_low_entropy_pkg

The low-entropy codes of annex B are prefix-free variable-to-variable codes. Every code is represented as a state
machine: the states are the active prefixes (the proper prefixes of its input codewords, ordered by length; state 0
is the null prefix), the inputs are the symbols 0 to L_i and the escape symbol X.

![Entry of LeTrans_c: flush word of the resulting active prefix, flag of a complete input codeword, and either the
length and the output codeword or the address of the next state and the next state](img/ocp_pkg_le_entry.drawio.svg)

| Constant | Entries | Entry |
| --- | --- | --- |
| `LeTrans_c` | 3004 (one per state and symbol, rows of a power of two of entries) | bits 40 to 27: flush word of the resulting active prefix; bit 26: complete input codeword; bits 25 to 21: length of the output codeword; bits 20 to 0: output codeword (complete) or the address of the next state (bits 19 to 8) and the next state (bits 7 to 0) |
| `LeTransBase_c` | 16 | First entry of code i, a multiple of the row size S_i = 2^ceil(log2(L_i + 2)); entry address base + state S_i + symbol, unused entries zero |
| `LeFlush_c` | 630 (one per state) | bits 13 to 10: length; bits 9 to 0: flush word |
| `LeFlushBase_c` | 16 | First entry of code i |

`tools/ocp_low_entropy_codes.py` is the transcription of tables B-1 to B-32 (code tables with their output codewords,
flush tables; the range notation 0^{r} of the tables expanded). `tools/gen_low_entropy_pkg.py` generates the package
from it; `--check` fails when the package is not up to date.
