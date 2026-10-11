# ocp_entropy_coder

The three entropy coders of CCSDS 123.0-B-2 (EC-1 to EC-3): `ocp_sample_adaptive_coder`, `ocp_hybrid_coder` with the
16 low-entropy codes of annex B, and `ocp_block_adaptive_coder` (adaptive entropy coder of CCSDS 121.0-B-3 without
preprocessor). `ocp_core` instantiates the coder selected by `EntropyCoder_g`.

| Document | Content |
| --- | --- |
| [Specification](docs/specification.md) | Requirements, configuration, interpretation of the standard, integration constraints |
| [Architecture](docs/architecture.md) | State machines, statistics memories, low-entropy code tables, option selection |
| [Verification plan](docs/verification_plan.md) | Test cases (core level) |
| [Verification report](docs/verification_report.md) | Results and findings |

Tests: `python run.py "*ocp_core*"`
