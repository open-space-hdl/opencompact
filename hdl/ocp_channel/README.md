# ocp_channel

OpenCompact compression channel: SDUs of samples in (`ocp_input_adapter`), compression with `ocp_core` and its image
framing, every compressed image out as one packet of a byte stream of 8 to 128 bits, and the status registers
(`ocp_mib`) on an AXI4-Lite slave.

| Document | Content |
| --- | --- |
| [Specification](docs/specification.md) | Requirements, error scenarios with their counter steps, generics, integration constraints |
| [Architecture](docs/architecture.md) | Structure, output adapter, image events, ports, public entities |
| [Verification plan](docs/verification_plan.md) | Integration test cases against the CNES reference software |
| [Verification report](docs/verification_report.md) | Results |

Tests: `python run.py "*ocp_channel*"`
