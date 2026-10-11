# ocp_core

Top level of OpenCompact (CO-1 to CO-3): header generator, predictor, the selected entropy coder and the bit packer.
Compresses images according to CCSDS 123.0-B-2 with all options set by generics and outputs every compressed image as a
stream of words of 8 to 64 bits.

| Document | Content |
| --- | --- |
| [Specification](docs/specification.md) | Requirements, configuration, interpretation of the standard, integration constraints |
| [Architecture](docs/architecture.md) | Image sequencing, header generator, bit packer, interfaces |
| [Verification plan](docs/verification_plan.md) | Test cases against the CNES reference software |
| [Verification report](docs/verification_report.md) | Results and findings |

Tests: `python run.py "*ocp_core*"`
