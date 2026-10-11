# ocp_core: Architecture

## 1. Structure

```text
          +-----------+
          | ocp_header| --- header bytes (8-bit codewords) ---+
          +-----------+                                        v
In  --> ocp_predictor --> ocp_<selected>_coder --> codewords --> mux --> ocp_bit_packer --> Out
Lim -->                                                         ^
                       image sequencer: header, then body ------+
```

The image sequencer selects the header generator as the source of the bit packer until the last header byte is taken,
then the entropy coder until its last codeword is taken. The predictor and the entropy coder run ahead during the
header: their codewords wait at the multiplexer. After the last codeword the bit packer adds the fill bits; it takes
the header of the next image only afterwards, so consecutive compressed images do not overlap.

## 2. Header generator (`ocp_header`)

The header is a constant computed during elaboration by the procedure `build` from the generics: every field of
CCSDS tables 5-3 to 5-15 in order, the optional tables and the fill bits to the byte boundaries. `Start` begins the
output of the constant byte by byte; `Out_Last` marks the last header byte. The synthesis tools implement the
constant as a ROM.

## 3. Bit packer (`ocp_bit_packer`)

A 72-bit buffer takes a codeword of up to 64 bits whenever it holds at most 8 bits and outputs one byte per cycle
when it holds 8 bits or more. After the last codeword (`In_Last`) it outputs the remaining bits padded with zeros, then
zero bytes until the number of bytes of the image is a multiple of B (`OutputWordSize_g`), and marks the last byte.
The byte counter modulo B starts at the first header byte.

## 4. Interfaces

| Port | Direction | Description |
| --- | --- | --- |
| `Clk`, `Rst` | in | Clock, synchronous high-active reset |
| `In_Valid`, `In_Ready`, `In_Data` | in | Samples (D bits) in the input order |
| `Lim_Valid`, `Lim_Ready`, `Lim_Data` | in | Error limit values (periodic updating) |
| `Out_Valid`, `Out_Ready`, `Out_Data`, `Out_Last` | out | Compressed image, bytes |
| `Ecc_Sec`, `Ecc_Ded` | out | Memory error events of the predictor and the entropy coder |
