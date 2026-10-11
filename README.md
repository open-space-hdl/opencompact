# OpenCompact

[![TRL 2](docs/img/trl-2.svg)](https://openspacehdl.org/trl/)

OpenCompact is an open hyperspectral and multispectral image compression core according to CCSDS 123.0-B-2
(Low-Complexity Lossless and Near-Lossless Multispectral and Hyperspectral Image Compression), based on the Open Logic
VHDL Library. It implements the complete compressor of the standard: the adaptive predictor with full and reduced
prediction and all local sum types, lossless and near-lossless compression with absolute and relative error limits,
periodic error limit updating and sample representatives, the band-interleaved and band-sequential orders, the
header with all optional tables and the sample-adaptive, hybrid and block-adaptive entropy coders. All parameters are
generics. The memories use the fault-tolerant entities of [Open Logic](https://github.com/open-logic/open-logic)
(SECDED ECC).

## Status

**Technology readiness level: TRL 2** (in development, first performance estimates). The core is a demonstrator: it
compresses the test images of 24 configurations, which together cover every option of the standard, byte for byte
identically to the CNES reference software for CCSDS 123.0-B-2, in GHDL and in QuestaSim, and it synthesizes for
every configuration. It has not been tested on hardware and has no flight heritage; see
[what the levels mean](https://openspacehdl.org/trl/) and the steps to the next level in the
[roadmap](docs/roadmap.md#technology-readiness).

The reference model of the verification (`tools/ocp_model.py`) reproduces all 6474 compressed images of the CCSDS test
data set for the standard. The [compliance matrix](docs/compliance.md) traces every clause of the standard to its
requirements and test cases; the [user guide](docs/user_guide.md) contains the implementation conformance statement
of annex A of the standard.

## Documentation

| Document | Content |
| --- | --- |
| [docs/architecture.md](docs/architecture.md) | Architecture: building blocks, owned clauses, Open Logic usage, verification |
| [docs/user_guide.md](docs/user_guide.md) | Integration: sources, generics, interfaces, operating sequence, integration constraints, performance, conformance statement |
| [docs/conventions.md](docs/conventions.md) | Coding, verification and repository conventions |
| [docs/roadmap.md](docs/roadmap.md) | Technology readiness, module status, open items |
| [docs/compliance.md](docs/compliance.md) | Compliance matrix: requirements and test cases of every clause (generated) |
| [docs/coverage.md](docs/coverage.md) | Code coverage of the regression |
| `hdl/<module>/docs/` | Specification, architecture, verification plan and verification report of each module |

## Repository structure

```text
opencompact/
|-- docs/             Top-level documentation
|-- hdl/<module>/     One folder per module: src/, tb/, docs/
|-- tb/               Shared verification package and the golden data (tb/golden/<configuration>/)
|-- lint/             VSG configuration (Open Logic rules), synthesizability check
|-- tools/            Reference model, configurations, golden data generator, table generator, compliance matrix,
|                     synthesis scripts
|   `-- docs/         Documentation website (MkDocs)
|-- open-logic/       Git submodule: Open Logic (fault-tolerant fork)
|-- uvvm/             Git submodule: UVVM verification framework
|-- component_list.txt  Modules in dependency order
`-- run.py            VUnit regression runner
```

## Running the tests

Prerequisites: Python 3, [GHDL](https://github.com/ghdl/ghdl) on the `PATH` and the Python packages of
`requirements.txt`.

```shell
git submodule update --init
python -m pip install -r requirements.txt
python run.py -p 4                  # full regression with GHDL
python run.py "*ocp_core*"          # one module
python run.py --questa <test>       # QuestaSim
```

Every testbench runs once per configuration of `tools/ocp_configs.py`; the compressed images are compared with the
golden data of `tb/golden/`, which `tools/golden.py` generates with the CNES reference software.

Checks besides the regression:

```shell
python lint/lint.py                         # VSG, no errors and no warnings
python lint/synth_check.py                  # synthesizability of every configuration with GHDL
python tools/compliance.py --check          # traceability of every clause
python tools/gen_low_entropy_pkg.py --check # low-entropy code tables up to date
python tools/check_model_testvectors.py <dir>   # reference model against the CCSDS test data set
```

## Licence

OpenCompact is licensed under the PSI HDL Library License, Version 1.0 ([License.txt](License.txt)), the licence of
Open Logic: the LGPL 2.1 ([LGPL2_1.txt](LGPL2_1.txt)) with an exception for binaries such as FPGA bitstreams.
