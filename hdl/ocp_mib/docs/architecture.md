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
| `Cfg_UserData`, `Cfg_M`, `Cfg_WeightInterval`, `Cfg_WeightVmin`, `Cfg_WeightVmax`, `Cfg_UnaryLimit`, `Cfg_InitCountExp`, `Cfg_RescaleSize`, `Cfg_AccuInit`, `Cfg_RefInterval` | out | 8, 17, 4, 5, 5, 6, 4, 4, 4, 13 | With `RuntimeParams_g`: committed runtime parameters for the core (zero for a parameter not in use) |
| `Act_UserData` to `Act_RefInterval` | in | as `Cfg_` | With `RuntimeParams_g`: runtime parameters that the core took for the last image |

## 4. Generics

The generics listed in the specification (section 4), with the names, defaults and ranges of `ocp_channel`; the
channel passes its own values. `AccuInit_g` gives the constant of the sample-adaptive coder (the first element; 15
when `AccuInitBandVarying_g` is true, as in the header). `HybridAccuInit_g` and `HybridAccuInitHigh_g` give the
lower bound of gamma0 that the COMMIT checks with the runtime parameters and the hybrid coder (`hybridG0Min` of
`ocp_pkg`, the function the core uses for its range limitation).

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

GENERICS gets the field RUNTIME_CONFIG (bit 18, RO), and the ID the version 2 (0x4F435002; version 3 with the runtime
parameters of section 6). These registers rely on
the TMR of the synthesis tool, like the counters.

## 6. Runtime parameters (register map version 3)

With `RuntimeParams_g` the runtime parameters join the three sets of section 5. The pending registers mirror the
layout of the read-only registers that show the parameters, so software uses one field definition for both: SAMPLES
and NEXT_SAMPLES, ORDER and NEXT_ORDER, and so on. The range check of a COMMIT covers the parameters of the options in
use, the dependent ranges against the pending values they depend on, and the copy into the committed set takes the
dimensions, the error limit values and the parameters in one clock cycle.

| Set | Registers | Written by | Read by |
| --- | --- | --- | --- |
| Pending | NEXT_SAMPLES, NEXT_ORDER, NEXT_WEIGHTS, NEXT_ADAPTIVE, NEXT_BLOCK (RW) | Software | Software, the range check |
| Committed | Outputs `Cfg_UserData`, `Cfg_M`, `Cfg_Weight*`, `Cfg_UnaryLimit`, `Cfg_InitCountExp`, `Cfg_RescaleSize`, `Cfg_AccuInit`, `Cfg_RefInterval` | A valid COMMIT, with the dimensions | The core at every image start |
| Active | The parameter fields of SAMPLES, ORDER, WEIGHTS, ADAPTIVE, BLOCK (RO) | The core at every image start, after its range limitation (`Act_` inputs) | Software |

New registers (offsets of `ocp_regs.yml`; the registers of version 2 keep their offsets and fields):

| Offset | Register | Fields (as in the read-only register of the same name without NEXT_) |
| --- | --- | --- |
| 0x07C | NEXT_SAMPLES | USER_DATA (bits 15:8, RW) |
| 0x080 | NEXT_ORDER | SUB_FRAME_DEPTH (bits 24:8, RW; BI order only) |
| 0x084 | NEXT_WEIGHTS | VMAX (bits 21:17, RW), VMIN (bits 16:12, RW), UPDATE_INTERVAL (bits 11:8, RW) |
| 0x088 | NEXT_ADAPTIVE | ACCU_INIT (bits 19:16, RW; sample-adaptive coder), INITIAL_COUNT (bits 15:12, RW), RESCALE_SIZE (bits 11:8, RW), UNARY_LIMIT (bits 5:0, RW); zero with the block-adaptive coder |
| 0x08C | NEXT_BLOCK | REF_INTERVAL (bits 20:8, RW); zero with the other coders |

GENERICS gets the field RUNTIME_PARAMS (bit 19, RO), and the ID the version 3 (0x4F435003). The fields
SAMPLES.USER_DATA, ORDER.SUB_FRAME_DEPTH, WEIGHTS.VMAX, VMIN and UPDATE_INTERVAL, ADAPTIVE.ACCU_INIT, INITIAL_COUNT,
RESCALE_SIZE and UNARY_LIMIT and BLOCK.REF_INTERVAL read the `Act_` inputs with `RuntimeParams_g`. Like the
registers of section 5 the new registers rely on the TMR of the synthesis tool.
