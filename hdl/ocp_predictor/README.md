# ocp_predictor

Predictor, quantizer and mapper of CCSDS 123.0-B-2 (PR-1 to PR-6): turns the image samples, given in the input order of
the compressed image, into the entropy coder input sequence of mapped quantizer indices and error limit values.

| Document | Content |
| --- | --- |
| [Specification](docs/specification.md) | Requirements, configuration, interpretation of the standard, integration constraints |
| [Architecture](docs/architecture.md) | State machine, memories, arithmetic, interfaces |
| [Verification plan](docs/verification_plan.md) | Test cases |
| [Verification report](docs/verification_report.md) | Results and findings |

Tests: `python run.py "*predictor*" "*image_start*"`
