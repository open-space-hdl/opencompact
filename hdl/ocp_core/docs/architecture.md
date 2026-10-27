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
| Run | Passed to the predictor | The last sample of the image without `In_Last` (to Discard) |
| Discard | Samples taken at once and dropped, error limit values not taken | The sample with `In_Last` (to Run) |

A sample with `In_Last` before the last sample of the image goes to the predictor with `Smp_End` (`In_End` of the
predictor); the framer stays in Run and counts the next image from the next sample. The predictor makes that sample
the last item of its image and starts the next image from its first position (`ocp_predictor` architecture, section
4 for the stride order); the entropy coder ends the image on that item with its normal end of an image (the hybrid
coder with its flush codewords and accumulator tail, the block-adaptive coder with the last block of fewer than J
values), and the bit packer appends the fill bits. The aborted image is therefore the compressed image of the samples
taken, whatever the timing (CO-FR-03, CO-FR-09), and the image before it is not touched. For three clock cycles
after the sample with the early `In_Last` the framer takes no error limit value (CO-FR-07), so that a source that
delivers the values ahead can drop those of the aborted image on `Ev_ImageError`.

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
| `Cfg_XSize`, `Cfg_YSize`, `Cfg_ZSize` | in | With `RuntimeConfig_g`: NX, NY, NZ of the next image (17 bits, 1 to the maxima) |
| `Cfg_AbsLimit`, `Cfg_RelLimit` | in | With `RuntimeConfig_g`: band-independent absolute and relative error limit values of the next image (16 bits, 0 to 2^DA - 1 and 2^DR - 1) |
| `Cfg_Taken` | out | With `RuntimeConfig_g`: pulse in the clock cycle in which the core takes the configuration inputs for an image |
| `Act_XSize`, `Act_YSize`, `Act_ZSize`, `Act_AbsLimit`, `Act_RelLimit` | out | With `RuntimeConfig_g`: the values the core took for the last image, after the range limitation (17 and 16 bits) |
| `Cfg_UserData`, `Cfg_M`, `Cfg_WeightInterval`, `Cfg_WeightVmin`, `Cfg_WeightVmax`, `Cfg_UnaryLimit`, `Cfg_InitCountExp`, `Cfg_RescaleSize`, `Cfg_AccuInit`, `Cfg_RefInterval` | in | With `RuntimeParams_g`: the runtime parameters of the next image (8, 17, 4, 5, 5, 6, 4, 4, 4, 13 bits; specification, table 1) |
| `Act_UserData` to `Act_RefInterval` | out | With `RuntimeParams_g`: the runtime parameters the core took for the last image, after the range limitation (zero for a parameter not in use) |

## 6. Runtime configuration

With `RuntimeConfig_g` the configuration of an image is taken once, when the first sample of the image arrives at the
input of the core (CO-RC-03), into an entry of a configuration queue, and `Cfg_Taken` pulses. The entry travels with
the image to the units that need it at their own image start, because these units work on different images at the
same time: while the header generator still outputs the header of image k, the predictor may already compress image
k + 1. On the way into the entry every input passes the range limitation of CO-RC-07, a comparison with constants
and a multiplexer per input, so that no unit addresses outside its memories or counts an image without a bounded
end, whatever arrives at the inputs. The limited values also go into the register of the active configuration,
which drives the `Act_` outputs until the next image start; `ocp_mib` reads its active registers from there.

| Unit | Uses from the entry | Change against the constant configuration |
| --- | --- | --- |
| Image framer (`UseInLast_g`) | NX, NY, NZ | Instead of the count down from NX NY NZ - 1, a mixed-radix count of the sample position (x fastest, then y, then z, in every input order) against NX - 1, NY - 1 and NZ - 1 of the image, taken with its first sample (`Cfg_Take` of the predictor); no product is needed |
| Predictor | NX, NY, NZ, M, error limit values | Position counters compare with the dimensions of the image; memories keep the sizes of the maxima, line memories the pitch of the maximum NX; the image-start sequencer computes the conditions of the dependency checks (section 6.1); the band-independent error limit values replace the constants; no stride order (CO-RC-04) |
| Entropy coder | NZ (hybrid coder) | Statistics memories for the maximum NZ; the hybrid tail covers the NZ bands of the image; a band without statistics in the image (also every band of a single-pixel image) ends with its initial accumulator |
| Header generator | NX, NY, NZ, error limit values | The header parts that hold these fields are the ROM parts with the runtime bits replaced (section 6.2) |

