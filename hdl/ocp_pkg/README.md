# ocp_pkg

Definitions shared by all OpenCompact modules (PK-1, PK-2): the codeword and entropy coder input streams, the decoding
of the string generics, the access to per-band tables, and the code and flush tables of the 16 low-entropy codes of
the hybrid entropy coder (`ocp_low_entropy_pkg`, generated from CCSDS 123.0-B-2 annex B).

| Document | Content |
| --- | --- |
| [Specification](docs/specification.md) | Requirements |
| [Architecture](docs/architecture.md) | Package contents, generation of the low-entropy code tables |
| [Verification plan](docs/verification_plan.md) | Test cases |
| [Verification report](docs/verification_report.md) | Results |

Tests: `python tools/gen_low_entropy_pkg.py --check` and `python run.py "*ocp_core*"`
