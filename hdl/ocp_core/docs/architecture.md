# ocp_core: Architecture

## 1. Structure

![Block diagram of ocp_core: ocp_predictor, the entropy coder selected by EntropyCoder_g, the source multiplexer, the
bit packer, the header generator, the image sequencer (CO-3), the OR of the memory error events and the error
injection](img/ocp_core_arch.drawio.svg)

The predictor signals with `Img_Start` that it has accepted the first item of an image. The image sequencer counts
the images accepted at the input and not yet given a header; it starts the header of the next image once the bit
packer has taken the last codeword of the previous one and an accepted image is waiting. It selects the header
generator as the source of the bit packer until the last part of the header is taken, then the entropy coder until
its last codeword is taken. The predictor and the entropy coder run ahead during the header: their codewords collect
in the codeword buffer of the entropy coder and leave it concatenated afterwards. Consecutive compressed images do
not overlap.

## 2. Header generator (`ocp_header`)

The header is a constant computed during elaboration by the procedure `build` from the generics: every field of
CCSDS tables 5-3 to 5-15 in order, the optional tables and the fill bits to the byte boundaries. `Start` begins the
output of the constant in parts of 64 bits, the last part shorter; `Out_Last` marks the last part. The synthesis
tools implement the constant as a ROM.

## 3. Bit packer (`ocp_bit_packer`)

The bit packer takes one codeword of up to 96 bits per clock cycle and outputs words of `OutWidth_g` bits (8, 16, 32
or 64). The codewords are written into a circular bit buffer (256 bits, 512 bits for 64-bit words with large output
word sizes) in stream order, the first bit of the image at buffer position 0: the position of a codeword is the sum of
the lengths before it, so the rotation of a codeword to its position and the write into the buffer take three
pipeline stages without a feedback loop. A word leaves the buffer once all its bits are written. On the way out,
buffer bits 8n to 8n + 7 of the word become byte n of the interface word (`Out_Data` bits 8n + 7 to 8n) with the first
of them in the most significant bit, so the first byte of the image is in bits 7 to 0 (CO-IF-02). The reordering is
wiring only.

After the last codeword of an image (`In_Last`) the bit packer appends zero bits up to a multiple of B bytes
(`OutputWordSize_g`, CCSDS 5.3.1.2), counted from the first bit of the image. The interface word that holds the end of
the image carries `Out_Last` and marks its valid bytes with `Out_Keep`; the next image starts with a new interface
word. The throughput is one codeword per clock cycle as long as the codewords carry on average at most `OutWidth_g`
bits per clock cycle.

## 4. Interfaces

| Port | Direction | Description |
| --- | --- | --- |
| `Clk`, `Rst` | in | Clock, synchronous high-active reset |
| `In_Valid`, `In_Ready`, `In_Data` | in | Samples (D bits) in the input order |
| `Lim_Valid`, `Lim_Ready`, `Lim_Data` | in | Error limit values (periodic updating) |
| `Out_Valid`, `Out_Ready`, `Out_Data`, `Out_Keep`, `Out_Last` | out | Compressed image, words of `OutWidth_g` bits, byte n in bits 8n + 7 to 8n (first byte in bits 7 to 0); valid bytes of the last word of an image, contiguous from byte 0 |
| `Ecc_Sec`, `Ecc_Ded` | out | Memory error events of the predictor and the entropy coder |
| `ErrInj_Channel`, `ErrInj_Double`, `ErrInj_Valid` | in | Error injection: channels 0 to 11 go to the predictor, channel 12 to the statistics memory and channel 13 to the codeword buffer of the entropy coder |