The queue holds the configurations of the images that have started at the input and whose header (and, with the
hybrid coder, whose tail) is not yet complete: an entry is written when the predictor takes the first sample of an
image, the header generator reads its entry with a read pointer that moves on after the last part of a header, the
hybrid coder with a second read pointer that moves on after the tail of an image. The framer and the predictor take
the values directly in the cycle of the take. The queue has 16 entries, like the error flag queue of the image
framer, and while it is full the core takes no first sample of a new image. The queue and the register of the active
configuration are registers, not memories (no RAM inference, like the error flag queue), and rely on the TMR of the
synthesis tool. With
`RuntimeConfig_g` false the queue, the range limitation, the register of the active configuration, the image-start
sequencer and the field substitution are not instantiated, the `Act_` outputs are zero, and the units use the
constants as before (CO-RC-06).

### 6.1 Image-start sequencer

The predictor checks before it starts a sample that the samples it depends on have left its feedback loops (PR-TP-01).
How far apart these samples are in the issue order depends on NX, NY and M. In BI order the sample of the previous row
of a band lies NX M - M issues back, in BSQ order NX - 1 issues; the local differences of the previous bands are read
NX M - M + 1 issues after they are written in BI order and NX NY issues in BSQ order. With constant dimensions the
elaboration computes from these distances which dependencies can be closer than the latency of the loops, and how long
the history of issued bands must be. With runtime dimensions the image-start sequencer computes the same conditions
from the dimensions of the image, in imageStartCycles clock cycles (7 to 9) before the first sample of the image is
started (CO-RC-05), with one adder stepped by a small state machine instead of a combinational product: the factors
of a gap are saturated just above the largest latency, which keeps the comparisons exact. The history of issued
bands is sized for the worst case over the allowed dimensions. The sequencer is an entity with its own ports so that
its results can be compared with the elaboration function for every NX and M of a range (verification plan of the
predictor).

### 6.2 Header with runtime fields

The header stays a constant built by the procedure `build` (section 2), with the maxima in place of the runtime fields;
the procedure also records the bit position and width of every runtime field: X Size, Y Size and Z Size of the
essential subpart (each NX, NY, NZ mod 2^16) and the band-independent absolute and relative error limit values of the
quantization subpart (DA and DR bits). When the header generator outputs a part that contains a runtime field, it
replaces those bits with the value of the image (the queue entry of the image whose header is output). In BI order
the sub-frame interleaving depth M = min(`SubFrameDepth_g`, NZ) is a runtime field as well. The fields have fixed
widths and positions, so the header length does not depend on the runtime values (CO-HD-08); the configurations
whose header length would depend on NZ, and those with supplementary information tables, are excluded by CO-CF-04.

### 6.3 Runtime parameters

With `RuntimeParams_g` the parameters of section 2.8 of the specification join the configuration of an image: they
are taken in the same cycle as the dimensions, pass the same range limitation and go into the register of the active
configuration (`Act_` outputs) and into the queue entry of the image. The limitation follows the order of CO-RP-02:
gamma0 first, then gamma\* against the limited gamma0; vmin first, then vmax against the limited vmin; M against the
limited NZ.

| Unit | Uses | Change against the runtime configuration without parameters |
| --- | --- | --- |
| Predictor | M, log2 t_inc, vmin, vmax | M feeds the image-start sequencer (section 6.1) in place of min(`SubFrameDepth_g`, NZ); the weight update parameters are taken at the image start and travel with every item of the image (3 + 5 + 5 bits per pipeline stage), so that the stage that computes the weight update scaling exponent (CCSDS 4.10.2) uses the values of the image of its item while two images share the pipeline |
| Sample-adaptive coder | Umax, gamma0, gamma\*, K | The values are taken from the queue entry of the image with the first item of the image and held until its last item; the accumulator and counter widths stay those of `RescaleCounterSize_g`; the escape codeword and the rescaling threshold compare with the values of the image |
| Hybrid coder | Umax, gamma0, gamma\* | As the sample-adaptive coder, held until the end of the tail of the image |
| Block-adaptive coder | r | Taken with the first item of the image; the reference sample counter counts against r of the image within the range of `RefInterval_g` |
| Header generator | all | Further runtime fields at fixed positions (section 6.2): user-defined data and M in the essential subpart, the weight update parameters in the primary subpart of the predictor metadata, the coder parameters in the entropy coder metadata; the header length stays constant |

The queue entry holds the parameters in the encoding of their header fields, and only the fields of the options in
use (table 2 of the specification), so the header generator copies the bits as they are. The coders decode the
fields they need: Umax = 32 for the code 0, gamma0 = 8 for 0, gamma\* = code + 4, r = 4096 for 0; M = 65536 for the code
0 where the predictor would need it from the queue (it takes M directly at the image start). The decoding functions
are in `ocp_pkg`; the elaboration checks for every value of every range that decoding its encoding gives the value
back (CO-RP-05). The coders take their entry with a read pointer of their own: it moves on after the last item of an
image (with the hybrid coder after its tail, the read pointer of section 6), so a coder never uses the entry of an
image that has started at the input while the coder still works on an earlier one.

With `RuntimeParams_g` false the parameter inputs are not connected, the queue entry has no parameter fields and the
units use the generics as with the runtime configuration alone (CO-RP-04).
