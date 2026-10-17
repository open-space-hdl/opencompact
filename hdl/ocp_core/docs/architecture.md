# ocp_core: Architecture

## 1. Structure

![Block diagram of ocp_core: the optional image framer (CO-4) at the inputs, ocp_predictor, the entropy coder selected
by EntropyCoder_g, the source multiplexer, the bit packer, the header generator, the image sequencer (CO-3), the OR of
the memory error events and the error injection](img/ocp_core_arch.drawio.svg)

The predictor signals with `Img_Start` that it has accepted the first item of an image. The image sequencer counts
the images accepted at the input and not yet given a header; it starts the header of the next image once the bit
packer has taken the last codeword of the previous one and an accepted image is waiting. It selects the header
generator as the source of the bit packer until the last part of the header is taken, then the entropy coder until
its last codeword is taken. The predictor and the entropy coder run ahead during the header: their codewords collect
in the codeword buffer of the entropy coder and leave it concatenated afterwards. Consecutive compressed images do
not overlap. With `UseInLast_g` the image framer (section 4) checks the image end marker at the input, ends aborted
images through the source multiplexer and flags the last word of an image with a framing error.

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
word. The end of an image enters the queue of image ends one cycle after its last codeword, before the bits of that
codeword are written, so the word with the last bit is always known as the last word; the last codeword is therefore
never empty. The throughput is one codeword per clock cycle as long as the codewords carry on average at most
`OutWidth_g` bits per clock cycle.

## 4. Image framer (`ocp_image_framer`)

With `UseInLast_g` the image framer (CO-4) sits between the sample and error limit inputs and the predictor; without it
the inputs connect to the predictor directly and `In_Last` is not used. The framer counts the samples of an image down
from NX NY NZ - 1 and compares the count with `In_Last` when a sample is taken. Its state machine:

| State | Samples and error limit values | Leaves on |
| --- | --- | --- |
| Run | Passed to the predictor | The last sample of the image without `In_Last` (to Discard); `In_Last` before the last sample, with or without `In_Error` (to Drain) |
| Drain | Not taken | The predictor and the entropy coder hold only the aborted image: one-cycle `Flush` (to Close) |
| Close | Not taken | The end of the aborted image is taken by the bit packer (to Run) |
| Discard | Samples taken at once and dropped, error limit values not taken | The sample with `In_Last` (to Run) |

Images overlap in the pipeline: when an image ends early, the predictor may still hold samples of it and the entropy
coder the last codewords of the image before. The framer therefore counts the images in the predictor, the entropy
coder and the path to the bit packer (+1 with `Img_Start` of the predictor, -1 when the bit packer takes the last
codeword of an image) and waits in Drain until only the aborted image is left. `Flush` then resets the predictor and
the entropy coder for one clock cycle (as `Rst`); the header generator, the image sequencer and the bit packer keep
their state. In Close the framer waits until the header of the aborted image is taken and offers a last codeword
of one zero bit to the bit packer through the source multiplexer; the bit packer appends the fill bits. The aborted
image consists of its header, the codewords the entropy coder output before the flush and at least one zero fill
bit up to a multiple of B bytes: a prefix of the compressed image of the complete image, cut at a codeword boundary.
An empty last codeword would not do: the words of the aborted image may all have left the bit packer before the
abort, and then no word could carry `Out_Last`.

With `In_Last` and `In_Error` on the last sample (CO-FR-08) the image is complete: the framer stays in Run, the next
sample starts a new image, and only the error flag and `Ev_ImageError` mark the image. `In_Error` without `In_Last` and
in Discard has no effect.

The error flag of every image is written into a queue of 16 flags when its last sample is taken (or its early
`In_Last`), as (not `In_Last`) or `In_Error` for the last sample and '1' for an early `In_Last`, and read when the bit
packer outputs the last word of the image: `Out_Error` is the flag at the head of the queue, gated by `Out_Valid` and
`Out_Last`. The flag is known when the last sample enters the predictor, many cycles before the last word of the image
can leave the bit packer, so the last word is never held for it. While the queue is full the framer takes no sample.
`Ev_ImageError` is a one-cycle pulse when an early or a missing `In_Last` or `In_Error` with the last sample is
detected.

## 5. Interfaces

| Port | Direction | Description |
| --- | --- | --- |
| `Clk`, `Rst` | in | Clock, synchronous high-active reset |
| `In_Valid`, `In_Ready`, `In_Data`, `In_Last`, `In_Error` | in | Samples (D bits) in the input order; `In_Last` on the last sample of an image, `In_Error` with it for an image that ends with an error (`UseInLast_g`) |
| `Lim_Valid`, `Lim_Ready`, `Lim_Data` | in | Error limit values (periodic updating) |
| `Out_Valid`, `Out_Ready`, `Out_Data`, `Out_Keep`, `Out_Last`, `Out_Error` | out | Compressed image, words of `OutWidth_g` bits, byte n in bits 8n + 7 to 8n (first byte in bits 7 to 0); valid bytes of the last word of an image, contiguous from byte 0; `Out_Error` on the last word of an image with a framing error |
| `Ecc_Sec`, `Ecc_Ded` | out | Memory error events of the predictor and the entropy coder |
| `Ev_ImageError` | out | Framing error event (one cycle) |
| `ErrInj_Channel`, `ErrInj_Double`, `ErrInj_Valid` | in | Error injection: channels 0 to 11 go to the predictor, channel 12 to the statistics memory and channel 13 to the codeword buffer of the entropy coder |
