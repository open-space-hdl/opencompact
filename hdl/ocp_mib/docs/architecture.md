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

## 4. Generics

The generics listed in the specification (section 4), with the names, defaults and ranges of `ocp_channel`; the
channel passes its own values. `AccuInit_g` gives the constant of the sample-adaptive coder (the first element; 15
when `AccuInitBandVarying_g` is true, as in the header).
