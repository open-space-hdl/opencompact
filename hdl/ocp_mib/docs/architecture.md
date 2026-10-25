# ocp_mib: Architecture

## 1. Structure

![Block diagram of ocp_mib: the AXI4-Lite slave olo_axi_lite_slave and the registers with the
constant configuration words and the six counters of the event inputs](img/ocp_mib_arch.drawio.svg)

`olo_axi_lite_slave` turns the AXI4-Lite accesses into a simple register bus (`Rb_*`). Every read is answered in the
clock cycle after `Rb_Rd` with `Rb_RdValid`, so the read timeout of the slave never expires. The registers GENERICS
to BLOCK are constants computed during elaboration from the generics with the field positions of `ocp_regs_pkg`; the
synthesis tool reduces them to the read multiplexer. The register map is in [register_map.md](register_map.md).

## 2. Counters

Each counter is a 32-bit register with its event input:

| Condition in a clock cycle | Next value |
| --- | --- |
| Write to its address, event | 1 |
| Write to its address, no event | 0 |
| Event, value below 2^32 - 1 | value + 1 |
| Otherwise | value |

A read returns the value before the clock edge of the read cycle. The counters are registers that rely on the TMR of
the synthesis tool, like all logic outside the memories (user guide, section "Protection scope").

## 3. Ports

| Port | Direction | Width | Description |
| --- | --- | --- | --- |
| `Clk` | in | 1 | Clock |
| `Rst` | in | 1 | Synchronous reset, high-active |
| `S_AxiLite_*` | | | AXI4-Lite slave: `ArAddr`, `AwAddr` 8 bits, `WData`, `RData` 32 bits, `WStrb` 4 bits, `BResp`, `RResp` 2 bits, handshakes |
| `Ev_ImageDone` | in | 1 | Pulse: a compressed image without error has left the core |
| `Ev_ImageAborted` | in | 1 | Pulse: a compressed image with an error has left the core |
| `Ev_SduError` | in | 1 | Pulse: faulty SDU forwarded |
| `Ev_SduDiscarded` | in | 1 | Pulse: SDU discarded |
| `Ecc_Sec`, `Ecc_Ded` | in | 1 | Pulses: corrected and detected memory errors of the core |
| `Cfg_XSize`, `Cfg_YSize`, `Cfg_ZSize` | out | 17 | With `RuntimeConfig_g`: committed NX, NY, NZ for the core |
| `Cfg_AbsLimit`, `Cfg_RelLimit` | out | 16 | With `RuntimeConfig_g`: committed band-independent error limit values for the core |
| `Cfg_Taken` | in | 1 | Pulse from the core: it takes the configuration outputs for an image in this clock cycle |
| `Act_XSize`, `Act_YSize`, `Act_ZSize` | in | 17 | With `RuntimeConfig_g`: NX, NY, NZ that the core took for the last image |
| `Act_AbsLimit`, `Act_RelLimit` | in | 16 | With `RuntimeConfig_g`: error limit values that the core took for the last image |

## 4. Generics

The generics listed in the specification (section 4), with the names, defaults and ranges of `ocp_channel`; the
channel passes its own values. `AccuInit_g` gives the constant of the sample-adaptive coder (the first element; 15
when `AccuInitBandVarying_g` is true, as in the header).

## 5. Runtime configuration

With `RuntimeConfig_g` three sets of values describe the configuration; the MIB holds the first two, the core the third:

| Set | Registers | Written by | Read by |
| --- | --- | --- | --- |
| Pending | NEXT_X, NEXT_Y, NEXT_Z, NEXT_LIMITS (RW) | Software | Software (readback before COMMIT), the range check |
| Committed | Outputs `Cfg_*` | A valid COMMIT, all fields in one clock cycle | The core at every image start |
| Active | IMAGE_X, IMAGE_Y, IMAGE_Z, ORDER.SUB_FRAME_DEPTH, LIMITS (RO) | The core at every image start, after its range limitation (`Act_` inputs) | Software |

The range check is combinational on the pending registers and is evaluated in the cycle of the COMMIT write (the
comparisons with the maxima are comparisons with constants). A COMMIT copies the pending set into the committed set
only when every field is in range; otherwise it sets CFG_ERROR. Because the core takes the committed outputs in one
clock cycle and a COMMIT changes all five in the same clock cycle, an image never sees a mix of two
configurations. A COMMIT written in the clock cycle of `Cfg_Taken` changes the outputs at the end of that cycle,
after the core has taken the previous values.
CFG_PENDING is set by a valid COMMIT and cleared by `Cfg_Taken` (a COMMIT and `Cfg_Taken` in the same cycle leave it
set: the new values are not yet taken). SUB_FRAME_DEPTH reads min(`SubFrameDepth_g`, `Act_ZSize`). Because the
active registers show what the core took, they also show the values of an image whose configuration reached the
core out of range (CO-RC-07).

New registers (offsets for `ocp_regs.yml`; the existing registers keep their offsets):

| Offset | Register | Fields |
| --- | --- | --- |
| 0x060 | CONTROL | COMMIT (bit 0, W1, reads 0) |
| 0x064 | STATUS | CFG_PENDING (bit 0, RO), CFG_ERROR (bit 1, W1C) |
| 0x068 | NEXT_X | SIZE (bits 16:0, RW) |
| 0x06C | NEXT_Y | SIZE (bits 16:0, RW) |
| 0x070 | NEXT_Z | SIZE (bits 16:0, RW) |
| 0x074 | NEXT_LIMITS | ABS (bits 15:0, RW), REL (bits 31:16, RW) |
| 0x078 | LIMITS | ABS (bits 15:0, RO), REL (bits 31:16, RO) |

GENERICS gets the field RUNTIME_CONFIG (bit 18, RO), and the ID the version 2 (0x4F435002). These registers rely on
the TMR of the synthesis tool, like the counters.
