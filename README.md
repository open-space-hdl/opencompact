# OpenCompact

[![TRL 3](docs/img/trl-3.svg)](https://openspacehdl.org/trl/)

OpenCompact is an open hyperspectral and multispectral image compression core according to CCSDS 123.0-B-2
(Low-Complexity Lossless and Near-Lossless Multispectral and Hyperspectral Image Compression), based on the Open Logic
VHDL Library. It implements the complete compressor of the standard: the adaptive predictor with full and reduced
prediction and all local sum types, lossless and near-lossless compression with absolute and relative error limits,
periodic error limit updating and sample representatives, the band-interleaved and band-sequential orders, the
header with all optional tables and the sample-adaptive, hybrid and block-adaptive entropy coders. All parameters are
generics. The memories use the fault-tolerant entities of [Open Logic](https://github.com/open-logic/open-logic)
(SECDED ECC).

The predictor is a pipeline that takes one sample per clock cycle where the configuration allows it: in
band-interleaved order with enough bands, with a speculative weight update for band-sequential order and single
bands, and in a stride order for near-lossless compression of band-interleaved images. The entropy coders take one
sample per clock cycle, and the compressed image leaves the core in words of 8 to 64 bits. The
[user guide](docs/user_guide.md#8-resources-and-performance) lists the throughput of every configuration. With the
optional image framing (`UseInLast_g`) an image end marker on the input lets the core detect lost samples: it
aborts or completes the damaged image, flags it on its last word and resynchronises with the next image
([user guide](docs/user_guide.md#42-image-framing)).

## Status

**Technology readiness level: TRL 3** (fully verified by simulation). The core compresses the test images of 38
configurations, which together cover every option of the standard, and of 24 random configurations byte for byte
identically to the CNES reference software for CCSDS 123.0-B-2, in GHDL and in QuestaSim. It also reproduces the
compressed images of 300 vectors of the CCSDS test data set, selected to cover the parameter values of the set. Unit
testbenches verify the predictor, the entropy coders and the bit packer; single and double bit errors are injected
into every memory through the error injection port, every reset at a random time is followed by a correct image,
and with the image framing every image with an early or a missing image end marker is flagged and followed by correct
images.
Code coverage is closed or every remaining miss is justified ([coverage](docs/coverage.md)). The predictor testbench
checks the throughput of every configuration cycle by cycle against the throughput model `tools/ocp_throughput.py`,
and every configuration synthesizes. The core has not been tested on hardware and has no flight heritage; see
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
|-- compile_order.txt   Synthesis sources in compile order (generated by run.py)
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
golden data of `tb/golden/`, which `tools/golden.py` generates with the CNES reference software. With the environment
variable `OCP_TESTVECTORS` the testbenches also run a selection of the CCSDS test data set that
`tools/ocp_testvectors.py` prepares (the data set is not part of the repository):

```shell
python tools/ocp_testvectors.py <data set directory> --out <directory> --count 300
OCP_TESTVECTORS=<directory> python run.py -p 4
```

Checks besides the regression:

```shell
python lint/lint.py                         # VSG, no errors and no warnings
python lint/synth_check.py                  # GHDL synthesis: configurations, generic bounds, invalid values
python tools/compliance.py --check          # traceability of every clause
python tools/gen_low_entropy_pkg.py --check # low-entropy code tables up to date
python tools/check_model_testvectors.py <dir>   # reference model against the CCSDS test data set
python tools/ocp_throughput.py              # cycles per sample of every configuration
python run.py --compile-order               # compile_order.txt; the CI fails when the file changes
```

Checks with the AMD Vivado tools (Vivado on the `PATH` or `VIVADO_PATH` set to the installation):

```shell
python lint/xsim_smoke.py                   # every synthesis top level in the AMD simulator for 1 us
python lint/vivado_ooc.py                   # out-of-context implementation at 200 MHz (see below)
```

`lint/vivado_ooc.py` implements three configurations out of context on the Versal AI Core device
`xcvc1902-vsva2197-2MP-e-S`:

- `rs_sce`: the `ocp_channel` of the reference system `spfi_compress_encrypt` (64 x 64 x 48 samples, D = 16, BI with
  M = 48, full prediction with P = 3, sample-adaptive coder, 32-bit words, 128-bit streams);
- `c01` and `c11`: `ocp_core` in `c01_lossless_bip` and `c11_wide_d32` of `tools/ocp_configs.py`.

Each run synthesizes out of context, places and routes with a clock of the target frequency on the core clock, which
enters through a global clock buffer, and writes the timing summary, the utilization, the 20 worst setup paths and
the logic level distribution to `<out>/results/` with `summary.md` as the overview. Only register-to-register paths
are timed: the ports have no input or output delays. The scoped constraints of the Open Logic modules that
OpenCompact uses are loaded, and the run stops before `opt_design` when a constraint did not apply. Vivado projects
need short paths on Windows, so the default output directory is `C:/osh/ocp_ooc`; Vivado writes its temporary
files to `<out>/tmp` (`--temp` selects another directory):

```shell
python lint/vivado_ooc.py --out C:/osh/ocp_ooc --mhz 200   # all three configurations
python lint/vivado_ooc.py c11                               # one configuration
python lint/vivado_ooc.py --elaborate                       # RTL elaboration only, no synthesis or implementation
```

## Licence

OpenCompact is licensed under the PSI HDL Library License, Version 1.0 ([License.txt](License.txt)), the licence of
Open Logic: the LGPL 2.1 ([LGPL2_1.txt](LGPL2_1.txt)) with an exception for binaries such as FPGA bitstreams.
