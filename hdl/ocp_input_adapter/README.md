# ocp_input_adapter

Input adapter of an OpenCompact channel: takes service data units (SDUs) of big-endian sample containers of ceil(D/8)
bytes from a byte stream of 8 to 128 bits and outputs one sample per beat to `ocp_core` with the image framing. The
user signal of an SDU marks the last SDU of an image and flags faulty SDUs; a faulty SDU, or one that does not hold a
whole number of samples, ends its image with an error, and the rest of that image is discarded.

| Document | Content |
| --- | --- |
| [Specification](docs/specification.md) | Requirements, partner behaviour of the SDU source, error conditions, generics |
| [Architecture](docs/architecture.md) | Width converter, sample extraction, SDU control, the `In_Error` input of the core |
| [Verification plan](docs/verification_plan.md) | Test cases with a reference model of the adapter |
| [Verification report](docs/verification_report.md) | Results |

Tests: `python run.py "*ocp_input_adapter*"`
